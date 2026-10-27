using Azure.Messaging.EventHubs;
using Azure.Messaging.EventHubs.Producer;
using Azure.Messaging.ServiceBus;
using CloudMart.Core.Domain;

namespace CloudMart.Core.Azure;

/// <summary>
/// Publishes to the "orders" topic. Each subscription (fulfillment, notifications, high-value) gets its own copy:
/// that is the pub/sub difference between a topic and a queue.
/// </summary>
public sealed class ServiceBusOrderEventPublisher(ServiceBusClient client, CloudMartSettings settings) : IOrderEventPublisher, IAsyncDisposable
{
    private readonly ServiceBusSender _sender = client.CreateSender(settings.OrdersTopic);

    public async Task PublishAsync(OrderPlaced evt, CancellationToken ct = default)
    {
        var message = new ServiceBusMessage(BinaryData.FromObjectAsJson(evt, CloudMartJson.Options))
        {
            // The topic has duplicate detection on, so a retried publish of the same order is dropped.
            MessageId = evt.OrderId.ToString(),
            Subject = nameof(OrderPlaced),
            ContentType = "application/json",
            CorrelationId = evt.CustomerId,
        };

        // Subscription SQL filters evaluate application properties, not the body.
        message.ApplicationProperties["total"] = (double)evt.Total;
        message.ApplicationProperties["itemCount"] = evt.ItemCount;

        await _sender.SendMessageAsync(message, ct);
    }

    public ValueTask DisposeAsync() => _sender.DisposeAsync();
}

/// <summary>Streams click events into Event Hubs, where a Function aggregates them in batches.</summary>
public sealed class EventHubsTelemetryPublisher(EventHubProducerClient producer) : ITelemetryPublisher
{
    public async Task PublishAsync(IReadOnlyList<TelemetryEvent> events, CancellationToken ct = default)
    {
        if (events.Count == 0)
            return;

        // Same partition key => same partition => one browser session's events stay in order.
        var options = new CreateBatchOptions { PartitionKey = events[0].SessionId ?? "anonymous" };
        using var batch = await producer.CreateBatchAsync(options, ct);
        foreach (var e in events)
        {
            if (!batch.TryAdd(new EventData(BinaryData.FromObjectAsJson(e, CloudMartJson.Options)) { ContentType = "application/json" }))
                throw new InvalidOperationException("The telemetry payload does not fit in a single Event Hubs batch.");
        }

        await producer.SendAsync(batch, ct);
    }
}
