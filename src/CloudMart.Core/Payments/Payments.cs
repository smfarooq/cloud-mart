using System.Text.Json.Serialization;
using Microsoft.Extensions.Configuration;

namespace CloudMart.Core.Payments;

// The payments module. It runs in-process inside the order flow until phase 16, when the Payments API hosts the
// same classes as a separate service with its own database. Extracting a module that already has a clean boundary
// is the low-risk way to split a monolith (the "strangler fig" pattern).

public enum PaymentStatus
{
    Captured,
    Declined,
    Refunded,
}

/// <summary>A charge for one order. The Payments API stores it in an Azure SQL ledger table (tamper-evident history).</summary>
public sealed class Payment
{
    public string Id { get; set; } = "";
    public string IdempotencyKey { get; set; } = "";
    public Guid OrderId { get; set; }
    public string CustomerId { get; set; } = "";
    public decimal Amount { get; set; }
    public string Currency { get; set; } = "USD";
    public PaymentStatus Status { get; set; }
    public string? Reason { get; set; }
    public string? GatewayReference { get; set; }
    public DateTimeOffset CreatedUtc { get; set; }
    public DateTimeOffset UpdatedUtc { get; set; }

    public Payment Clone() => (Payment)MemberwiseClone();
}

public sealed record ChargeRequest(Guid OrderId, string CustomerId, decimal Amount, string Currency = "USD")
{
    /// <summary>
    /// The key the order flow sends on every attempt at charging this order: HTTP retries, Durable activity retries
    /// and Service Bus redeliveries all reuse it, so the customer is charged once. Sent as the Idempotency-Key header.
    /// </summary>
    [JsonIgnore]
    public string IdempotencyKey => $"charge-{OrderId}";
}

public sealed record RefundRequest(string Reason);

public static class PaymentsApi
{
    /// <summary>App role on the Payments API app registration, assigned to the callers' managed identities.</summary>
    public const string ProcessRole = "Payments.Process";
}

public static class PaymentRules
{
    public const decimal Limit = 10_000m;

    public static string? Decline(decimal amount) =>
        amount <= 0 ? "the amount must be positive"
        : amount > Limit ? $"the order exceeds the {Limit:N0} limit"
        : null;
}

/// <summary>An idempotency key was reused for a different order, or the order was already charged under another key.</summary>
public sealed class PaymentConflictException(string message) : Exception(message);

public interface IPaymentStore
{
    Task<Payment?> GetAsync(string id, CancellationToken ct = default);
    Task<Payment?> GetByIdempotencyKeyAsync(string key, CancellationToken ct = default);
    Task<Payment?> GetByOrderAsync(Guid orderId, CancellationToken ct = default);

    /// <summary>Inserts the payment. Returns false if the idempotency key or the order already has one (a race).</summary>
    Task<bool> TryAddAsync(Payment payment, CancellationToken ct = default);

    /// <summary>Captured -> Refunded. Returns false if the payment was not Captured.</summary>
    Task<bool> TryRefundAsync(string id, string reason, CancellationToken ct = default);
}

