using System.Threading.Channels;
using CloudMart.Core.Domain;
using CloudMart.Core.Services;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace CloudMart.Core.InProcess;

public sealed class InProcessOrderQueue
{
    public Channel<OrderPlaced> Channel { get; } = System.Threading.Channels.Channel.CreateUnbounded<OrderPlaced>();
}

public sealed class InProcessOrderEventPublisher(InProcessOrderQueue queue) : IOrderEventPublisher
{
    public Task PublishAsync(OrderPlaced evt, CancellationToken ct = default) => queue.Channel.Writer.WriteAsync(evt, ct).AsTask();
}

/// <summary>
/// Does in the API process what the Service Bus-triggered Functions do in Azure. Note what is missing here:
/// no retries, no dead-letter queue, no durability across restarts, no scale-out. That gap is the case for phase 5.
/// </summary>
public sealed class InProcessOrderWorker(
    InProcessOrderQueue queue,
    IServiceScopeFactory scopes,
    ILogger<InProcessOrderWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await foreach (var evt in queue.Channel.Reader.ReadAllAsync(stoppingToken))
        {
            try
            {
                await using var scope = scopes.CreateAsyncScope();
                var fulfillment = scope.ServiceProvider.GetRequiredService<OrderFulfillmentService>();
                await fulfillment.ProcessAsync(evt, stoppingToken);
                if (evt.Total > OrderPlaced.HighValueThreshold)
                    await fulfillment.FlagHighValueAsync(evt, stoppingToken);
                fulfillment.Notify(evt);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                logger.LogError(ex, "In-process fulfillment failed for order {OrderId}; the order stays Pending", evt.OrderId);
            }
        }
    }
}

public sealed class InProcessTelemetryPublisher(ProductViewAggregator aggregator) : ITelemetryPublisher
{
    public Task PublishAsync(IReadOnlyList<TelemetryEvent> events, CancellationToken ct = default) => aggregator.ApplyAsync(events, ct);
}
