using CloudMart.Core.Domain;
using Microsoft.Extensions.Logging;

namespace CloudMart.Core.Services;

public sealed class OrderService(
    IProductRepository products,
    IOrderRepository orders,
    IOrderEventPublisher publisher,
    ILogger<OrderService> logger)
{
    public const int MaxLines = 20;

    public async Task<Order> PlaceOrderAsync(Customer customer, PlaceOrderRequest request, CancellationToken ct = default)
    {
        if (request.Lines is null || request.Lines.Count == 0)
            throw new OrderValidationException("An order needs at least one line.");
        if (request.Lines.Count > MaxLines)
            throw new OrderValidationException($"An order can have at most {MaxLines} lines.");

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

        var now = DateTimeOffset.UtcNow;
        var order = new Order
        {
            Id = Guid.NewGuid(),
            CustomerId = customer.Id,
            CustomerName = customer.Name,
            Status = OrderStatus.Pending,
            Lines = lines,
            Total = lines.Sum(l => l.UnitPrice * l.Quantity),
            CreatedUtc = now,
            UpdatedUtc = now,
        };

        await orders.AddAsync(order, ct);

        // Dual write: the order row is committed before the event is published, so a publish failure leaves the
        // order Pending forever. The production answer is the transactional outbox pattern (learning path, phase 5).
        await publisher.PublishAsync(
            new OrderPlaced(order.Id, order.CustomerId, order.CustomerName, order.Total, lines.Sum(l => l.Quantity), request.SimulateFailure, now),
            ct);

        CloudMartTelemetry.OrdersPlaced.Add(1);
        logger.LogInformation("Order {OrderId} placed by {CustomerId} for {Total}", order.Id, order.CustomerId, order.Total);
        return order;
    }
}
