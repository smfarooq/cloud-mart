using System.Text.Json;
using System.Text.Json.Serialization;
using Azure.Messaging.ServiceBus;
using Microsoft.Extensions.Configuration;

namespace CloudMart.Core;

/// <summary>
/// Configuration contract shared by the API, the Functions app and the Bicep templates. In App Service and
/// Functions these arrive as app settings with "__" in place of ":" (for example Cosmos__Endpoint).
/// </summary>
public sealed record CloudMartSettings
{
    public string? CosmosEndpoint { get; init; }
    public string CosmosDatabase { get; init; } = "cloudmart";
    public string ProductsContainer { get; init; } = "products";
    public string StatsContainer { get; init; } = "product-stats";

    /// <summary>InMemory, SqlServer or PostgreSql.</summary>
    public string OrdersProvider { get; init; } = "InMemory";
    public string? OrdersConnectionString { get; init; }
    public bool EnsureOrdersSchema { get; init; } = true;

    public string? ServiceBusNamespace { get; init; }
    public string OrdersTopic { get; init; } = "orders";

    /// <summary>AmqpTcp (port 5671), or AmqpWebSockets (443) behind a firewall that only lets HTTPS out (phase 13).</summary>
    public ServiceBusTransportType ServiceBusTransport { get; init; } = ServiceBusTransportType.AmqpTcp;

    public string? EventHubsNamespace { get; init; }
    public string TelemetryHub { get; init; } = "telemetry";

    public string? BlobEndpoint { get; init; }
    public string UploadContainer { get; init; } = "product-uploads";
    public string ImageContainer { get; init; } = "product-images";

    /// <summary>Phase 16. Empty = the payments module runs in-process.</summary>
    public string? PaymentsBaseUrl { get; init; }

    /// <summary>"api://&lt;Payments API client id&gt;/.default". Empty = call without a token (local runs).</summary>
    public string? PaymentsScope { get; init; }

    public string? ShippingBaseUrl { get; init; }
    public string? ShippingScope { get; init; }

    /// <summary>Phase 14: the data lake's blob endpoint. Empty = no lake; the Platform page shows analytics as off.</summary>
    public string? DataLakeEndpoint { get; init; }
    public string OrderExportsContainer { get; init; } = "orders";
    public string ClickstreamContainer { get; init; } = "clickstream";

    /// <summary>Event Hubs Capture writes the click stream to the lake (phase 14).</summary>
    public bool ClickstreamCapture { get; init; }

    public static CloudMartSettings From(IConfiguration config)
    {
        var sql = Blank(config.GetConnectionString("OrdersSql"));
        var postgres = Blank(config.GetConnectionString("OrdersPostgres"));
        var ordersProvider = Blank(config["Orders:Provider"])
            ?? (sql is not null ? "SqlServer" : postgres is not null ? "PostgreSql" : "InMemory");

        return new CloudMartSettings
        {
            CosmosEndpoint = Blank(config["Cosmos:Endpoint"]),
            CosmosDatabase = config["Cosmos:Database"] ?? "cloudmart",
            OrdersProvider = ordersProvider,
            OrdersConnectionString = ordersProvider switch
            {
                "SqlServer" => sql ?? throw Missing("ConnectionStrings:OrdersSql"),
                "PostgreSql" => postgres ?? throw Missing("ConnectionStrings:OrdersPostgres"),
                _ => null,
            },
            EnsureOrdersSchema = config.GetValue("Orders:EnsureCreated", true),
            ServiceBusNamespace = Blank(config["ServiceBus:FullyQualifiedNamespace"]),
            ServiceBusTransport = config.GetValue("ServiceBus:TransportType", ServiceBusTransportType.AmqpTcp),
            EventHubsNamespace = Blank(config["EventHubs:FullyQualifiedNamespace"]),
            BlobEndpoint = Blank(config["Storage:BlobEndpoint"]),
            PaymentsBaseUrl = Blank(config["Payments:BaseUrl"]),
            PaymentsScope = Blank(config["Payments:Scope"]),
            ShippingBaseUrl = Blank(config["Shipping:BaseUrl"]),
            ShippingScope = Blank(config["Shipping:Scope"]),
            DataLakeEndpoint = Blank(config["Analytics:DataLakeEndpoint"]),
            ClickstreamCapture = config.GetValue("Analytics:ClickstreamCapture", false),
        };
    }

    private static string? Blank(string? value) => string.IsNullOrWhiteSpace(value) ? null : value;

    private static InvalidOperationException Missing(string key) =>
        new($"Orders:Provider needs the '{key}' connection string.");
}

public static class CloudMartJson
{
    public static JsonSerializerOptions Options { get; } = new(JsonSerializerDefaults.Web)
    {
        Converters = { new JsonStringEnumConverter() },
    };
}
