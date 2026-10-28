using System.Collections.Concurrent;
using CloudMart.Core.Domain;

namespace CloudMart.Core.Shipping;

// The shipping module: in-process until phase 16, then hosted by the Shipping API with Azure Table Storage.

public enum ShipmentStatus
{
    Scheduled,
    Cancelled,
}

/// <summary>One parcel per order. In Table Storage: PartitionKey = order id, RowKey = "shipment".</summary>
public sealed class Shipment
{
    public Guid OrderId { get; set; }
    public string CustomerName { get; set; } = "";
    public int ItemCount { get; set; }
    public string Carrier { get; set; } = "";
    public string TrackingNumber { get; set; } = "";
    public ShipmentStatus Status { get; set; }
    public string? Reason { get; set; }
    public DateTimeOffset EstimatedDeliveryUtc { get; set; }
    public DateTimeOffset CreatedUtc { get; set; }
    public DateTimeOffset UpdatedUtc { get; set; }

    public Shipment Clone() => (Shipment)MemberwiseClone();
}

public sealed record ShipmentRequest(string CustomerName, int ItemCount, decimal Total);

public sealed record CancelShipmentRequest(string Reason);

/// <summary>A shipment, or the business reason it could not be scheduled. A rejection is an answer, not an error.</summary>
public sealed record ShipmentResult(Shipment? Shipment, string? Rejection);

public static class ShippingApi
{
    /// <summary>App role on the Shipping API app registration, assigned to the callers' managed identities.</summary>
    public const string ManageRole = "Shipments.Manage";
}

public static class ShippingRules
{
    public const int MaxItemsPerParcel = 10;

    public static string? Reject(int itemCount) =>
        itemCount > MaxItemsPerParcel ? $"no carrier takes more than {MaxItemsPerParcel} items in one parcel" : null;

    public static (string Carrier, int Days) ChooseCarrier(decimal total) =>
        total > OrderPlaced.HighValueThreshold ? ("Contoso Express", 2) : ("Fabrikam Post", 4);

    /// <summary>Derived from the order id, so a retried request produces the same tracking number.</summary>
    public static string TrackingNumber(Guid orderId) => $"CM{orderId:N}"[..12].ToUpperInvariant();
}

public interface IShipmentStore
{
    Task<Shipment?> GetAsync(Guid orderId, CancellationToken ct = default);

    /// <summary>Inserts the shipment unless the order already has one, and returns the stored shipment.</summary>
    Task<(Shipment Shipment, bool Created)> AddOrGetAsync(Shipment shipment, CancellationToken ct = default);

    /// <summary>Scheduled -> Cancelled. Returns false if there is no shipment or it is already cancelled.</summary>
    Task<bool> TryCancelAsync(Guid orderId, string reason, CancellationToken ct = default);
}

public sealed class ShippingProcessor(IShipmentStore store)
{
    public async Task<(ShipmentResult Result, bool Created)> ScheduleAsync(Guid orderId, ShipmentRequest request, CancellationToken ct = default)
    {
        if (await store.GetAsync(orderId, ct) is { } existing)
            return (new ShipmentResult(existing, null), false);

        if (ShippingRules.Reject(request.ItemCount) is { } rejection)
            return (new ShipmentResult(null, rejection), false);

        var now = DateTimeOffset.UtcNow;
        var (carrier, days) = ShippingRules.ChooseCarrier(request.Total);
        var (shipment, created) = await store.AddOrGetAsync(new Shipment
        {
            OrderId = orderId,
            CustomerName = request.CustomerName,
            ItemCount = request.ItemCount,
            Carrier = carrier,
            TrackingNumber = ShippingRules.TrackingNumber(orderId),
            Status = ShipmentStatus.Scheduled,
            EstimatedDeliveryUtc = now.AddDays(days),
            CreatedUtc = now,
            UpdatedUtc = now,
        }, ct);
        return (new ShipmentResult(shipment, null), created);
    }

    /// <summary>Cancelling twice is a no-op, so the saga can retry its compensation safely.</summary>
    public async Task<Shipment?> CancelAsync(Guid orderId, string reason, CancellationToken ct = default)
    {
        await store.TryCancelAsync(orderId, reason, ct);
        return await store.GetAsync(orderId, ct);
    }
}

public sealed class InMemoryShipmentStore : IShipmentStore
{
    private readonly ConcurrentDictionary<Guid, Shipment> _shipments = new();

    public Task<Shipment?> GetAsync(Guid orderId, CancellationToken ct = default) =>
        Task.FromResult(_shipments.GetValueOrDefault(orderId)?.Clone());

    public Task<(Shipment Shipment, bool Created)> AddOrGetAsync(Shipment shipment, CancellationToken ct = default)
    {
        var added = _shipments.TryAdd(shipment.OrderId, shipment.Clone());
        return Task.FromResult((_shipments[shipment.OrderId].Clone(), added));
    }

    public Task<bool> TryCancelAsync(Guid orderId, string reason, CancellationToken ct = default)
    {
        if (!_shipments.TryGetValue(orderId, out var current) || current.Status == ShipmentStatus.Cancelled)
            return Task.FromResult(false);

        var cancelled = current.Clone();
        cancelled.Status = ShipmentStatus.Cancelled;
        cancelled.Reason = reason;
        cancelled.UpdatedUtc = DateTimeOffset.UtcNow;
        return Task.FromResult(_shipments.TryUpdate(orderId, cancelled, current));
    }
}
