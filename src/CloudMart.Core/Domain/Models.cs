namespace CloudMart.Core.Domain;

/// <summary>A catalog item. Stored in Cosmos DB, partitioned by <see cref="Category"/>.</summary>
public sealed record Product
{
    public required string Id { get; init; }
    public required string Category { get; init; }
    public required string Name { get; init; }
    public string Description { get; init; } = "";
    public decimal Price { get; init; }
    public int Stock { get; init; }
    public string? ImageUrl { get; init; }
    public DateTimeOffset UpdatedUtc { get; init; } = DateTimeOffset.UtcNow;
}

/// <summary>View counter per product, fed by the telemetry stream. Partitioned by <see cref="Id"/> (the product id).</summary>
public sealed record ProductStats
{
    public required string Id { get; init; }
    public long Views { get; init; }
    public DateTimeOffset UpdatedUtc { get; init; }
}

public sealed record TrendingProduct(Product Product, long Views);

public enum OrderStatus
{
    Pending,
    Confirmed,
    Rejected,
}

/// <summary>An order. Stored relationally (Azure SQL or PostgreSQL) because it needs transactions and joins.</summary>
public sealed class Order
{
    public Guid Id { get; set; }
    public string CustomerId { get; set; } = "";
    public string CustomerName { get; set; } = "";
    public OrderStatus Status { get; set; }
    public string? StatusReason { get; set; }
    public bool ReviewRequired { get; set; }
    public decimal Total { get; set; }
    public string? PaymentId { get; set; }
    public string? TrackingNumber { get; set; }
    public DateTimeOffset CreatedUtc { get; set; }
    public DateTimeOffset UpdatedUtc { get; set; }
    public List<OrderLine> Lines { get; set; } = [];

    public Order Clone() => new()
    {
        Id = Id,
        CustomerId = CustomerId,
        CustomerName = CustomerName,
        Status = Status,
        StatusReason = StatusReason,
        ReviewRequired = ReviewRequired,
        Total = Total,
        PaymentId = PaymentId,
        TrackingNumber = TrackingNumber,
        CreatedUtc = CreatedUtc,
        UpdatedUtc = UpdatedUtc,
        Lines = Lines.Select(l => l.Clone()).ToList(),
    };
}

// A class rather than a record: EF Core tracks owned entities by reference, and record value-equality
// would make two identical lines look like the same entity.
public sealed class OrderLine
{
    public string ProductId { get; set; } = "";
    public string ProductName { get; set; } = "";
    public decimal UnitPrice { get; set; }
    public int Quantity { get; set; }

    public OrderLine Clone() => new() { ProductId = ProductId, ProductName = ProductName, UnitPrice = UnitPrice, Quantity = Quantity };
}

/// <summary>How the order saga ended. ReviewRequired is set when a compensation could not complete.</summary>
public sealed record OrderOutcome(
    OrderStatus Status,
    string Reason,
    string? PaymentId = null,
    string? TrackingNumber = null,
    bool ReviewRequired = false);

public sealed record OrderSummary(int Total, int Pending, int Confirmed, int Rejected, decimal ConfirmedRevenue);

public sealed record Customer(string Id, string Name, bool IsAdmin);

public sealed record OrderLineRequest(string ProductId, int Quantity);

public sealed record PlaceOrderRequest(IReadOnlyList<OrderLineRequest> Lines, bool SimulateFailure = false);

public sealed record UpsertProductRequest(string? Id, string Name, string Category, string? Description, decimal Price, int Stock);

public sealed record ImageUploadRequest(string FileName, string ContentType);

public sealed class OrderValidationException(string message) : Exception(message);

/// <summary>An Idempotency-Key that was already used for a different request (HTTP 422).</summary>
public sealed class IdempotencyConflictException(string message) : Exception(message);

public sealed class SimulatedFailureException(string message) : Exception(message);