public sealed class PaymentProcessor(IPaymentStore store, IConfiguration config)
{
    /// <summary>Charges once per idempotency key. Created is false when an earlier attempt already did the work.</summary>
    public async Task<(Payment Payment, bool Created)> ChargeAsync(ChargeRequest request, string idempotencyKey, CancellationToken ct = default)
    {
        if (await FindExistingAsync(request, idempotencyKey, ct) is { } existing)
            return (existing, false);

        var now = DateTimeOffset.UtcNow;
        var decline = PaymentRules.Decline(request.Amount);
        // PaymentGateway:ApiKey is a Key Vault secret. Echoing its last four characters proves it arrived.
        var apiKey = config["PaymentGateway:ApiKey"];
        var payment = new Payment
        {
            Id = $"pay_{Guid.NewGuid():N}"[..20],
            IdempotencyKey = idempotencyKey,
            OrderId = request.OrderId,
            CustomerId = request.CustomerId,
            Amount = request.Amount,
            Currency = request.Currency,
            Status = decline is null ? PaymentStatus.Captured : PaymentStatus.Declined,
            Reason = decline ?? (apiKey is { Length: > 4 } ? $"charged via gateway key ****{apiKey[^4..]}" : "charged (no gateway key configured)"),
            GatewayReference = decline is null ? $"gw_{Guid.NewGuid():N}"[..19] : null,
            CreatedUtc = now,
            UpdatedUtc = now,
        };

        if (await store.TryAddAsync(payment, ct))
            return (payment, true);

        // Lost a race with a concurrent attempt: return whatever it stored.
        return (await FindExistingAsync(request, idempotencyKey, ct)
            ?? throw new InvalidOperationException($"Payment for order {request.OrderId} could not be stored."), false);
    }

    /// <summary>Refunds a captured payment. Refunding an already refunded payment is a no-op (idempotent).</summary>
    public async Task<Payment?> RefundAsync(string id, string reason, CancellationToken ct = default)
    {
        var payment = await store.GetAsync(id, ct);
        if (payment is null)
            return null;
        if (payment.Status == PaymentStatus.Declined)
            throw new PaymentConflictException($"Payment {id} was declined, so there is nothing to refund.");
        if (payment.Status == PaymentStatus.Captured)
            await store.TryRefundAsync(id, $"refunded: {reason}", ct);
        return await store.GetAsync(id, ct);
    }

    private async Task<Payment?> FindExistingAsync(ChargeRequest request, string idempotencyKey, CancellationToken ct)
    {
        if (await store.GetByIdempotencyKeyAsync(idempotencyKey, ct) is { } byKey)
        {
            return byKey.OrderId == request.OrderId
                ? byKey
                : throw new PaymentConflictException($"Idempotency key '{idempotencyKey}' was already used for another order.");
        }

        if (await store.GetByOrderAsync(request.OrderId, ct) is { } byOrder)
            throw new PaymentConflictException($"Order {request.OrderId} was already charged by payment {byOrder.Id}.");
        return null;
    }
}

public sealed class InMemoryPaymentStore : IPaymentStore
{
    private readonly Dictionary<string, Payment> _payments = [];
    private readonly Lock _gate = new();

    public Task<Payment?> GetAsync(string id, CancellationToken ct = default) => Find(p => p.Id == id);

    public Task<Payment?> GetByIdempotencyKeyAsync(string key, CancellationToken ct = default) => Find(p => p.IdempotencyKey == key);

    public Task<Payment?> GetByOrderAsync(Guid orderId, CancellationToken ct = default) => Find(p => p.OrderId == orderId);

    public Task<bool> TryAddAsync(Payment payment, CancellationToken ct = default)
    {
        lock (_gate)
        {
            // The same two uniqueness rules the SQL table enforces with UNIQUE constraints.
            if (_payments.Values.Any(p => p.IdempotencyKey == payment.IdempotencyKey || p.OrderId == payment.OrderId))
                return Task.FromResult(false);
            _payments[payment.Id] = payment.Clone();
            return Task.FromResult(true);
        }
    }

    public Task<bool> TryRefundAsync(string id, string reason, CancellationToken ct = default)
    {
        lock (_gate)
        {
            if (!_payments.TryGetValue(id, out var payment) || payment.Status != PaymentStatus.Captured)
                return Task.FromResult(false);
            payment.Status = PaymentStatus.Refunded;
            payment.Reason = reason;
            payment.UpdatedUtc = DateTimeOffset.UtcNow;
            return Task.FromResult(true);
        }
    }

    private Task<Payment?> Find(Func<Payment, bool> predicate)
    {
        lock (_gate)
            return Task.FromResult(_payments.Values.FirstOrDefault(predicate)?.Clone());
    }
}
