using System.Diagnostics;
using System.Text.Json;
using CloudMart.Core.Domain;

namespace CloudMart.Core.Outbox;

// The transactional outbox (phase 5). A database transaction can't include a Service Bus send, so "save the order,
// then publish" can lose the event between the two steps. Instead, the event is saved as a row in the same
// transaction as the order, and a relay (OutboxRelay) publishes the rows afterwards, retrying until the broker takes
// them. Delivery is at least once: consumers already de-duplicate on the order id.

/// <summary>A message waiting in the outbox, or already sent. In SQL it's a row of the OutboxMessages table.</summary>
public sealed class OutboxMessage
{
    public const int MaxErrorLength = 1000;

    /// <summary>The Service Bus MessageId. For <see cref="OrderPlaced"/> it's the order id: one message per order.</summary>
    public Guid Id { get; set; }

    public string Type { get; set; } = "";
    public string Payload { get; set; } = "";

    /// <summary>The checkout request's W3C trace context, so the relay's publish joins the order's end-to-end trace.</summary>
    public string? TraceParent { get; set; }

    public DateTimeOffset CreatedUtc { get; set; }

    /// <summary>
    /// When a relay may next take it. A claim pushes this forward by the lease, like a queue's visibility timeout:
    /// other relays skip the message, and if the claiming relay dies, it simply becomes due again.
    /// </summary>
    public DateTimeOffset NextAttemptUtc { get; set; }

    /// <summary>Failed publish attempts so far. Drives the backoff.</summary>
    public int Attempts { get; set; }

    /// <summary>The claim that holds the message, so a relay whose lease ran out can't release someone else's claim.</summary>
    public Guid? ClaimId { get; set; }

    public DateTimeOffset? SentUtc { get; set; }
    public string? LastError { get; set; }

    public static OutboxMessage For(OrderPlaced placed, DateTimeOffset now) => new()
    {
        Id = placed.OrderId,
        Type = nameof(OrderPlaced),
        Payload = JsonSerializer.Serialize(placed, CloudMartJson.Options),
        TraceParent = Activity.Current is { IdFormat: ActivityIdFormat.W3C } current ? current.Id : null,
        CreatedUtc = now,
        NextAttemptUtc = now,
    };

    public OrderPlaced ToOrderPlaced() =>
        Type == nameof(OrderPlaced)
            ? JsonSerializer.Deserialize<OrderPlaced>(Payload, CloudMartJson.Options)
              ?? throw new InvalidOperationException($"Outbox message {Id} has an empty payload.")
            : throw new NotSupportedException($"Outbox message {Id} has an unknown type '{Type}'.");

    public OutboxMessage Clone() => (OutboxMessage)MemberwiseClone();
}

/// <summary>
/// The outbox table. Writing a message together with its order is <see cref="IOrderRepository.AddAsync"/>'s job,
/// because only the order's own transaction can make the two atomic.
/// </summary>
public interface IOutboxStore
{
    /// <summary>Adds the message unless the outbox already has one with its id. Returns true if it was added.</summary>
    Task<bool> EnsureAsync(OutboxMessage message, CancellationToken ct = default);

    /// <summary>
    /// Claims up to <paramref name="max"/> unsent messages that are due, oldest first, and leases them to one relay
    /// for <paramref name="lease"/>. Concurrent claims never return the same message.
    /// </summary>
    Task<IReadOnlyList<OutboxMessage>> ClaimAsync(int max, DateTimeOffset now, TimeSpan lease, CancellationToken ct = default);

    Task MarkSentAsync(Guid id, DateTimeOffset sentUtc, CancellationToken ct = default);

    /// <summary>Gives a claimed message back for another attempt at <paramref name="retryUtc"/>, if the claim still holds it.</summary>
    Task RetryLaterAsync(Guid id, Guid claimId, DateTimeOffset retryUtc, string error, CancellationToken ct = default);

    /// <summary>When the earliest unsent message falls due, or null when everything has been sent.</summary>
    Task<DateTimeOffset?> NextDueAsync(CancellationToken ct = default);
}

/// <summary>The outbox for in-memory orders. It shares nothing with another process, so it only needs a lock.</summary>
public sealed class InMemoryOutboxStore : IOutboxStore
{
    private readonly Dictionary<Guid, OutboxMessage> _messages = [];
    private readonly Lock _gate = new();

    /// <summary>A copy of every message, sent or not.</summary>
    public IReadOnlyList<OutboxMessage> Messages
    {
        get
        {
            lock (_gate)
                return _messages.Values.OrderBy(m => m.CreatedUtc).Select(m => m.Clone()).ToList();
        }
    }

    public Task<bool> EnsureAsync(OutboxMessage message, CancellationToken ct = default)
    {
        lock (_gate)
            return Task.FromResult(_messages.TryAdd(message.Id, message.Clone()));
    }

    public Task<IReadOnlyList<OutboxMessage>> ClaimAsync(int max, DateTimeOffset now, TimeSpan lease, CancellationToken ct = default)
    {
        var claimId = Guid.NewGuid();
        lock (_gate)
        {
            var due = _messages.Values
                .Where(m => m.SentUtc is null && m.NextAttemptUtc <= now)
                .OrderBy(m => m.NextAttemptUtc)
                .Take(max)
                .ToList();
            foreach (var message in due)
            {
                message.ClaimId = claimId;
                message.NextAttemptUtc = now + lease;
            }
            return Task.FromResult<IReadOnlyList<OutboxMessage>>(due.Select(m => m.Clone()).ToList());
        }
    }

    public Task MarkSentAsync(Guid id, DateTimeOffset sentUtc, CancellationToken ct = default)
    {
        lock (_gate)
        {
            if (_messages.TryGetValue(id, out var message) && message.SentUtc is null)
            {
                message.SentUtc = sentUtc;
                message.ClaimId = null;
            }
        }
        return Task.CompletedTask;
    }

    public Task RetryLaterAsync(Guid id, Guid claimId, DateTimeOffset retryUtc, string error, CancellationToken ct = default)
    {
        lock (_gate)
        {
            if (_messages.TryGetValue(id, out var message) && message.ClaimId == claimId && message.SentUtc is null)
            {
                message.ClaimId = null;
                message.NextAttemptUtc = retryUtc;
                message.Attempts++;
                message.LastError = error;
            }
        }
        return Task.CompletedTask;
    }

    public Task<DateTimeOffset?> NextDueAsync(CancellationToken ct = default)
    {
        lock (_gate)
            return Task.FromResult(_messages.Values.Where(m => m.SentUtc is null).Min(m => (DateTimeOffset?)m.NextAttemptUtc));
    }
}

/// <summary>Wakes this process's relay: a message was just written, so don't wait for the next due time.</summary>
public sealed class OutboxSignal
{
    private readonly SemaphoreSlim _signal = new(0, 1);

    public void Wake()
    {
        try
        {
            _signal.Release();
        }
        catch (SemaphoreFullException)
        {
            // A wake-up is already pending, and the relay's next run covers this message too.
        }
    }

    /// <summary>
    /// Waits for <see cref="Wake"/>, or until <paramref name="timeout"/> passes. Null waits for a wake-up only.
    /// Returns true if it was woken.
    /// </summary>
    public Task<bool> WaitAsync(TimeSpan? timeout, CancellationToken ct) => _signal.WaitAsync(timeout ?? Timeout.InfiniteTimeSpan, ct);
}
