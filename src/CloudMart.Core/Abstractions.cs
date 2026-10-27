using CloudMart.Core.Domain;

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
    Task AddAsync(Order order, CancellationToken ct = default);
    Task<Order?> GetAsync(Guid id, CancellationToken ct = default);
    Task<IReadOnlyList<Order>> ListByCustomerAsync(string customerId, int take, CancellationToken ct = default);
    Task<IReadOnlyList<Order>> ListRecentAsync(int take, CancellationToken ct = default);

    /// <summary>
    /// Moves a Pending order to its final status. Returns false if the order was not Pending any more, which is
    /// how consumers stay idempotent under at-least-once delivery.
    /// </summary>
    Task<bool> TryCompleteAsync(Guid id, OrderStatus status, string? reason, CancellationToken ct = default);

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

/// <summary>A dependency the readiness probe (/health/ready) should check.</summary>
public interface IHealthProbe
{
    string Name { get; }
    Task CheckAsync(CancellationToken ct);
}

/// <summary>Which implementation is active for each boundary. Shown on the Platform page.</summary>
public sealed record CloudMartProviders(string Catalog, string Orders, string Messaging, string Telemetry, string Images);
