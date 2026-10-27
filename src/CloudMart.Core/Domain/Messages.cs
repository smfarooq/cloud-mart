namespace CloudMart.Core.Domain;

/// <summary>
/// Published when an order is accepted. Travels over a Service Bus topic in Azure, or an in-process channel locally.
/// </summary>
public sealed record OrderPlaced(
    Guid OrderId,
    string CustomerId,
    string CustomerName,
    decimal Total,
    int ItemCount,
    bool SimulateFailure,
    DateTimeOffset PlacedUtc)
{
    /// <summary>Matches the SQL filter on the "high-value" Service Bus subscription (infra/modules/servicebus.bicep).</summary>
    public const decimal HighValueThreshold = 500m;
}

/// <summary>A click-stream event from the browser. Travels over Event Hubs in Azure.</summary>
public sealed record TelemetryEvent(string Type, string? ProductId, string? SessionId, DateTimeOffset? Timestamp)
{
    public const string ProductView = "product_view";
}

/// <summary>Where and how the browser should upload an image (valet-key pattern).</summary>
public sealed record UploadTarget(
    string UploadUrl,
    string Method,
    IReadOnlyDictionary<string, string> Headers,
    string BlobName,
    DateTimeOffset ExpiresUtc);

public sealed record StoredImage(Stream Content, string ContentType);
