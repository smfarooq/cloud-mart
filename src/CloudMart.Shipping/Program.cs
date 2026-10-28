using System.Text.Json.Serialization;
using Azure.Data.Tables;
using Azure.Identity;
using CloudMart.Core;
using CloudMart.Core.Shipping;
using CloudMart.ServiceDefaults;
using CloudMart.Shipping;

// The Shipping service (phase 16). Like Payments: called only by the order saga, protected by an app role, and
// reachable only through a private endpoint once the network phase is in place.
var builder = WebApplication.CreateBuilder(args);
var config = builder.Configuration;

builder.AddCloudMartObservability();
var entraEnabled = builder.AddCloudMartServiceAuth(ShippingApi.ManageRole);
builder.Services.AddCloudMartChaos(config);
builder.Services.AddCloudMartHealth();
builder.Services.AddProblemDetails();
builder.Services.AddOpenApi();
builder.Services.ConfigureHttpJsonOptions(o => o.SerializerOptions.Converters.Add(new JsonStringEnumConverter()));

// Table Storage with the managed identity (Shipping:TableEndpoint), Azurite via a connection string, or memory.
var tableEndpoint = config["Shipping:TableEndpoint"];
var tableConnection = config.GetConnectionString("ShipmentsTable");
var useTable = !string.IsNullOrEmpty(tableEndpoint) || !string.IsNullOrEmpty(tableConnection);
if (useTable)
{
    var tables = !string.IsNullOrEmpty(tableConnection)
        ? new TableServiceClient(tableConnection)
        : new TableServiceClient(new Uri(tableEndpoint!), new DefaultAzureCredential());
    builder.Services.AddSingleton(tables.GetTableClient(config["Shipping:TableName"] ?? "shipments"));
    builder.Services.AddSingleton<TableShipmentStore>();
    builder.Services.AddSingleton<IShipmentStore>(sp => sp.GetRequiredService<TableShipmentStore>());
    builder.Services.AddSingleton<IHealthProbe>(sp => sp.GetRequiredService<TableShipmentStore>());
}
else
{
    builder.Services.AddSingleton<IShipmentStore, InMemoryShipmentStore>();
}
builder.Services.AddSingleton<ShippingProcessor>();

var app = builder.Build();

if (useTable)
{
    try
    {
        // Bicep creates the table; this covers Azurite and fresh accounts.
        await app.Services.GetRequiredService<TableClient>().CreateIfNotExistsAsync();
    }
    catch (Exception ex)
    {
        app.Logger.LogError(ex, "Could not reach the shipments table; /health/ready will show why");
    }
}

if (!entraEnabled)
    app.Logger.LogWarning("Entra ID is not configured: every caller gets the {Role} role. Never expose this beyond a lab.", ShippingApi.ManageRole);

app.UseExceptionHandler();
app.UseStatusCodePages();
app.UseAuthentication();
app.UseAuthorization();
app.UseCloudMartChaos();

app.MapOpenApi();
app.MapCloudMartHealth();

var shipments = app.MapGroup("/shipments").WithTags("Shipments").RequireAuthorization(ServicePolicies.Caller);

// PUT, because the caller names the resource (one shipment per order). PUT is idempotent by definition, so a retry
// needs no extra header: same URL, same result. Compare POST + Idempotency-Key in the Payments API.
shipments.MapPut("/{orderId:guid}", async (Guid orderId, ShipmentRequest request, ShippingProcessor processor, CancellationToken ct) =>
{
    var (result, created) = await processor.ScheduleAsync(orderId, request, ct);
    if (result.Shipment is not { } shipment)
        return Results.Problem(result.Rejection, title: "Shipment rejected", statusCode: StatusCodes.Status422UnprocessableEntity);
    return created ? Results.Created($"/shipments/{orderId}", shipment) : Results.Ok(shipment);
});

shipments.MapGet("/{orderId:guid}", async (Guid orderId, IShipmentStore store, CancellationToken ct) =>
    await store.GetAsync(orderId, ct) is { } shipment ? Results.Ok(shipment) : Results.NotFound());

shipments.MapPost("/{orderId:guid}/cancel", async (Guid orderId, CancelShipmentRequest request, ShippingProcessor processor, CancellationToken ct) =>
    await processor.CancelAsync(orderId, request.Reason, ct) is { } shipment ? Results.Ok(shipment) : Results.NotFound());

app.Run();
