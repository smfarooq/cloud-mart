using Azure.Core;
using Azure.Identity;
using Azure.Messaging.EventHubs.Producer;
using Azure.Messaging.ServiceBus;
using Azure.Storage.Blobs;
using CloudMart.Core.Azure;
using CloudMart.Core.InMemory;
using CloudMart.Core.InProcess;
using CloudMart.Core.Payments;
using CloudMart.Core.Services;
using CloudMart.Core.Shipping;
using Microsoft.Azure.Cosmos;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Npgsql;

namespace CloudMart.Core;

public enum CloudMartHost
{
    Api,
    Functions,
}

public static class CloudMartServiceCollectionExtensions
{
    private static readonly string[] PostgresScopes = ["https://ossrdbms-aad.database.windows.net/.default"];

    /// <summary>
    /// Registers CloudMart's services, choosing in-memory or Azure implementations from configuration.
    /// Nothing configured = runs on a laptop. Add Cosmos__Endpoint = catalog moves to Cosmos DB. And so on.
    /// </summary>
    public static IServiceCollection AddCloudMartCore(
        this IServiceCollection services, IConfiguration config, CloudMartHost host, TokenCredential? credential = null)
    {
        var settings = CloudMartSettings.From(config);
        services.AddSingleton(settings);

        // One credential for every Azure SDK client and both databases. In Azure it resolves to the managed
        // identity whose client id is in AZURE_CLIENT_ID (or AKS workload identity); on a laptop it falls
        // back to your `az login` / Visual Studio sign-in. No keys or connection-string secrets anywhere.
        credential ??= new DefaultAzureCredential();
        services.AddSingleton(credential);

        services.AddScoped<OrderService>();
        services.AddScoped<OrderFulfillmentService>();
        services.AddScoped<OrderSagaActivities>();
        services.AddScoped<ProductViewAggregator>();
        services.AddScoped<ProductImageProcessor>();

        string catalog, orders, messaging, telemetry, images, payments, shipping;

        // Catalog + view counters: Cosmos DB (phase 4)
        if (settings.CosmosEndpoint is { } cosmosEndpoint)
        {
            services.AddSingleton(_ => new CosmosClient(cosmosEndpoint, credential, new CosmosClientOptions
            {
                ApplicationName = "CloudMart",
                UseSystemTextJsonSerializerWithOptions = CloudMartJson.Options,
            }));
            services.AddSingleton<CosmosProductRepository>();
            services.AddSingleton<IProductRepository>(sp => sp.GetRequiredService<CosmosProductRepository>());
            services.AddSingleton<IHealthProbe>(sp => sp.GetRequiredService<CosmosProductRepository>());
            services.AddSingleton<IProductStatsRepository, CosmosProductStatsRepository>();
            catalog = "Cosmos DB";
        }
        else
        {
            services.AddSingleton<IProductRepository, InMemoryProductRepository>();
            services.AddSingleton<IProductStatsRepository, InMemoryProductStatsRepository>();
            catalog = "In-memory";
        }

        // Orders: Azure SQL Database or Azure Database for PostgreSQL (phase 4)
        switch (settings.OrdersProvider)
        {
            case "SqlServer":
                // Entra auth lives in the connection string: "Authentication=Active Directory Managed Identity;
                // User Id=<identity client id>" in Azure, "Authentication=Active Directory Default" locally.
                services.AddDbContext<OrdersDbContext>(o => o.UseSqlServer(settings.OrdersConnectionString, sql => sql.EnableRetryOnFailure()));
                AddEfOrders(services);
                orders = "Azure SQL Database";
                break;

            case "PostgreSql":
                var dataSourceBuilder = new NpgsqlDataSourceBuilder(settings.OrdersConnectionString);
                if (string.IsNullOrEmpty(dataSourceBuilder.ConnectionStringBuilder.Password))
                {
                    // Entra auth for PostgreSQL: the "password" is a short-lived access token, refreshed periodically.
                    dataSourceBuilder.UsePeriodicPasswordProvider(
                        async (_, ct) => (await credential.GetTokenAsync(new TokenRequestContext(PostgresScopes), ct)).Token,
                        TimeSpan.FromMinutes(30),
                        TimeSpan.FromSeconds(10));
                }
                var dataSource = dataSourceBuilder.Build();
                services.AddDbContext<OrdersDbContext>(o => o.UseNpgsql(dataSource));
                AddEfOrders(services);
                orders = "Azure Database for PostgreSQL";
                break;

            default:
                services.AddSingleton<IOrderRepository, InMemoryOrderRepository>();
                orders = "In-memory";
                break;
        }

        // Product images: Blob Storage (phase 4) + Event Grid (phase 5)
        if (settings.BlobEndpoint is { } blobEndpoint)
        {
            services.AddSingleton(_ => new BlobServiceClient(new Uri(blobEndpoint), credential));
            services.AddSingleton<BlobImageStore>();
            services.AddSingleton<IImageStore>(sp => sp.GetRequiredService<BlobImageStore>());
            services.AddSingleton<IHealthProbe>(sp => sp.GetRequiredService<BlobImageStore>());
            images = "Blob Storage";
        }
        else
        {
            services.AddSingleton<InMemoryImageStore>();
            services.AddSingleton<IImageStore>(sp => sp.GetRequiredService<InMemoryImageStore>());
            images = "In-memory";
        }

        // Order events: Service Bus topic (phase 5)
        if (settings.ServiceBusNamespace is { } serviceBusNamespace)
        {
            services.AddSingleton(_ => new ServiceBusClient(serviceBusNamespace, credential,
                new ServiceBusClientOptions { TransportType = settings.ServiceBusTransport }));
            services.AddSingleton<IOrderEventPublisher, ServiceBusOrderEventPublisher>();
            messaging = settings.ServiceBusTransport == ServiceBusTransportType.AmqpWebSockets ? "Service Bus (WebSockets)" : "Service Bus";
        }
        else
        {
            services.AddSingleton<InProcessOrderQueue>();
            services.AddSingleton<IOrderEventPublisher, InProcessOrderEventPublisher>();
            if (host == CloudMartHost.Api)
                services.AddHostedService<InProcessOrderWorker>();
            messaging = "In-process";
        }

        // Click stream: Event Hubs (phase 5)
        if (settings.EventHubsNamespace is { } eventHubsNamespace)
        {
            services.AddSingleton(_ => new EventHubProducerClient(eventHubsNamespace, settings.TelemetryHub, credential));
            services.AddSingleton<ITelemetryPublisher, EventHubsTelemetryPublisher>();
            telemetry = "Event Hubs";
        }
        else
        {
            services.AddScoped<ITelemetryPublisher, InProcessTelemetryPublisher>();
            telemetry = "In-process";
        }

        // Payments and shipping: separate services (phase 16), otherwise modules in this process.
        if (settings.PaymentsBaseUrl is { } paymentsUrl)
        {
            AddServiceClient<PaymentsApiClient>(services, paymentsUrl, settings.PaymentsScope, credential);
            services.AddTransient<IPaymentGateway>(sp => sp.GetRequiredService<PaymentsApiClient>());
            services.AddTransient<IHealthProbe>(sp => sp.GetRequiredService<PaymentsApiClient>());
            payments = "Payments API";
        }
        else
        {
            services.AddSingleton<IPaymentStore, InMemoryPaymentStore>();
            services.AddSingleton<PaymentProcessor>();
            services.AddSingleton<IPaymentGateway, InProcessPaymentGateway>();
            payments = "In-process";
        }

        if (settings.ShippingBaseUrl is { } shippingUrl)
        {
            AddServiceClient<ShippingApiClient>(services, shippingUrl, settings.ShippingScope, credential);
            services.AddTransient<IShippingGateway>(sp => sp.GetRequiredService<ShippingApiClient>());
            services.AddTransient<IHealthProbe>(sp => sp.GetRequiredService<ShippingApiClient>());
            shipping = "Shipping API";
        }
        else
        {
            services.AddSingleton<IShipmentStore, InMemoryShipmentStore>();
            services.AddSingleton<ShippingProcessor>();
            services.AddSingleton<IShippingGateway, InProcessShippingGateway>();
            shipping = "In-process";
        }

        services.AddSingleton(new CloudMartProviders(catalog, orders, messaging, telemetry, images, payments, shipping));
        return services;
    }

