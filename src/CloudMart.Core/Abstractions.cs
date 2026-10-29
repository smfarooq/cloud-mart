using CloudMart.Core.Domain;
using CloudMart.Core.Outbox;
using CloudMart.Core.Payments;
using CloudMart.Core.Shipping;

namespace CloudMart.Core;

// Every async boundary in CloudMart has two implementations: an in-memory/in-process one so the app runs on a
// laptop with zero Azure resources, and an Azure one that lights up when its configuration is present.
// See CloudMartServiceCollectionExtensions for the switch.

public interface IProductRepository
{
    Task<IReadOnlyList<Product>> ListAsync(string? category, CancellationToken ct = default);
    Task<Product?> GetAsync(string id, CancellationToken ct = default);
    Task<Product> UpsertAsync(Product product, CancellationToken ct = default);
}

public interface IProductStatsRepository
{
    Task IncrementViewsAsync(IReadOnlyDictionary<string, int> viewsByProduct, CancellationToken ct = default);
    Task<IReadOnlyList<ProductStats>> TopAsync(int count, CancellationToken ct = default);
}

public interface IOrderRepository
{
    /// <summary>
    /// Saves a new order and the outbox message that announces it, in one transaction: the transactional outbox
    /// (phase 5). Fails if an order with the same id exists.
    /// </summary>
    Task AddAsync(Order order, OutboxMessage placed, CancellationToken ct = default);
    Task<Order?> GetAsync(Guid id, CancellationToken ct = default);
    Task<IReadOnlyList<Order>> ListByCustomerAsync(string customerId, int take, CancellationToken ct = default);
    Task<IReadOnlyList<Order>> ListRecentAsync(int take, CancellationToken ct = default);

    /// <summary>
    /// Moves a Pending order to its final status. Returns false if the order was not Pending any more, which is
    /// how consumers stay idempotent under at-least-once delivery.
    /// </summary>
    Task<bool> TryCompleteAsync(Guid id, OrderOutcome outcome, CancellationToken ct = default);

    Task MarkForReviewAsync(Guid id, CancellationToken ct = default);
    Task<OrderSummary> SummarizeAsync(DateTimeOffset since, CancellationToken ct = default);
}

public interface IOrderEventPublisher
{
    Task PublishAsync(OrderPlaced evt, CancellationToken ct = default);
}

public interface ITelemetryPublisher
{
    Task PublishAsync(IReadOnlyList<TelemetryEvent> events, CancellationToken ct = default);
}

public interface IImageStore
{
    Task<UploadTarget> CreateUploadTargetAsync(string productId, string fileName, string contentType, CancellationToken ct = default);
    Task<StoredImage?> OpenReadAsync(string imageName, CancellationToken ct = default);

    /// <summary>Validates an upload and moves it to the images container. Returns the image name, or null if rejected.</summary>
    Task<string?> PromoteUploadAsync(string uploadName, CancellationToken ct = default);
}

/// <summary>Takes payment for an order: the payments module in-process, or the Payments API (phase 16).</summary>
public interface IPaymentGateway
{
    /// <summary>A declined payment is returned with Status = Declined. Exceptions mean "unknown, try again".</summary>
    Task<Payment> ChargeAsync(ChargeRequest request, CancellationToken ct = default);
    Task<Payment> RefundAsync(string paymentId, string reason, CancellationToken ct = default);
}

/// <summary>Books a parcel for an order: the shipping module in-process, or the Shipping API (phase 16).</summary>
public interface IShippingGateway
{
    Task<ShipmentResult> ScheduleAsync(Guid orderId, ShipmentRequest request, CancellationToken ct = default);
    Task CancelAsync(Guid orderId, string reason, CancellationToken ct = default);
}

/// <summary>A dependency the readiness probe (/health/ready) should check.</summary>
public interface IHealthProbe
{
    string Name { get; }
    Task CheckAsync(CancellationToken ct);
}

/// <summary>Which implementation is active for each boundary. Shown on the Platform page.</summary>
public sealed record CloudMartProviders(
    string Catalog,
    string Orders,
    string Messaging,
    string Telemetry,
    string Images,
    string Payments,
    string Shipping);
