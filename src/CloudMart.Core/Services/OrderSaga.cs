using CloudMart.Core.Domain;
using CloudMart.Core.Payments;
using CloudMart.Core.Shipping;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace CloudMart.Core.Services;

/// <summary>
/// The steps of the order saga. Each one is a separate unit of work: an activity function under Durable Functions
/// (with its own retries and checkpoint), or a direct call when the saga runs in-process.
/// </summary>
public interface IOrderSagaContext
{
    Task<OrderCheck> PrepareAsync(OrderPlaced order);
    Task<Payment> ChargeAsync(OrderPlaced order);
    Task<ShipmentResult> ShipAsync(OrderPlaced order);
    Task<Payment> RefundAsync(RefundCommand command);
    Task<bool> CompleteAsync(OrderCompletion completion);
}

public sealed record OrderCheck(bool Pending, string? Problem);

public sealed record RefundCommand(string PaymentId, string Reason);

public sealed record OrderCompletion(Guid OrderId, OrderOutcome Outcome);

/// <summary>
/// Charge, then ship; if shipping fails, refund. There is no distributed transaction across the Payments and
/// Shipping services, so each step commits on its own and a compensating step undoes the earlier one.
/// </summary>
/// <remarks>
/// Under Durable Functions this method IS the orchestrator, replayed from its history after every step. It must be
/// deterministic: no clocks, GUIDs, random numbers or I/O here, only calls through <see cref="IOrderSagaContext"/>.
/// </remarks>
public static class OrderSaga
{
    /// <summary>Returns the outcome, or null if the order was already completed (a duplicate start).</summary>
    public static async Task<OrderOutcome?> RunAsync(IOrderSagaContext saga, OrderPlaced order)
    {
        var check = await saga.PrepareAsync(order);
        if (!check.Pending)
            return null;

        var outcome = check.Problem is { } problem
            ? new OrderOutcome(OrderStatus.Rejected, problem)
            : await ChargeAndShipAsync(saga, order);

        await saga.CompleteAsync(new OrderCompletion(order.OrderId, outcome));
        return outcome;
    }

    private static async Task<OrderOutcome> ChargeAndShipAsync(IOrderSagaContext saga, OrderPlaced order)
    {
        // Step 1: charge. A decline is a business answer: nothing happened, so there is nothing to undo.
        Payment payment;
        try
        {
            payment = await saga.ChargeAsync(order);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // Retries are exhausted and we don't know whether the charge went through. Reject, and flag it so a
            // person checks for an orphaned payment (same idempotency key, so a later retry can't double-charge).
            return new OrderOutcome(OrderStatus.Rejected, $"Payment service unavailable: {FirstLine(ex)}", ReviewRequired: true);
        }

        if (payment.Status != PaymentStatus.Captured)
            return new OrderOutcome(OrderStatus.Rejected, $"Payment declined: {payment.Reason}.", payment.Id);

        // Step 2: ship. From here on a failure must undo step 1.
        string failure;
        try
        {
            var result = await saga.ShipAsync(order);
            if (result.Shipment is { } shipment)
            {
                return new OrderOutcome(
                    OrderStatus.Confirmed,
                    $"Paid ({payment.Reason}) and shipping with {shipment.Carrier}.",
                    payment.Id,
                    shipment.TrackingNumber);
            }

            failure = $"Shipping rejected: {result.Rejection}";
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            failure = $"Shipping service unavailable: {FirstLine(ex)}";
        }

        // Step 3 (compensation): refund the charge.
        try
        {
            await saga.RefundAsync(new RefundCommand(payment.Id, failure));
            return new OrderOutcome(OrderStatus.Rejected, $"{failure}. Payment {payment.Id} was refunded.", payment.Id);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return new OrderOutcome(
                OrderStatus.Rejected,
                $"{failure}. Refunding payment {payment.Id} FAILED ({FirstLine(ex)}): needs manual review.",
                payment.Id,
                ReviewRequired: true);
        }
    }

    private static string FirstLine(Exception ex) => ex.Message.Split('\n')[0].Trim();
}

/// <summary>What each saga step does. Shared by the in-process runner and the Durable activity functions.</summary>
public sealed class OrderSagaActivities(
    IOrderRepository orders,
    IProductRepository products,
    IPaymentGateway payments,
    IShippingGateway shipping,
    IConfiguration config,
    ILogger<OrderSagaActivities> logger)
{
    public async Task<OrderCheck> PrepareAsync(OrderPlaced evt, CancellationToken ct = default)
    {
        var order = await orders.GetAsync(evt.OrderId, ct)
            ?? throw new InvalidOperationException($"Order {evt.OrderId} was not found.");

        if (order.Status != OrderStatus.Pending)
        {
            logger.LogInformation("Order {OrderId} is already {Status}; ignoring duplicate delivery", order.Id, order.Status);
            return new OrderCheck(false, null);
        }

        // Long enough to watch the order sit in Pending in the UI.
        var delayMs = config.GetValue("Fulfillment:SimulatedDelayMs", 1500);
        if (delayMs > 0)
            await Task.Delay(delayMs, ct);

        foreach (var line in order.Lines)
        {
            var product = await products.GetAsync(line.ProductId, ct);
            if (product is null)
                return new OrderCheck(true, $"Product {line.ProductId} no longer exists.");
            if (line.Quantity > product.Stock)
                return new OrderCheck(true, $"Only {product.Stock} x {product.Name} in stock.");
        }

        return new OrderCheck(true, null);
    }

    public Task<Payment> ChargeAsync(OrderPlaced evt, CancellationToken ct = default) =>
        payments.ChargeAsync(new ChargeRequest(evt.OrderId, evt.CustomerId, evt.Total), ct);

    public Task<ShipmentResult> ShipAsync(OrderPlaced evt, CancellationToken ct = default) =>
        shipping.ScheduleAsync(evt.OrderId, new ShipmentRequest(evt.CustomerName, evt.ItemCount, evt.Total), ct);

    public async Task<Payment> RefundAsync(RefundCommand command, CancellationToken ct = default)
    {
        logger.LogWarning("Compensating: refunding payment {PaymentId} because {Reason}", command.PaymentId, command.Reason);
        return await payments.RefundAsync(command.PaymentId, command.Reason, ct);
    }

    public async Task<bool> CompleteAsync(OrderCompletion completion, CancellationToken ct = default)
    {
        var (orderId, outcome) = completion;
        if (!await orders.TryCompleteAsync(orderId, outcome, ct))
        {
            logger.LogInformation("Order {OrderId} was completed by another consumer", orderId);
            return false;
        }

        CloudMartTelemetry.OrdersCompleted.Add(1, new KeyValuePair<string, object?>("status", outcome.Status.ToString()));
        logger.LogInformation("Order {OrderId} {Status}: {Reason}", orderId, outcome.Status, outcome.Reason);
        return true;
    }
}

/// <summary>Runs the saga steps directly, one after another. No checkpoints: a crash mid-saga loses its place.</summary>
public sealed class InProcessOrderSagaContext(OrderSagaActivities activities, CancellationToken ct) : IOrderSagaContext
{
    public Task<OrderCheck> PrepareAsync(OrderPlaced order) => activities.PrepareAsync(order, ct);
    public Task<Payment> ChargeAsync(OrderPlaced order) => activities.ChargeAsync(order, ct);
    public Task<ShipmentResult> ShipAsync(OrderPlaced order) => activities.ShipAsync(order, ct);
    public Task<Payment> RefundAsync(RefundCommand command) => activities.RefundAsync(command, ct);
    public Task<bool> CompleteAsync(OrderCompletion completion) => activities.CompleteAsync(completion, ct);
}
