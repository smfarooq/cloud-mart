using CloudMart.Core.Domain;
using CloudMart.Core.Payments;
using CloudMart.Core.Services;
using CloudMart.Core.Shipping;
using Microsoft.Extensions.Configuration;

namespace CloudMart.Core.Tests;

/// <summary>The saga's failure paths, driven by a scripted context: exactly what Durable Functions replays.</summary>
public class OrderSagaTests
{
    private static readonly OrderPlaced Order = new(Guid.NewGuid(), "user-1", "Test User", 120m, 2, false, DateTimeOffset.UtcNow);

    [Fact]
    public async Task Happy_path_charges_ships_and_confirms()
    {
        var saga = new ScriptedSaga();

        var outcome = await OrderSaga.RunAsync(saga, Order);

        Assert.Equal(OrderStatus.Confirmed, outcome!.Status);
        Assert.Equal(new[] { "prepare", "charge", "ship", "complete" }, saga.Steps);
        Assert.Equal("CM-TRACK", outcome.TrackingNumber);
    }

    [Fact]
    public async Task Declined_payment_rejects_without_shipping_or_refunding()
    {
        var saga = new ScriptedSaga { PaymentStatus = PaymentStatus.Declined };

        var outcome = await OrderSaga.RunAsync(saga, Order);

        Assert.Equal(OrderStatus.Rejected, outcome!.Status);
        Assert.Equal(new[] { "prepare", "charge", "complete" }, saga.Steps);
    }

    [Fact]
    public async Task Shipping_outage_after_payment_triggers_a_refund()
    {
        var saga = new ScriptedSaga { ShipFailure = new HttpRequestException("503 Service Unavailable") };

        var outcome = await OrderSaga.RunAsync(saga, Order);

        Assert.Equal(OrderStatus.Rejected, outcome!.Status);
        Assert.Equal(new[] { "prepare", "charge", "ship", "refund", "complete" }, saga.Steps);
        Assert.False(outcome.ReviewRequired);
    }

    [Fact]
    public async Task Failed_refund_flags_the_order_for_a_person()
    {
        var saga = new ScriptedSaga
        {
            ShipFailure = new HttpRequestException("503"),
            RefundFailure = new HttpRequestException("payments down too"),
        };

        var outcome = await OrderSaga.RunAsync(saga, Order);

        Assert.True(outcome!.ReviewRequired);
        Assert.Contains("FAILED", outcome.Reason);
    }

    [Fact]
    public async Task Unknown_payment_result_flags_for_review_and_does_not_ship()
    {
        var saga = new ScriptedSaga { ChargeFailure = new TimeoutException("no answer from the Payments API") };

        var outcome = await OrderSaga.RunAsync(saga, Order);

        Assert.True(outcome!.ReviewRequired);
        Assert.Equal(new[] { "prepare", "charge", "complete" }, saga.Steps);
    }

    [Fact]
    public async Task Already_completed_order_is_left_alone()
    {
        var saga = new ScriptedSaga { Pending = false };

        Assert.Null(await OrderSaga.RunAsync(saga, Order));
        Assert.Equal(new[] { "prepare" }, saga.Steps);
    }

    private sealed class ScriptedSaga : IOrderSagaContext
    {
        public List<string> Steps { get; } = [];
        public bool Pending { get; init; } = true;
        public PaymentStatus PaymentStatus { get; init; } = PaymentStatus.Captured;
        public Exception? ChargeFailure { get; init; }
        public Exception? ShipFailure { get; init; }
        public Exception? RefundFailure { get; init; }

        public Task<OrderCheck> PrepareAsync(OrderPlaced order) => Step("prepare", new OrderCheck(Pending, null));

        public Task<Payment> ChargeAsync(OrderPlaced order) =>
            Step("charge", new Payment { Id = "pay_1", OrderId = order.OrderId, Status = PaymentStatus, Reason = "test" }, ChargeFailure);

        public Task<ShipmentResult> ShipAsync(OrderPlaced order) =>
            Step("ship", new ShipmentResult(new Shipment { OrderId = order.OrderId, Carrier = "Test", TrackingNumber = "CM-TRACK" }, null), ShipFailure);