    private static void AddServiceClient<TClient>(IServiceCollection services, string baseUrl, string? scope, TokenCredential credential)
        where TClient : class
    {
        var client = services.AddHttpClient<TClient>(http => http.BaseAddress = new Uri(baseUrl.TrimEnd('/') + "/"));
        if (scope is not null)
            client.AddHttpMessageHandler(() => new EntraTokenHandler(credential, scope));

        // Timeout per attempt, retries with exponential backoff and jitter (5xx, 408, 429, network errors), and a
        // circuit breaker that fails fast while the service is down instead of piling up waiting requests.
        client.AddStandardResilienceHandler();
    }

    /// <summary>Creates the orders schema (if enabled) and seeds the catalog when it is empty. Never throws.</summary>
    public static async Task InitializeCloudMartDataAsync(this IServiceProvider services, ILogger logger, CancellationToken ct)
    {
        await using var scope = services.CreateAsyncScope();
        var settings = scope.ServiceProvider.GetRequiredService<CloudMartSettings>();

        if (settings.OrdersProvider != "InMemory" && settings.EnsureOrdersSchema)
        {
            try
            {
                // Fine for a lab. Production would run EF migrations (a migration bundle) from the pipeline instead,
                // so the app's identity needs only data rights, not db_ddladmin.
                var db = scope.ServiceProvider.GetRequiredService<OrdersDbContext>();
                await db.Database.EnsureCreatedAsync(ct);
                logger.LogInformation("Orders schema is ready on {Provider}", settings.OrdersProvider);
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Could not prepare the orders database; /health/ready will show why");
            }
        }

        try
        {
            var products = scope.ServiceProvider.GetRequiredService<IProductRepository>();
            if ((await products.ListAsync(null, ct)).Count == 0)
            {
                foreach (var product in CatalogSeed.Products)
                    await products.UpsertAsync(product, ct);
                logger.LogInformation("Seeded {Count} catalog products", CatalogSeed.Products.Count);
            }
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Could not seed the catalog; /health/ready will show why");
        }
    }

    private static void AddEfOrders(IServiceCollection services)
    {
        services.AddScoped<EfOrderRepository>();
        services.AddScoped<IOrderRepository>(sp => sp.GetRequiredService<EfOrderRepository>());
        services.AddScoped<IHealthProbe>(sp => sp.GetRequiredService<EfOrderRepository>());
    }
}
