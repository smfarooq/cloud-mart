using System.Collections.Concurrent;
using CloudMart.Core.Domain;
using CloudMart.Core.Services;

namespace CloudMart.Core.InMemory;

public sealed class InMemoryProductRepository : IProductRepository
{
    private readonly ConcurrentDictionary<string, Product> _products = new(StringComparer.OrdinalIgnoreCase);

    public Task<IReadOnlyList<Product>> ListAsync(string? category, CancellationToken ct = default) =>
        Task.FromResult<IReadOnlyList<Product>>(_products.Values
            .Where(p => category is null || string.Equals(p.Category, category, StringComparison.OrdinalIgnoreCase))
            .OrderBy(p => p.Name)
            .ToList());

    public Task<Product?> GetAsync(string id, CancellationToken ct = default) =>
        Task.FromResult(_products.GetValueOrDefault(id));

    public Task<Product> UpsertAsync(Product product, CancellationToken ct = default) =>
        Task.FromResult(_products[product.Id] = product);
}

public sealed class InMemoryProductStatsRepository : IProductStatsRepository
{
    private readonly ConcurrentDictionary<string, long> _views = new(StringComparer.OrdinalIgnoreCase);

    public Task IncrementViewsAsync(IReadOnlyDictionary<string, int> viewsByProduct, CancellationToken ct = default)
    {
        foreach (var (productId, count) in viewsByProduct)
            _views.AddOrUpdate(productId, count, (_, current) => current + count);
        return Task.CompletedTask;
    }

    public Task<IReadOnlyList<ProductStats>> TopAsync(int count, CancellationToken ct = default) =>
        Task.FromResult<IReadOnlyList<ProductStats>>(_views
            .OrderByDescending(kv => kv.Value)
            .Take(count)
            .Select(kv => new ProductStats { Id = kv.Key, Views = kv.Value, UpdatedUtc = DateTimeOffset.UtcNow })
            .ToList());
}

public sealed class InMemoryOrderRepository : IOrderRepository
{
    private readonly ConcurrentDictionary<Guid, Order> _orders = new();
    private readonly Lock _gate = new();

    // Orders are cloned on the way in and out so callers never share mutable state, just like a real database.
    public Task AddAsync(Order order, CancellationToken ct = default)
    {
        _orders[order.Id] = order.Clone();
        return Task.CompletedTask;
    }

    public Task<Order?> GetAsync(Guid id, CancellationToken ct = default)
    {
        lock (_gate)
            return Task.FromResult(_orders.GetValueOrDefault(id)?.Clone());
    }

    public Task<IReadOnlyList<Order>> ListByCustomerAsync(string customerId, int take, CancellationToken ct = default) =>
        List(o => o.CustomerId == customerId, take);

    public Task<IReadOnlyList<Order>> ListRecentAsync(int take, CancellationToken ct = default) => List(_ => true, take);

    public Task<bool> TryCompleteAsync(Guid id, OrderOutcome outcome, CancellationToken ct = default)
    {
        lock (_gate)
        {
            if (!_orders.TryGetValue(id, out var order) || order.Status != OrderStatus.Pending)
                return Task.FromResult(false);
            order.Status = outcome.Status;
            order.StatusReason = outcome.Reason;
            order.PaymentId = outcome.PaymentId;
            order.TrackingNumber = outcome.TrackingNumber;
            order.ReviewRequired |= outcome.ReviewRequired;
            order.UpdatedUtc = DateTimeOffset.UtcNow;
            return Task.FromResult(true);
        }
    }

    public Task MarkForReviewAsync(Guid id, CancellationToken ct = default)
    {
        lock (_gate)
        {
            if (_orders.TryGetValue(id, out var order))
                order.ReviewRequired = true;
        }
        return Task.CompletedTask;
    }

    public Task<OrderSummary> SummarizeAsync(DateTimeOffset since, CancellationToken ct = default)
    {
        lock (_gate)
        {
            var recent = _orders.Values.Where(o => o.CreatedUtc >= since).ToList();
            return Task.FromResult(new OrderSummary(
                recent.Count,
                recent.Count(o => o.Status == OrderStatus.Pending),
                recent.Count(o => o.Status == OrderStatus.Confirmed),
                recent.Count(o => o.Status == OrderStatus.Rejected),
                recent.Where(o => o.Status == OrderStatus.Confirmed).Sum(o => o.Total)));
        }
    }

    private Task<IReadOnlyList<Order>> List(Func<Order, bool> predicate, int take)
    {
        lock (_gate)
        {
            return Task.FromResult<IReadOnlyList<Order>>(_orders.Values
                .Where(predicate)
                .OrderByDescending(o => o.CreatedUtc)
                .Take(take)
                .Select(o => o.Clone())
                .ToList());
        }
    }
}

/// <summary>
/// Local stand-in for Blob Storage. The "upload URL" points back at the API (PUT /api/local-uploads/...),
/// which plays the role Event Grid + the Function play in Azure.
/// </summary>
public sealed class InMemoryImageStore : IImageStore
{
    private readonly ConcurrentDictionary<string, (byte[] Data, string ContentType)> _uploads = new();
    private readonly ConcurrentDictionary<string, (byte[] Data, string ContentType)> _images = new();

    public Task<UploadTarget> CreateUploadTargetAsync(string productId, string fileName, string contentType, CancellationToken ct = default)
    {
        var name = ImageRules.CreateUploadName(productId, fileName);
        return Task.FromResult(new UploadTarget(
            $"/api/local-uploads/{name}",
            "PUT",
            new Dictionary<string, string> { ["Content-Type"] = contentType },
            name,
            DateTimeOffset.UtcNow.AddMinutes(10)));
    }

    public void SaveUpload(string uploadName, byte[] data, string contentType) => _uploads[uploadName] = (data, contentType);

    public Task<StoredImage?> OpenReadAsync(string imageName, CancellationToken ct = default) =>
        Task.FromResult(_images.TryGetValue(imageName, out var image)
            ? new StoredImage(new MemoryStream(image.Data, writable: false), image.ContentType)
            : null);

    public Task<string?> PromoteUploadAsync(string uploadName, CancellationToken ct = default)
    {
        if (!_uploads.TryRemove(uploadName, out var upload) || !ImageRules.IsAllowed(upload.ContentType, upload.Data.Length))
            return Task.FromResult<string?>(null);

        _images[uploadName] = upload;
        return Task.FromResult<string?>(uploadName);
    }
}
