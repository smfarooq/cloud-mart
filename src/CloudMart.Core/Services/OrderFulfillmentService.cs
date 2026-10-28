using CloudMart.Core.Domain;
using Microsoft.Extensions.Logging;

namespace CloudMart.Core.Services;

/// <summary>
/// Consumes <see cref="OrderPlaced"/> in-process (<see cref="InProcess.InProcessOrderWorker"/>). Once messaging is
/// deployed, the Functions app runs the same <see cref="OrderSaga"/> as a Durable Functions orchestration instead.
/// </summary>
public sealed class OrderFulfillmentService(
    OrderSagaActivities activities,
    IOrderRepository orders,
    ILogger<OrderFulfillmentService> logger)
{
    public async Task ProcessAsync(OrderPlaced evt, CancellationToken ct = default)
    {
        using var activity = CloudMartTelemetry.Source.StartActivity("FulfillOrder");
        activity?.SetTag("cloudmart.order_id", evt.OrderId);

        ThrowIfSimulatedFailure(evt);

        var outcome = await OrderSaga.RunAsync(new InProcessOrderSagaContext(activities, ct), evt);
        activity?.SetTag("cloudmart.order_status", outcome?.Status.ToString() ?? "duplicate");
    }

    /// <summary>Thrown on every attempt, so Service Bus retries up to maxDeliveryCount and then dead-letters it.</summary>
    public static void ThrowIfSimulatedFailure(OrderPlaced evt)
    {
        if (evt.SimulateFailure)
            throw new SimulatedFailureException($"Order {evt.OrderId} requested a simulated processing failure.");
    }

    public async Task FlagHighValueAsync(OrderPlaced evt, CancellationToken ct = default)
    {
        await orders.MarkForReviewAsync(evt.OrderId, ct);
        logger.LogWarning("High-value order {OrderId} ({Total}) flagged for manual review", evt.OrderId, evt.Total);
    }

    public void Notify(OrderPlaced evt) =>
        // Swap for Azure Communication Services email or a Logic App in a real system.
        logger.LogInformation("Notification queued for {CustomerName}: order {OrderId} received", evt.CustomerName, evt.OrderId);
}
