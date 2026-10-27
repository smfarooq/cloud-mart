using System.Text.Json;
using CloudMart.Core;
using Microsoft.Extensions.Diagnostics.HealthChecks;

namespace CloudMart.Api;

/// <summary>
/// Readiness: can we reach every configured dependency? Used by App Service health check, Container Apps and AKS
/// readiness probes, and Front Door / Application Gateway health probes.
/// </summary>
public sealed class DependencyHealthCheck(IServiceScopeFactory scopes) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        await using var scope = scopes.CreateAsyncScope();
        var probes = scope.ServiceProvider.GetServices<IHealthProbe>().ToList();
        var results = new Dictionary<string, object>();
        var healthy = true;

        foreach (var probe in probes)
        {
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(TimeSpan.FromSeconds(5));
            try
            {
                await probe.CheckAsync(timeout.Token);
                results[probe.Name] = "ok";
            }
            catch (Exception ex)
            {
                healthy = false;
                // Showing the raw error is a learning aid ("Login failed for user..."); hide it in production.
                results[probe.Name] = $"{ex.GetType().Name}: {ex.Message.Split('\n')[0]}";
            }
        }

        return healthy
            ? HealthCheckResult.Healthy($"{probes.Count} dependencies reachable", results)
            : HealthCheckResult.Unhealthy("One or more dependencies are unreachable", data: results);
    }

    public static Task WriteResponseAsync(HttpContext http, HealthReport report)
    {
        http.Response.ContentType = "application/json";
        var body = new
        {
            status = report.Status.ToString(),
            dependencies = report.Entries.SelectMany(e => e.Value.Data).ToDictionary(d => d.Key, d => d.Value),
        };
        return http.Response.WriteAsync(JsonSerializer.Serialize(body, CloudMartJson.Options));
    }
}
