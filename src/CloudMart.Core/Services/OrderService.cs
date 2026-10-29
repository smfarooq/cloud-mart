using System.Security.Cryptography;
using System.Text;
using CloudMart.Core.Domain;
using CloudMart.Core.Outbox;
using Microsoft.Extensions.Logging;

namespace CloudMart.Core.Services;

public sealed class OrderService(
    IProductRepository products,
    IOrderRepository orders,
    IOutboxStore outbox,
    OutboxSignal relay,
    ILogger<OrderService> logger)
{
    public const int MaxLines = 20;
    public const int MaxIdempotencyKeyLength = 100;

    /// <param name="idempotencyKey">
    /// The client's Idempotency-Key header: one value per checkout, reused on every retry of it. The same key from
    /// the same customer always returns the same order, so a lost response or a retried request never orders twice.
    /// </param>
    public async Task<Order> PlaceOrderAsync(
        Customer customer, PlaceOrderRequest request, string? idempotencyKey = null, CancellationToken ct = default)
    {
        if (request.Lines is null || request.Lines.Count == 0)
            throw new OrderValidationException("An order needs at least one line.");
        if (request.Lines.Count > MaxLines)
            throw new OrderValidationException($"An order can have at most {MaxLines} lines.");
        if (idempotencyKey is not null && !IsValidKey(idempotencyKey))
            throw new OrderValidationException($"Idempotency-Key must be 1 to {MaxIdempotencyKeyLength} visible ASCII characters.");

        var lines = new List<OrderLine>();
        foreach (var group in request.Lines.GroupBy(l => l.ProductId, StringComparer.OrdinalIgnoreCase))
        {
            var quantity = group.Sum(l => l.Quantity);
            if (quantity <= 0)
                throw new OrderValidationException($"Quantity for '{group.Key}' must be positive.");

            var product = await products.GetAsync(group.Key, ct)
                ?? throw new OrderValidationException($"Unknown product '{group.Key}'.");

            // Prices always come from the catalog, never from the client.
            lines.Add(new OrderLine { ProductId = product.Id, ProductName = product.Name, UnitPrice = product.Price, Quantity = quantity });
        }

        var id = idempotencyKey is null ? Guid.NewGuid() : OrderIdFor(customer.Id, idempotencyKey);
        if (idempotencyKey is not null && await orders.GetAsync(id, ct) is { } existing)
            return await ReplayAsync(existing, lines, request.SimulateFailure, ct);

        var now = DateTimeOffset.UtcNow;
        var order = new Order
        {
            Id = id,
            CustomerId = customer.Id,
            CustomerName = customer.Name,
            Status = OrderStatus.Pending,
            Lines = lines,
            Total = lines.Sum(l => l.UnitPrice * l.Quantity),
            CreatedUtc = now,
            UpdatedUtc = now,
        };

        try
        {
            // The order and its OrderPlaced message are committed together or not at all, so there is no moment
            // when one exists without the other.
            await orders.AddAsync(order, OutboxMessage.For(Placed(order, request.SimulateFailure), now), ct);
        }
        catch (Exception ex) when (idempotencyKey is not null && ex is not OperationCanceledException)
        {
            // Two requests with the same key arrived together and the other one inserted first: a primary-key
            // violation, whatever the provider calls it. Anything else is a real failure.
            if (await orders.GetAsync(id, ct) is { } raced)
                return await ReplayAsync(raced, lines, request.SimulateFailure, ct);
            throw;
        }

        // Publishing is the relay's job (OutboxRelay). Wake it rather than wait for it: the order still confirms in
        // seconds, but the checkout no longer waits for Service Bus, and a Service Bus outage delays the
        // confirmation instead of failing the checkout.
        relay.Wake();

        CloudMartTelemetry.OrdersPlaced.Add(1);
        logger.LogInformation("Order {OrderId} placed by {CustomerId} for {Total}", order.Id, order.CustomerId, order.Total);
        return order;
    }

    /// <summary>
    /// The order id is a hash of the customer and the key, so a retry maps to the same row and the primary key does
    /// the de-duplication: no extra column, no schema change, and one customer's key can't reach another's order.
    /// </summary>
    public static Guid OrderIdFor(string customerId, string idempotencyKey)
    {
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes($"{customerId}\n{idempotencyKey}"));
        hash[6] = (byte)((hash[6] & 0x0F) | 0x80); // RFC 9562 version 8: a custom, name-based UUID
        hash[8] = (byte)((hash[8] & 0x3F) | 0x80); // RFC 9562 variant
        return new Guid(hash.AsSpan(0, 16), bigEndian: true);
    }

    private async Task<Order> ReplayAsync(Order existing, List<OrderLine> lines, bool simulateFailure, CancellationToken ct)
    {
        if (!SameLines(existing.Lines, lines))
            throw new IdempotencyConflictException("This Idempotency-Key was already used for a different order.");

        // Still Pending: make sure its message is in the outbox, and leave publishing to the relay. Normally it is
        // there already, sent or still retrying; this adds it for an order saved before the outbox existed.
        if (existing.Status == OrderStatus.Pending &&
            await outbox.EnsureAsync(OutboxMessage.For(Placed(existing, simulateFailure), DateTimeOffset.UtcNow), ct))
        {
            relay.Wake();
        }

        logger.LogInformation("Order {OrderId} returned again for a retried Idempotency-Key ({Status})", existing.Id, existing.Status);
        return existing;
    }

    private static OrderPlaced Placed(Order order, bool simulateFailure) =>
        new(order.Id, order.CustomerId, order.CustomerName, order.Total, order.Lines.Sum(l => l.Quantity), simulateFailure, order.CreatedUtc);

    private static bool SameLines(List<OrderLine> stored, List<OrderLine> requested) =>
        stored.Count == requested.Count &&
        requested.All(r => stored.Any(s => string.Equals(s.ProductId, r.ProductId, StringComparison.OrdinalIgnoreCase) && s.Quantity == r.Quantity));

    private static bool IsValidKey(string key) =>
        key.Length is > 0 and <= MaxIdempotencyKeyLength && key.All(c => c is >= '!' and <= '~');
}