        public Task<Payment> RefundAsync(RefundCommand command) =>
            Step("refund", new Payment { Id = command.PaymentId, Status = PaymentStatus.Refunded }, RefundFailure);

        public Task<bool> CompleteAsync(OrderCompletion completion) => Step("complete", true);

        private Task<T> Step<T>(string name, T result, Exception? failure = null)
        {
            Steps.Add(name);
            return failure is null ? Task.FromResult(result) : Task.FromException<T>(failure);
        }
    }
}

public class PaymentProcessorTests
{
    private readonly InMemoryPaymentStore _store = new();
    private readonly PaymentProcessor _processor;

    public PaymentProcessorTests() =>
        _processor = new PaymentProcessor(_store, new ConfigurationBuilder()
            .AddInMemoryCollection(new Dictionary<string, string?> { ["PaymentGateway:ApiKey"] = "secret-1234" })
            .Build());

    [Fact]
    public async Task Same_idempotency_key_charges_once()
    {
        var request = new ChargeRequest(Guid.NewGuid(), "user-1", 100m);

        var (first, created) = await _processor.ChargeAsync(request, request.IdempotencyKey);
        var (second, createdAgain) = await _processor.ChargeAsync(request, request.IdempotencyKey);

        Assert.True(created);
        Assert.False(createdAgain);
        Assert.Equal(first.Id, second.Id);
        Assert.Equal("charged via gateway key ****1234", first.Reason);
    }

    [Fact]
    public async Task Reusing_a_key_for_another_order_is_a_conflict()
    {
        var request = new ChargeRequest(Guid.NewGuid(), "user-1", 100m);
        await _processor.ChargeAsync(request, "key-1");

        await Assert.ThrowsAsync<PaymentConflictException>(() =>
            _processor.ChargeAsync(request with { OrderId = Guid.NewGuid() }, "key-1"));
    }

    [Fact]
    public async Task Over_the_limit_is_declined_and_cannot_be_refunded()
    {
        var request = new ChargeRequest(Guid.NewGuid(), "user-1", PaymentRules.Limit + 1);

        var (payment, _) = await _processor.ChargeAsync(request, request.IdempotencyKey);

        Assert.Equal(PaymentStatus.Declined, payment.Status);
        await Assert.ThrowsAsync<PaymentConflictException>(() => _processor.RefundAsync(payment.Id, "test"));
    }

    [Fact]
    public async Task Refund_is_idempotent()
    {
        var request = new ChargeRequest(Guid.NewGuid(), "user-1", 100m);
        var (payment, _) = await _processor.ChargeAsync(request, request.IdempotencyKey);

        var first = await _processor.RefundAsync(payment.Id, "shipping failed");
        var second = await _processor.RefundAsync(payment.Id, "retry");

        Assert.Equal(PaymentStatus.Refunded, first!.Status);
        Assert.Equal(first.Reason, second!.Reason); // the retry changed nothing
    }
}

public class ShippingProcessorTests
{
    private readonly ShippingProcessor _processor = new(new InMemoryShipmentStore());

    [Fact]
    public async Task Scheduling_twice_returns_the_same_shipment()
    {
        var orderId = Guid.NewGuid();
        var request = new ShipmentRequest("Test User", 2, 120m);

        var (first, created) = await _processor.ScheduleAsync(orderId, request);
        var (second, createdAgain) = await _processor.ScheduleAsync(orderId, request);

        Assert.True(created);
        Assert.False(createdAgain);
        Assert.Equal(first.Shipment!.TrackingNumber, second.Shipment!.TrackingNumber);
        Assert.Equal("Fabrikam Post", first.Shipment.Carrier);
    }

    [Fact]
    public async Task Too_many_items_is_a_business_rejection()
    {
        var (result, _) = await _processor.ScheduleAsync(Guid.NewGuid(), new ShipmentRequest("Test User", ShippingRules.MaxItemsPerParcel + 1, 100m));

        Assert.Null(result.Shipment);
        Assert.NotNull(result.Rejection);
    }
}
