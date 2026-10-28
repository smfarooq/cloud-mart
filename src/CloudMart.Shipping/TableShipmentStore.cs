using System.Net;
using Azure;
using Azure.Data.Tables;
using CloudMart.Core;
using CloudMart.Core.Shipping;

namespace CloudMart.Shipping;

/// <summary>
/// Azure Table Storage: a key-value store with no schema, priced per GB and per transaction, in the storage account
/// CloudMart already has. A good fit when every read is "get by key" and you don't need queries across items:
/// here, always "the shipment for order X". (Cosmos DB for Table is the drop-in upgrade for global distribution.)
/// </summary>
public sealed class TableShipmentStore(TableClient table) : IShipmentStore, IHealthProbe
{
    // PartitionKey = order id spreads the load; RowKey is fixed because an order has one shipment.
    private const string RowKey = "shipment";

    public string Name => "shipments-table";

    public async Task<Shipment?> GetAsync(Guid orderId, CancellationToken ct = default)
    {
        var entity = await table.GetEntityIfExistsAsync<TableEntity>(orderId.ToString(), RowKey, cancellationToken: ct);
        return entity.HasValue ? ToShipment(entity.Value!) : null;
    }

    public async Task<(Shipment Shipment, bool Created)> AddOrGetAsync(Shipment shipment, CancellationToken ct = default)
    {
        try
        {
            // AddEntity fails with 409 if the key exists: the insert itself is the idempotency check, no race window.
            await table.AddEntityAsync(ToEntity(shipment), ct);
            return (shipment, true);
        }
        catch (RequestFailedException ex) when (ex.Status == (int)HttpStatusCode.Conflict)
        {
            return (await GetAsync(shipment.OrderId, ct) ?? throw new InvalidOperationException("Shipment vanished after a conflict."), false);
        }
    }

    public async Task<bool> TryCancelAsync(Guid orderId, string reason, CancellationToken ct = default)
    {
        var response = await table.GetEntityIfExistsAsync<TableEntity>(orderId.ToString(), RowKey, cancellationToken: ct);
        if (!response.HasValue || response.Value!.GetString(nameof(Shipment.Status)) == nameof(ShipmentStatus.Cancelled))
            return false;

        var entity = response.Value;
        entity[nameof(Shipment.Status)] = nameof(ShipmentStatus.Cancelled);
        entity[nameof(Shipment.Reason)] = reason;
        entity[nameof(Shipment.UpdatedUtc)] = DateTimeOffset.UtcNow;
        try
        {
            // Optimistic concurrency: the update only applies if nobody changed the entity since we read it (ETag).
            await table.UpdateEntityAsync(entity, entity.ETag, TableUpdateMode.Replace, ct);
            return true;
        }
        catch (RequestFailedException ex) when (ex.Status == (int)HttpStatusCode.PreconditionFailed)
        {
            return false;
        }
    }

    public Task CheckAsync(CancellationToken ct) =>
        table.GetEntityIfExistsAsync<TableEntity>("health", "probe", cancellationToken: ct);

    private static TableEntity ToEntity(Shipment s)
    {
        var entity = new TableEntity(s.OrderId.ToString(), RowKey)
        {
            [nameof(Shipment.CustomerName)] = s.CustomerName,
            [nameof(Shipment.ItemCount)] = s.ItemCount,
            [nameof(Shipment.Carrier)] = s.Carrier,
            [nameof(Shipment.TrackingNumber)] = s.TrackingNumber,
            [nameof(Shipment.Status)] = s.Status.ToString(),
            [nameof(Shipment.EstimatedDeliveryUtc)] = s.EstimatedDeliveryUtc,
            [nameof(Shipment.CreatedUtc)] = s.CreatedUtc,
            [nameof(Shipment.UpdatedUtc)] = s.UpdatedUtc,
        };
        // Tables have no schema: a property that is null is simply not stored.
        if (s.Reason is not null)
            entity[nameof(Shipment.Reason)] = s.Reason;
        return entity;
    }

    private static Shipment ToShipment(TableEntity e) => new()
    {
        OrderId = Guid.Parse(e.PartitionKey),
        CustomerName = e.GetString(nameof(Shipment.CustomerName)) ?? "",
        ItemCount = e.GetInt32(nameof(Shipment.ItemCount)) ?? 0,
        Carrier = e.GetString(nameof(Shipment.Carrier)) ?? "",
        TrackingNumber = e.GetString(nameof(Shipment.TrackingNumber)) ?? "",
        Status = Enum.Parse<ShipmentStatus>(e.GetString(nameof(Shipment.Status)) ?? nameof(ShipmentStatus.Scheduled)),
        Reason = e.GetString(nameof(Shipment.Reason)),
        EstimatedDeliveryUtc = e.GetDateTimeOffset(nameof(Shipment.EstimatedDeliveryUtc)) ?? default,
        CreatedUtc = e.GetDateTimeOffset(nameof(Shipment.CreatedUtc)) ?? default,
        UpdatedUtc = e.GetDateTimeOffset(nameof(Shipment.UpdatedUtc)) ?? default,
    };
}
