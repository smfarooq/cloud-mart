using CloudMart.Core;
using CloudMart.Core.Domain;
using CloudMart.Core.InMemory;
using CloudMart.Core.InProcess;
using CloudMart.Core.Outbox;
using CloudMart.Core.Payments;
using CloudMart.Core.Services;
using CloudMart.Core.Shipping;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;

namespace CloudMart.Core.Tests;

public class OrderFlowTests
{
    private readonly InMemoryProductRepository _products = new();
    private readonly InMemoryOutboxStore _outbox = new();
    private readonly InMemoryOrderRepository _orders;
    private readonly InMemoryPaymentStore _payments = new();
    private readonly InMemoryShipmentStore _shipments = new();
    private readonly RecordingPublisher _publisher = new();
    private readonly Customer _customer = new("user-1", "Test User", IsAdmin: false);

    private static readonly IConfiguration NoDelay =
        new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["Fulfillment:SimulatedDelayMs"] = "0" }).Build();

    public OrderFlowTests()
    {
        _orders = new InMemoryOrderRepository(_outbox);
        foreach (var product in CatalogSeed.Products)
            _products.UpsertAsync(product).GetAwaiter().GetResult();
    }

    [Fact]
    public async Task PlaceOrder_prices_from_catalog_and_publishes_event_through_the_outbox()
    {
        var order = await NewOrderService().PlaceOrderAsync(_customer, new PlaceOrderRequest([new("woodgrove-desk-lamp", 2)]));

        Assert.Equal(OrderStatus.Pending, order.Status);
        Assert.Equal(118m, order.Total);
        Assert.Empty(_publisher.Published); // the checkout only writes the outbox

        await NewRelay().RunAsync();

        var evt = Assert.Single(_publisher.Published);
        Assert.Equal(order.Id, evt.OrderId);
        Assert.NotNull(Assert.Single(_outbox.Messages).SentUtc);
    }

    [Fact]
    public async Task PlaceOrder_rejects_unknown_product()
    {
        await Assert.ThrowsAsync<OrderValidationException>(() =>
            NewOrderService().PlaceOrderAsync(_customer, new PlaceOrderRequest([new("does-not-exist", 1)])));
        Assert.Empty(_outbox.Messages);
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
        // Still Pending, but the replay finds the order's message already in the outbox and adds nothing.
        Assert.Equal(first.Id, Assert.Single(_outbox.Messages).Id);
        Assert.Empty(_publisher.Published);
    }

    [Fact]
    public async Task PlaceOrder_retry_after_fulfillment_returns_the_result_without_publishing()
    {
        var service = NewOrderService();
        var request = new PlaceOrderRequest([new("woodgrove-desk-lamp", 1)]);
        await service.PlaceOrderAsync(_customer, request, "checkout-2");
        await NewRelay().RunAsync();
        await NewFulfillment().ProcessAsync(_publisher.Published.Single());

        var retry = await service.PlaceOrderAsync(_customer, request, "checkout-2");
        await NewRelay().RunAsync();

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
        Assert.Single(_outbox.Messages);
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
        Assert.Empty(_outbox.Messages);
    }

    // ---- The transactional outbox (phase 5) ----

    [Fact]
    public async Task PlaceOrder_wakes_the_relay()
    {
        var signal = new OutboxSignal();

        await NewOrderService(signal).PlaceOrderAsync(_customer, new PlaceOrderRequest([new("woodgrove-desk-lamp", 1)]));

        Assert.True(await signal.WaitAsync(TimeSpan.Zero, CancellationToken.None));
    }

    [Fact]
    public async Task Outbox_failed_publish_leaves_an_unsent_message_that_a_later_run_sends()
    {
        _publisher.Down = true;
        // The checkout succeeds while Service Bus is down: it never talks to the broker.
        var order = await NewOrderService().PlaceOrderAsync(_customer, new PlaceOrderRequest([new("woodgrove-desk-lamp", 1)]));
        var clock = new ManualClock(order.CreatedUtc);

        var nextDue = await NewRelay(clock).RunAsync();

        var waiting = Assert.Single(_outbox.Messages);
        Assert.Null(waiting.SentUtc);
        Assert.Equal(1, waiting.Attempts);
        Assert.Equal(RecordingPublisher.DownError, waiting.LastError);
        Assert.Equal(clock.Now + OutboxRelay.Backoff(1), nextDue);

        // A run before the backoff ends (another order woke the relay, say) doesn't try it again.
        await NewRelay(clock).RunAsync();
        Assert.Equal(1, _publisher.Attempts);

        _publisher.Down = false;
        clock.Now = nextDue!.Value;
        Assert.Null(await NewRelay(clock).RunAsync()); // nothing left to send

        Assert.Equal(order.Id, Assert.Single(_publisher.Published).OrderId);
        Assert.NotNull(Assert.Single(_outbox.Messages).SentUtc);
        Assert.Equal(OrderStatus.Pending, (await _orders.GetAsync(order.Id))!.Status); // the saga takes it from here
    }

    [Fact]
    public async Task Outbox_relays_running_at_once_publish_each_message_once()
    {
        var service = NewOrderService();
        var placed = new List<Guid>();
        for (var i = 0; i < 3 * OutboxRelay.BatchSize + 5; i++)
            placed.Add((await service.PlaceOrderAsync(_customer, new PlaceOrderRequest([new("woodgrove-desk-lamp", 1)]))).Id);

        // Four API instances, each with its own relay, all woken at once.
        await Task.WhenAll(Enumerable.Range(0, 4).Select(_ => Task.Run(() => NewRelay().RunAsync())));
        await NewRelay().RunAsync();

        Assert.Equal(placed.Order(), _publisher.Published.Select(e => e.OrderId).Order());
    }

    [Fact]
    public async Task Outbox_relay_that_dies_after_publishing_sends_a_duplicate_that_changes_nothing()
    {
        var order = await NewOrderService().PlaceOrderAsync(_customer, new PlaceOrderRequest([new("woodgrove-desk-lamp", 1)]));
        var clock = new ManualClock(order.CreatedUtc);

        // One relay claims the message and publishes it, then dies before it can mark it sent.
        var claimed = Assert.Single(await _outbox.ClaimAsync(OutboxRelay.BatchSize, clock.Now, OutboxRelay.Lease));
        await _publisher.PublishAsync(claimed.ToOrderPlaced());

        // Its lease keeps the message from every other relay until the lease runs out ...
        Assert.Equal(clock.Now + OutboxRelay.Lease, await NewRelay(clock).RunAsync());
        Assert.Single(_publisher.Published);

        // ... and then another relay sends it again: at-least-once delivery.
        clock.Now += OutboxRelay.Lease;
        await NewRelay(clock).RunAsync();
        Assert.Equal(2, _publisher.Published.Count);

        // Both copies carry the order id, which is the Service Bus MessageId, so duplicate detection drops the second.
        // If it got through anyway, the saga would find the order no longer Pending and leave it alone.
        Assert.All(_publisher.Published, evt => Assert.Equal(order.Id, evt.OrderId));
        var fulfillment = NewFulfillment();
        await fulfillment.ProcessAsync(_publisher.Published[0]);
        var confirmed = (await _orders.GetAsync(order.Id))!;
        await fulfillment.ProcessAsync(_publisher.Published[1]);

        Assert.Equal(OrderStatus.Confirmed, confirmed.Status);
        Assert.Equal(confirmed.UpdatedUtc, (await _orders.GetAsync(order.Id))!.UpdatedUtc);
    }

    [Fact]
    public async Task Outbox_replay_of_a_pending_order_from_before_the_outbox_adds_its_message()
    {
        // An order placed before the outbox existed: it is in the orders table, but its message went nowhere
        // (here, into a store no relay reads), so nothing will ever publish it.
        var outbox = new InMemoryOutboxStore();
        var orders = new InMemoryOrderRepository(new InMemoryOutboxStore());
        var service = new OrderService(_products, orders, outbox, new OutboxSignal(), NullLogger<OrderService>.Instance);
        var request = new PlaceOrderRequest([new("woodgrove-desk-lamp", 1)]);
        var order = await service.PlaceOrderAsync(_customer, request, "checkout-legacy");
        Assert.Empty(outbox.Messages);

        var retry = await service.PlaceOrderAsync(_customer, request, "checkout-legacy");

        Assert.Equal(order.Id, retry.Id);
        Assert.Equal(order.Id, Assert.Single(outbox.Messages).Id);
        Assert.Empty(_publisher.Published); // the replay queues the message; only the relay publishes

        await new OutboxRelay(outbox, _publisher, TimeProvider.System, NullLogger<OutboxRelay>.Instance).RunAsync();
        Assert.Equal(order.Id, Assert.Single(_publisher.Published).OrderId);
    }

    [Fact]
    public async Task Outbox_replay_while_the_message_waits_for_a_retry_adds_nothing_and_publishes_nothing()
    {
        _publisher.Down = true;
        var service = NewOrderService();
        var request = new PlaceOrderRequest([new("woodgrove-desk-lamp", 1)]);
        await service.PlaceOrderAsync(_customer, request, "checkout-4");
        await NewRelay().RunAsync();

        await service.PlaceOrderAsync(_customer, request, "checkout-4");

        var waiting = Assert.Single(_outbox.Messages);
        Assert.Equal(1, waiting.Attempts); // the retry didn't reset the backoff or publish around the relay
        Assert.Equal(1, _publisher.Attempts);
    }

    [Theory]
    [InlineData(1, 5)]
    [InlineData(2, 10)]
    [InlineData(4, 40)]
    [InlineData(5, 60)]
    [InlineData(1000, 60)]
    public void Outbox_backoff_doubles_up_to_a_minute(int attempts, int seconds) =>
        Assert.Equal(TimeSpan.FromSeconds(seconds), OutboxRelay.Backoff(attempts));

    // ---- Fulfillment ----

    [Theory]
    [InlineData("woodgrove-desk-lamp", 1, OrderStatus.Confirmed)]
    [InlineData("fabrikam-studio-mic", 4, OrderStatus.Rejected)]     // only 3 in stock
    [InlineData("contoso-workstation-16", 3, OrderStatus.Rejected)]  // over the payment limit
    [InlineData("woodgrove-desk-lamp", 11, OrderStatus.Rejected)]    // too many items for one parcel: refunded
    public async Task Fulfillment_applies_business_rules(string productId, int quantity, OrderStatus expected)
    {
        var order = await PlaceAndRelayAsync(new PlaceOrderRequest([new(productId, quantity)]));

        await NewFulfillment().ProcessAsync(_publisher.Published.Single());

        Assert.Equal(expected, (await _orders.GetAsync(order.Id))!.Status);
    }

    [Fact]
    public async Task Confirmed_order_records_payment_and_tracking_number()
    {
        var order = await PlaceAndRelayAsync(new PlaceOrderRequest([new("woodgrove-desk-lamp", 2)]));

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
        var order = await PlaceAndRelayAsync(new PlaceOrderRequest([new("woodgrove-desk-lamp", 11)]));

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
        var order = await PlaceAndRelayAsync(new PlaceOrderRequest([new("woodgrove-desk-lamp", 1)]));
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
        await PlaceAndRelayAsync(new PlaceOrderRequest([new("woodgrove-desk-lamp", 1)], SimulateFailure: true));

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

    private OrderService NewOrderService(OutboxSignal? signal = null) =>
        new(_products, _orders, _outbox, signal ?? new OutboxSignal(), NullLogger<OrderService>.Instance);

    private OutboxRelay NewRelay(TimeProvider? clock = null) =>
        new(_outbox, _publisher, clock ?? TimeProvider.System, NullLogger<OutboxRelay>.Instance);

    /// <summary>Places an order and runs the relay once, as the API's relay does right after the commit.</summary>
    private async Task<Order> PlaceAndRelayAsync(PlaceOrderRequest request)
    {
        var order = await NewOrderService().PlaceOrderAsync(_customer, request);
        await NewRelay().RunAsync();
        return order;
    }

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
        public const string DownError = "Service Bus is unreachable.";

        private readonly Lock _gate = new();

        public List<OrderPlaced> Published { get; } = [];
        public int Attempts { get; private set; }

        /// <summary>Makes every publish fail, as if the network or the firewall blocked Service Bus.</summary>
        public bool Down { get; set; }

        public async Task PublishAsync(OrderPlaced evt, CancellationToken ct = default)
        {
            await Task.Yield(); // lets concurrent relays interleave
            lock (_gate)
            {
                Attempts++;
                if (Down)
                    throw new InvalidOperationException(DownError);
                Published.Add(evt);
            }
        }
    }

    private sealed class ManualClock(DateTimeOffset now) : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = now;
        public override DateTimeOffset GetUtcNow() => Now;
    }
}
