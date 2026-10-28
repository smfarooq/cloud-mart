using System.Text.Json.Serialization;
using CloudMart.Core;
using CloudMart.Core.Payments;
using CloudMart.Payments;
using CloudMart.ServiceDefaults;
using Microsoft.AspNetCore.Mvc;
using Microsoft.EntityFrameworkCore;

// The Payments service (phase 16). Only the order saga calls it, never a browser: no CORS, an app role instead of
// a user scope, and in Azure a private endpoint instead of a public address. It is also the only workload that may
// read the payment-gateway secret.
var builder = WebApplication.CreateBuilder(args);
var config = builder.Configuration;

builder.AddCloudMartObservability();
var entraEnabled = builder.AddCloudMartServiceAuth(PaymentsApi.ProcessRole);
builder.Services.AddCloudMartChaos(config);
builder.Services.AddCloudMartHealth();
builder.Services.AddProblemDetails();
builder.Services.AddOpenApi();
builder.Services.ConfigureHttpJsonOptions(o => o.SerializerOptions.Converters.Add(new JsonStringEnumConverter()));

// Azure SQL with Entra auth ("Authentication=Active Directory Managed Identity" in the connection string), or memory.
var sql = config.GetConnectionString("PaymentsSql");
if (!string.IsNullOrEmpty(sql))
{
    builder.Services.AddDbContext<PaymentsDbContext>(o => o.UseSqlServer(sql, s => s.EnableRetryOnFailure()));
    builder.Services.AddScoped<LedgerPaymentStore>();
    builder.Services.AddScoped<IPaymentStore>(sp => sp.GetRequiredService<LedgerPaymentStore>());
    builder.Services.AddScoped<IHealthProbe>(sp => sp.GetRequiredService<LedgerPaymentStore>());
}
else
{
    builder.Services.AddSingleton<IPaymentStore, InMemoryPaymentStore>();
}
builder.Services.AddScoped<PaymentProcessor>();

var app = builder.Build();

if (!string.IsNullOrEmpty(sql) && config.GetValue("Payments:EnsureCreated", true))
{
    try
    {
        // Lab shortcut, like the orders schema: production would run this from the pipeline, not with the app's identity.
        await using var scope = app.Services.CreateAsyncScope();
        await scope.ServiceProvider.GetRequiredService<PaymentsDbContext>().Database.ExecuteSqlRawAsync(PaymentsDbContext.CreateLedgerTableSql);
        app.Logger.LogInformation("Payments ledger table is ready");
    }
    catch (Exception ex)
    {
        app.Logger.LogError(ex, "Could not prepare the payments database; /health/ready will show why");
    }
}

if (!entraEnabled)
    app.Logger.LogWarning("Entra ID is not configured: every caller gets the {Role} role. Never expose this beyond a lab.", PaymentsApi.ProcessRole);

app.UseExceptionHandler();
app.UseStatusCodePages();
app.UseAuthentication();
app.UseAuthorization();
app.UseCloudMartChaos();

app.MapOpenApi();
app.MapCloudMartHealth();

var payments = app.MapGroup("/payments").WithTags("Payments").RequireAuthorization(ServicePolicies.Caller);

// POST, because the server picks the payment id. The Idempotency-Key header is what makes retrying a POST safe:
// a repeated key returns the first result (200) instead of charging again (201).
payments.MapPost("/", async (
    ChargeRequest request,
    [FromHeader(Name = "Idempotency-Key")] string? idempotencyKey,
    PaymentProcessor processor,
    CancellationToken ct) =>
{
    if (string.IsNullOrWhiteSpace(idempotencyKey) || idempotencyKey.Length > 100)
        return Results.Problem("Send an Idempotency-Key header (up to 100 characters). Retries must reuse it.", statusCode: 400);

    try
    {
        var (payment, created) = await processor.ChargeAsync(request, idempotencyKey, ct);
        return created ? Results.Created($"/payments/{payment.Id}", payment) : Results.Ok(payment);
    }
    catch (PaymentConflictException ex)
    {
        return Results.Problem(ex.Message, statusCode: 409);
    }
});

payments.MapGet("/{id}", async (string id, IPaymentStore store, CancellationToken ct) =>
    await store.GetAsync(id, ct) is { } payment ? Results.Ok(payment) : Results.NotFound());

payments.MapGet("/", async (Guid orderId, IPaymentStore store, CancellationToken ct) =>
    await store.GetByOrderAsync(orderId, ct) is { } payment ? Results.Ok(payment) : Results.NotFound());

// The saga's compensating action. Refunding twice returns the refunded payment again.
payments.MapPost("/{id}/refund", async (string id, RefundRequest request, PaymentProcessor processor, CancellationToken ct) =>
{
    try
    {
        return await processor.RefundAsync(id, request.Reason, ct) is { } payment ? Results.Ok(payment) : Results.NotFound();
    }
    catch (PaymentConflictException ex)
    {
        return Results.Problem(ex.Message, statusCode: 409);
    }
});

app.Run();
