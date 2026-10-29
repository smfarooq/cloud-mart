using System.Diagnostics;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace CloudMart.Core.Outbox;

/// <summary>
/// One pass of the outbox relay: claim the messages that are due, publish each one, then mark it sent or schedule a
/// retry with backoff. Every API instance runs a relay; claims lease their messages, so two relays never publish the
/// same message at once. A relay that dies mid-batch leaves its messages leased, and another relay picks them up
/// when the lease runs out. If it dies between publishing and marking sent, the message goes out twice, with the
/// same MessageId: Service Bus duplicate detection drops the copy, and the saga ignores orders that aren't Pending.
/// </summary>
public sealed class OutboxRelay(IOutboxStore store, IOrderEventPublisher publisher, TimeProvider clock, ILogger<OutboxRelay> logger)
{
    public const int BatchSize = 10;
    public static readonly TimeSpan PublishTimeout = TimeSpan.FromSeconds(10);

    /// <summary>Longer than a batch of timed-out publishes, so a slow batch never loses its claim halfway through.</summary>
    public static readonly TimeSpan Lease = TimeSpan.FromMinutes(2);

    /// <summary>Publishes everything that is due. Returns when the next unsent message falls due, or null if there is none.</summary>
    public async Task<DateTimeOffset?> RunAsync(CancellationToken ct = default)
    {
        IReadOnlyList<OutboxMessage> batch;
        do
        {
            batch = await store.ClaimAsync(BatchSize, clock.GetUtcNow(), Lease, ct);
            foreach (var message in batch)
                await PublishAsync(message, ct);
        }
        while (batch.Count == BatchSize);

        return await store.NextDueAsync(ct);
    }

    /// <summary>5 s, 10 s, 20 s, 40 s, then every minute: quick to recover from a blip, gentle on a broker that is down.</summary>
    public static TimeSpan Backoff(int attempts) =>
        TimeSpan.FromSeconds(Math.Min(60, 5 * Math.Pow(2, Math.Clamp(attempts, 1, 10) - 1)));

    private async Task PublishAsync(OutboxMessage message, CancellationToken ct)
    {
        // The relay runs outside the checkout request, so it continues the request's trace from the stored context:
        // the Service Bus send, and the FulfillOrder function after it, stay in the order's end-to-end trace.
        ActivityContext.TryParse(message.TraceParent, null, out var checkout);
        using (var activity = CloudMartTelemetry.Source.StartActivity("OutboxRelay", ActivityKind.Internal, checkout))
        {
            activity?.SetTag("cloudmart.order_id", message.Id);
            activity?.SetTag("cloudmart.outbox.attempts", message.Attempts);
            try
            {
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
                timeout.CancelAfter(PublishTimeout);
                await publisher.PublishAsync(message.ToOrderPlaced(), timeout.Token);
            }
            catch (Exception ex) when (!ct.IsCancellationRequested)
            {
                var attempts = message.Attempts + 1;
                var retryUtc = clock.GetUtcNow() + Backoff(attempts);
                var error = ex is OperationCanceledException ? $"No answer within {PublishTimeout.TotalSeconds:0} s" : ex.Message;
                activity?.SetStatus(ActivityStatusCode.Error, error);
                await store.RetryLaterAsync(message.Id, message.ClaimId!.Value, retryUtc, Truncate(error), ct);
                logger.LogWarning(ex, "Could not publish outbox message {MessageId} (attempt {Attempts}); next try at {RetryUtc:u}",
                    message.Id, attempts, retryUtc);
                return;
            }
        }

        await store.MarkSentAsync(message.Id, clock.GetUtcNow(), ct);
        if (message.Attempts > 0)
            logger.LogInformation("Published outbox message {MessageId} after {Attempts} failed attempts", message.Id, message.Attempts);
    }

    private static string Truncate(string error) =>
        error.Length <= OutboxMessage.MaxErrorLength ? error : error[..OutboxMessage.MaxErrorLength];
}

/// <summary>
/// Runs <see cref="OutboxRelay"/> in the API: once at startup (messages left by a crash or a restart), whenever this
/// process writes a message (<see cref="OutboxSignal"/>), and when the next unsent message falls due. It never polls
/// on a fixed timer. An idle relay leaves the database alone, so a serverless Azure SQL database can still auto-pause.
/// The price: messages abandoned by an instance that died stay put until some relay next runs (that instance's
/// restart, or the next order on any instance).
/// </summary>
public sealed class OutboxRelayWorker(
    IServiceScopeFactory scopes,
    OutboxSignal signal,
    TimeProvider clock,
    ILogger<OutboxRelayWorker> logger) : BackgroundService
{
    // SemaphoreSlim can't wait longer than about 24 days; a message due later than this is simply checked again.
    private static readonly TimeSpan MaxWait = TimeSpan.FromDays(1);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var failures = 0;
        while (!stoppingToken.IsCancellationRequested)
        {
            TimeSpan? wait;
            try
            {
                await using var scope = scopes.CreateAsyncScope();
                var nextDue = await scope.ServiceProvider.GetRequiredService<OutboxRelay>().RunAsync(stoppingToken);
                failures = 0;
                wait = nextDue - clock.GetUtcNow();
            }
            catch (Exception ex) when (!stoppingToken.IsCancellationRequested)
            {
                // Usually the database: unreachable, still paused, or the identity has no access yet (phase 4).
                wait = OutboxRelay.Backoff(++failures);
                logger.LogError(ex, "The outbox relay failed; trying again in {Delay}", wait);
            }

            if (wait > MaxWait)
                wait = MaxWait;
            if (wait is null || wait > TimeSpan.Zero)
                await signal.WaitAsync(wait, stoppingToken);
        }
    }
}
