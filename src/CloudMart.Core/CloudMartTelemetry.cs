using System.Diagnostics;
using System.Diagnostics.Metrics;

namespace CloudMart.Core;

/// <summary>
/// Custom traces and metrics. The API registers this source/meter with OpenTelemetry, so they show up in
/// Application Insights as dependencies (traces) and customMetrics.
/// </summary>
public static class CloudMartTelemetry
{
    public const string SourceName = "CloudMart";

    public static readonly ActivitySource Source = new(SourceName);

    private static readonly Meter Meter = new(SourceName);

    public static readonly Counter<long> OrdersPlaced = Meter.CreateCounter<long>("cloudmart.orders.placed");
    public static readonly Counter<long> OrdersCompleted = Meter.CreateCounter<long>("cloudmart.orders.completed");
    public static readonly Counter<long> ProductViews = Meter.CreateCounter<long>("cloudmart.product.views");
}
