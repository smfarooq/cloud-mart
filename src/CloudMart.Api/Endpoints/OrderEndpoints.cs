using System.Security.Claims;
using CloudMart.Core;
using CloudMart.Core.Domain;
using CloudMart.Core.Services;
using Microsoft.AspNetCore.Mvc;
using Microsoft.FeatureManagement;

namespace CloudMart.Api.Endpoints;

public static class OrderEndpoints
{
    public static void MapOrderEndpoints(this IEndpointRouteBuilder app)
    {
        var orders = app.MapGroup("/api/orders").WithTags("Orders").RequireAuthorization(Policies.User);

        orders.MapGet("/", async (bool? all, ClaimsPrincipal user, IOrderRepository repo, CancellationToken ct) =>
        {
            var customer = user.ToCustomer();
            return all == true && customer.IsAdmin
                ? await repo.ListRecentAsync(50, ct)
                : await repo.ListByCustomerAsync(customer.Id, 50, ct);
        });

        orders.MapGet("/{id:guid}", async (Guid id, ClaimsPrincipal user, IOrderRepository repo, CancellationToken ct) =>
        {
            var customer = user.ToCustomer();
            var order = await repo.GetAsync(id, ct);
            // 404 rather than 403 for someone else's order, so ids can't be probed.
            return order is not null && (order.CustomerId == customer.Id || customer.IsAdmin) ? Results.Ok(order) : Results.NotFound();
        });

        // 202 Accepted: the order is stored, but confirmation happens asynchronously (Service Bus -> Function).
        // A retry with the same Idempotency-Key gets the same 202 and the same order, never a second one.
        orders.MapPost("/", async (
            PlaceOrderRequest request,
            [FromHeader(Name = "Idempotency-Key")] string? idempotencyKey,
            ClaimsPrincipal user,
            OrderService service,
            CancellationToken ct) =>
        {
            try
            {
                var order = await service.PlaceOrderAsync(user.ToCustomer(), request, idempotencyKey, ct);
                return Results.Accepted($"/api/orders/{order.Id}", order);
            }
            catch (OrderValidationException ex)
            {
                return Results.Problem(ex.Message, statusCode: 400);
            }
            catch (IdempotencyConflictException ex)
            {
                return Results.Problem(ex.Message, statusCode: 422);
            }
        });
    }

    public static void MapTelemetryEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapPost("/api/telemetry", async (TelemetryEvent[] events, ITelemetryPublisher publisher, CancellationToken ct) =>
        {
            if (events.Length is 0 or > 100)
                return Results.Problem("Send between 1 and 100 events.", statusCode: 400);

            var accepted = events
                .Where(e => e.Type is { Length: > 0 and <= 50 } && (e.ProductId?.Length ?? 0) <= 64 && (e.SessionId?.Length ?? 0) <= 64)
                .Select(e => e with { Timestamp = e.Timestamp ?? DateTimeOffset.UtcNow })
                .ToList();
            await publisher.PublishAsync(accepted, ct);
            return Results.Accepted();
        }).WithTags("Telemetry");
    }

    public static void MapPlatformEndpoints(this IEndpointRouteBuilder app)
    {
        app.MapGet("/api/platform/info", (PlatformInfoProvider platform, IFeatureManager features, IFeatureDefinitionProvider definitions) =>
                platform.GetAsync(features, definitions))
            .WithTags("Platform");

        // App roles are in the API's access token, not the SPA's ID token, so the SPA asks the API who you are.
        app.MapGet("/api/me", (ClaimsPrincipal user) => user.ToCustomer())
            .RequireAuthorization(Policies.User)
            .WithTags("Platform");

        // Chaos endpoints generate something to find in Application Insights during phase 7.
        var chaos = app.MapGroup("/api/platform/chaos").WithTags("Platform").RequireAuthorization(Policies.Admin);

        chaos.MapPost("/exception", IResult () =>
            throw new InvalidOperationException("Deliberate failure from /api/platform/chaos/exception. Find me under Failures in Application Insights."));

        chaos.MapPost("/latency", async (int? ms, CancellationToken ct) =>
        {
            var delay = Math.Clamp(ms ?? 3000, 0, 30_000);
            await Task.Delay(delay, ct);
            return Results.Ok(new { delayedMs = delay });
        });

        chaos.MapPost("/dependency", async (IHttpClientFactory httpClients, CancellationToken ct) =>
        {
            try
            {
                await httpClients.CreateClient().GetAsync("https://cloudmart-missing-dependency.invalid/", ct);
                return Results.Ok();
            }
            catch (HttpRequestException ex)
            {
                return Results.Problem($"Dependency call failed as intended: {ex.Message}", statusCode: 502);
            }
        });
    }
}
