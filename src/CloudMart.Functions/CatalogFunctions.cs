using Azure.Messaging.EventGrid;
using CloudMart.Core;
using CloudMart.Core.Domain;
using CloudMart.Core.Services;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Logging;

namespace CloudMart.Functions;

public sealed class CatalogFunctions(
    ProductImageProcessor images,
    ProductViewAggregator views,
    IOrderRepository orders,
    CloudMartSettings settings,
    ILogger<CatalogFunctions> logger)
{
    /// <summary>
    /// Event Grid (push, discrete events): the storage account's system topic raises BlobCreated when the browser
    /// finishes its SAS upload. The event subscription filters to the uploads container.
    /// </summary>
    [Function(nameof(ProcessProductImage))]
    public async Task ProcessProductImage([EventGridTrigger] EventGridEvent evt, CancellationToken ct)
    {
        // Subject: /blobServices/default/containers/{container}/blobs/{productId}/{file}
        var prefix = $"/blobServices/default/containers/{settings.UploadContainer}/blobs/";
        if (evt.EventType != "Microsoft.Storage.BlobCreated" || !evt.Subject.StartsWith(prefix, StringComparison.Ordinal))
        {
            logger.LogInformation("Ignoring {EventType} for {Subject}", evt.EventType, evt.Subject);
            return;
        }

        await images.ProcessUploadAsync(evt.Subject[prefix.Length..], ct);
    }

    /// <summary>
    /// Event Hubs (pull, high-volume stream): events arrive in batches per partition, checkpointed by the host.
    /// The "functions" consumer group gives this reader its own position in the stream.
    /// </summary>
    [Function(nameof(AggregateProductViews))]
    public async Task AggregateProductViews(
        [EventHubTrigger("telemetry", Connection = "EventHubs", ConsumerGroup = "functions")] string[] events,
        CancellationToken ct)
    {
        var parsed = events
            .Select(e => System.Text.Json.JsonSerializer.Deserialize<TelemetryEvent>(e, CloudMartJson.Options))
            .OfType<TelemetryEvent>()
            .ToList();
        var applied = await views.ApplyAsync(parsed, ct);
        logger.LogInformation("Applied {Views} product views from a batch of {Count} events", applied, events.Length);
    }

    /// <summary>A timer trigger: the serverless replacement for a scheduled task on a VM.</summary>
    [Function(nameof(DailyOrderReport))]
    public async Task DailyOrderReport([TimerTrigger("0 0 6 * * *")] TimerInfo timer, CancellationToken ct)
    {
        var summary = await orders.SummarizeAsync(DateTimeOffset.UtcNow.AddDays(-1), ct);
        logger.LogInformation(
            "Last 24h: {Total} orders ({Confirmed} confirmed, {Rejected} rejected, {Pending} pending), revenue {Revenue}",
            summary.Total, summary.Confirmed, summary.Rejected, summary.Pending, summary.ConfirmedRevenue);
    }
}
