using CloudMart.Core;
using CloudMart.Core.Domain;
using CloudMart.Core.InMemory;
using CloudMart.Core.InProcess;
using CloudMart.Core.Payments;
using CloudMart.Core.Services;
using CloudMart.Core.Shipping;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;

namespace CloudMart.Core.Tests;

public class OrderFlowTests
{
    private readonly InMemoryProductRepository _products = new();
    private readonly InMemoryOrderRepository _orders = new();
    private readonly InMemoryPaymentStore _payments = new();
    private readonly InMemoryShipmentStore _shipments = new();
    private readonly RecordingPublisher _publisher = new();
    private readonly Customer _customer = new("user-1", "Test User", IsAdmin: false);

    private static readonly IConfiguration NoDelay =
        new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["Fulfillment:SimulatedDelayMs"] = "0" }).Build();

    public OrderFlowTests()
    {
        foreach (var product in CatalogSeed.Products)
            _products.UpsertAsync(product).GetAwaiter().GetResult();
    }

    [Fact]
    public async Task PlaceOrder_prices_from_catalog_and_publishes_event()
    {
        var order = await NewOrderService().PlaceOrderAsync(_customer, new PlaceOrderRequest([new("woodgrove-desk-lamp", 2)]));

        Assert.Equal(OrderStatus.Pending, order.Status);
        Assert.Equal(118m, order.Total);
        var evt = Assert.Single(_publisher.Published);
        Assert.Equal(order.Id, evt.OrderId);
    }

    [Fact]
    public async Task PlaceOrder_rejects_unknown_product()
    {
        await Assert.ThrowsAsync<OrderValidationException>(() =>
            NewOrderService().PlaceOrderAsync(_customer, new PlaceOrderRequest([new("does-not-exist", 1)])));
        Assert.Empty(_publisher.Published);
    }

    [Fact]
    public async Task PlaceOrder_with_the_same_idempotency_key_returns_the_same_order()
    {
        var service = NewOrderService();
        var request = new PlaceOrderRequest([new("woodgrove-desk-lamp", 2)]);

        var first = await service.PlaceOrderAsync(_customer, request, "checkout-1");
        var retry = await service.PlaceOrderAsync(_customer, request, "checkout-1");

        Assert.Equal(first.Id, retry.Id);
        Assert.Single(await _orders.ListByCustomerAsync(_customer.Id, 10));
        // Still Pending, so the retry publishes again (same order id): duplicate detection and the saga absorb it.
        Assert.All(_publisher.Published, evt => Assert.Equal(first.Id, evt.OrderId));
    }

    [Fact]
    public async Task PlaceOrder_retry_after_fulfillment_returns_the_result_without_publishing()
    {
        var service = NewOrderService();
        var request = new PlaceOrderRequest([new("woodgrove-desk-lamp", 1)]);
        await service.PlaceOrderAsync(_customer, request, "checkout-2");
        await NewFulfillment().ProcessAsync(_publisher.Published.Single());

        var retry = await service.PlaceOrderAsync(_customer, request, "checkout-2");

        Assert.Equal(OrderStatus.Confirmed, retry.Status);
        Assert.Single(_publisher.Published);
    }

    [Fact]
    public async Task PlaceOrder_rejects_a_key_reused_for_a_different_order()
    {
        var service = NewOrderService();
        await service.PlaceOrderAsync(_customer, new PlaceOrderRequest([new("woodgrove-desk-lamp", 1)]), "checkout-3");

        await Assert.ThrowsAsync<IdempotencyConflictException>(() =>
            service.PlaceOrderAsync(_customer, new PlaceOrderRequest([new("woodgrove-desk-lamp", 2)]), "checkout-3"));
        Assert.Single(_publisher.Published);
    }

    [Fact]
    public async Task PlaceOrder_keys_belong_to_one_customer()
    {
        var service = NewOrderService();
        var request = new PlaceOrderRequest([new("woodgrove-desk-lamp", 1)]);

        var mine = await service.PlaceOrderAsync(_customer, request, "same-key");
        var theirs = await service.PlaceOrderAsync(new Customer("user-2", "Someone Else", IsAdmin: false), request, "same-key");

        Assert.NotEqual(mine.Id, theirs.Id);
    }

    [Theory]
    [InlineData("")]
    [InlineData("has a space")]
    [InlineData("ключ")]
    public async Task PlaceOrder_rejects_a_malformed_idempotency_key(string key)
    {
        await Assert.ThrowsAsync<OrderValidationException>(() =>
            NewOrderService().PlaceOrderAsync(_customer, new PlaceOrderRequest([new("woodgrove-desk-lamp", 1)]), key));
        Assert.Empty(_publisher.Published);
    }

    [Theory]
    [InlineData("woodgrove-desk-lamp", 1, OrderStatus.Confirmed)]
    [InlineData("fabrikam-studio-mic", 4, OrderStatus.Rejected)]     // only 3 in stock
    [InlineData("contoso-workstation-16", 3, OrderStatus.Rejected)]  // over the payment limit
    [InlineData("woodgrove-desk-lamp", 11, OrderStatus.Rejected)]    // too many items for one parcel: refunded
    public async Task Fulfillment_applies_business_rules(string productId, int quantity, OrderStatus expected)
    {
        var order = await NewOrderService().PlaceOrderAsync(_customer, new PlaceOrderRequest([new(productId, quantity)]));

        await NewFulfillment().ProcessAsync(_publisher.Published.Single());

        Assert.Equal(expected, (await _orders.GetAsync(order.Id))!.Status);
    }

    [Fact]
    public async Task Confirmed_order_records_payment_and_tracking_number()
    {
        var order = await NewOrderService().PlaceOrderAsync(_customer, new PlaceOrderRequest([new("woodgrove-desk-lamp", 2)]));

        await NewFulfillment().ProcessAsync(_publisher.Published.Single());

        var stored = (await _orders.GetAsync(order.Id))!;
        var payment = await _payments.GetByOrderAsync(order.Id);
        Assert.Equal(PaymentStatus.Captured, payment!.Status);
        Assert.Equal(payment.Id, stored.PaymentId);
        Assert.Equal(ShippingRules.TrackingNumber(order.Id), stored.TrackingNumber);
    }

    [Fact]
    public async Task Shipping_rejection_refunds_the_payment()
    {
        var order = await NewOrderService().PlaceOrderAsync(_customer, new PlaceOrderRequest([new("woodgrove-desk-lamp", 11)]));

        await NewFulfillment().ProcessAsync(_publisher.Published.Single());

        var stored = (await _orders.GetAsync(order.Id))!;
        var payment = await _payments.GetByOrderAsync(order.Id);
        Assert.Equal(PaymentStatus.Refunded, payment!.Status);
        Assert.Contains("refunded", stored.StatusReason);
        Assert.Null(await _shipments.GetAsync(order.Id));
    }

    [Fact]
    public async Task Fulfillment_is_idempotent_under_redelivery()
    {
        var order = await NewOrderService().PlaceOrderAsync(_customer, new PlaceOrderRequest([new("woodgrove-desk-lamp", 1)]));
        var evt = _publisher.Published.Single();
        var fulfillment = NewFulfillment();

        await fulfillment.ProcessAsync(evt);
        var firstUpdate = (await _orders.GetAsync(order.Id))!.UpdatedUtc;
        await fulfillment.ProcessAsync(evt); // Service Bus delivers at least once

        Assert.Equal(firstUpdate, (await _orders.GetAsync(order.Id))!.UpdatedUtc);
    }

    [Fact]
    public async Task Simulated_failure_throws_so_the_broker_can_retry_and_dead_letter()
    {
        await NewOrderService().PlaceOrderAsync(_customer, new PlaceOrderRequest([new("woodgrove-desk-lamp", 1)], SimulateFailure: true));

        await Assert.ThrowsAsync<SimulatedFailureException>(() => NewFulfillment().ProcessAsync(_publisher.Published.Single()));
    }

    [Fact]
    public async Task View_aggregator_counts_only_product_views()
    {
        var stats = new InMemoryProductStatsRepository();
        var applied = await new ProductViewAggregator(stats).ApplyAsync(
        [
            new(TelemetryEvent.ProductView, "a", "s1", null),
            new(TelemetryEvent.ProductView, "a", "s1", null),
            new(TelemetryEvent.ProductView, "b", "s2", null),
            new("add_to_cart", "a", "s1", null),
        ]);

        Assert.Equal(3, applied);
        var top = await stats.TopAsync(1);
        Assert.Equal(("a", 2L), (top[0].Id, top[0].Views));
    }

    private OrderService NewOrderService() => new(_products, _orders, _publisher, NullLogger<OrderService>.Instance);

    private OrderFulfillmentService NewFulfillment() => new(
        new OrderSagaActivities(
            _orders,
            _products,
            new InProcessPaymentGateway(new PaymentProcessor(_payments, NoDelay)),
            new InProcessShippingGateway(new ShippingProcessor(_shipments)),
            NoDelay,
            NullLogger<OrderSagaActivities>.Instance),
        _orders,
        NullLogger<OrderFulfillmentService>.Instance);

    private sealed class RecordingPublisher : IOrderEventPublisher
    {
        public List<OrderPlaced> Published { get; } = [];

        public Task PublishAsync(OrderPlaced evt, CancellationToken ct = default)
        {
            Published.Add(evt);
            return Task.CompletedTask;
        }
    }
}
