using CloudMart.Core.Domain;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace CloudMart.Core.Services;

/// <summary>
/// Consumes <see cref="OrderPlaced"/>. Runs in an Azure Function (Service Bus trigger) once messaging is deployed,
/// or in <see cref="InProcess.InProcessOrderWorker"/> before that.
/// </summary>
public sealed class OrderFulfillmentService(
    IOrderRepository orders,
    IProductRepository products,
    IConfiguration config,
    ILogger<OrderFulfillmentService> logger)
{
    public const decimal PaymentLimit = 10_000m;

    public async Task ProcessAsync(OrderPlaced evt, CancellationToken ct = default)
    {
        using var activity = CloudMartTelemetry.Source.StartActivity("FulfillOrder");
        activity?.SetTag("cloudmart.order_id", evt.OrderId);

        if (evt.SimulateFailure)
        {
            // Thrown on every attempt, so Service Bus retries up to maxDeliveryCount and then dead-letters it.
            throw new SimulatedFailureException($"Order {evt.OrderId} requested a simulated processing failure.");
        }

        var order = await orders.GetAsync(evt.OrderId, ct)
            ?? throw new InvalidOperationException($"Order {evt.OrderId} was not found.");

        if (order.Status != OrderStatus.Pending)
        {
            logger.LogInformation("Order {OrderId} is already {Status}; ignoring duplicate delivery", order.Id, order.Status);
            return;
        }

        var delayMs = config.GetValue("Fulfillment:SimulatedDelayMs", 1500);
        if (delayMs > 0)
            await Task.Delay(delayMs, ct);

        var (status, reason) = await DecideAsync(order, ct);
        if (await orders.TryCompleteAsync(order.Id, status, reason, ct))
        {
            CloudMartTelemetry.OrdersCompleted.Add(1, new KeyValuePair<string, object?>("status", status.ToString()));
            logger.LogInformation("Order {OrderId} {Status}: {Reason}", order.Id, status, reason);
        }
        else
        {
            logger.LogInformation("Order {OrderId} was completed by another consumer", order.Id);
        }
    }

    public async Task FlagHighValueAsync(OrderPlaced evt, CancellationToken ct = default)
    {
        await orders.MarkForReviewAsync(evt.OrderId, ct);
        logger.LogWarning("High-value order {OrderId} ({Total}) flagged for manual review", evt.OrderId, evt.Total);
    }

    public void Notify(OrderPlaced evt) =>
        // Swap for Azure Communication Services email or a Logic App in a real system.
        logger.LogInformation("Notification queued for {CustomerName}: order {OrderId} received", evt.CustomerName, evt.OrderId);

    private async Task<(OrderStatus Status, string Reason)> DecideAsync(Order order, CancellationToken ct)
    {
        foreach (var line in order.Lines)
        {
            var product = await products.GetAsync(line.ProductId, ct);
            if (product is null)
                return (OrderStatus.Rejected, $"Product {line.ProductId} no longer exists.");
            if (line.Quantity > product.Stock)
                return (OrderStatus.Rejected, $"Only {product.Stock} x {product.Name} in stock.");
        }

        if (order.Total > PaymentLimit)
            return (OrderStatus.Rejected, $"Payment declined: order exceeds the {PaymentLimit:N0} limit.");

        // PaymentGateway:ApiKey comes from Key Vault (secret "PaymentGateway--ApiKey"). Showing its last four
        // characters proves the secret reached the app without ever putting it in source or app settings.
        var apiKey = config["PaymentGateway:ApiKey"];
        return apiKey is { Length: > 4 }
            ? (OrderStatus.Confirmed, $"Paid via gateway key ****{apiKey[^4..]}")
            : (OrderStatus.Confirmed, "Paid (no gateway key configured)");
    }
}
