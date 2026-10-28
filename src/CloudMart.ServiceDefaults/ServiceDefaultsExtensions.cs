using Azure.Monitor.OpenTelemetry.AspNetCore;
using CloudMart.Core;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Microsoft.Identity.Web;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;

namespace CloudMart.ServiceDefaults;

// What every CloudMart web service does the same way: telemetry, health endpoints, caller authentication and the
// chaos switch. The same idea as .NET Aspire's "ServiceDefaults" project.

public static class ServicePolicies
{
    /// <summary>The caller's token carries the service's app role (assigned to the calling managed identity).</summary>
    public const string Caller = "CloudMart.ServiceCaller";
}

/// <summary>Failure injection for the resilience labs. Change the app setting and watch retries in App Insights.</summary>
public sealed class ChaosOptions
{
    /// <summary>0 to 1: the share of requests answered with 503 Service Unavailable.</summary>
    public double FailureRate { get; set; }

    /// <summary>Added to every request, to trip client timeouts.</summary>
    public int DelayMs { get; set; }
}

public static class ServiceDefaultsExtensions
{
    /// <summary>OpenTelemetry traces and metrics, exported to Application Insights when its connection string is set.</summary>
    public static WebApplicationBuilder AddCloudMartObservability(this WebApplicationBuilder builder)
    {
        var otel = builder.Services.AddOpenTelemetry()
            .WithTracing(tracing => tracing.AddSource(CloudMartTelemetry.SourceName))
            .WithMetrics(metrics => metrics.AddMeter(CloudMartTelemetry.SourceName));
        if (!string.IsNullOrEmpty(builder.Configuration["APPLICATIONINSIGHTS_CONNECTION_STRING"]))
            otel.UseAzureMonitor();
        return builder;
    }

    /// <summary>
    /// Service-to-service authentication: Entra ID bearer tokens that must carry <paramref name="requiredRole"/>.
    /// Callers are managed identities, so these are app-only tokens: a "roles" claim and no "scp" (no user).
    /// Until AzureAd:ClientId is configured, a local bypass signs every caller in with that role.
    /// </summary>
    /// <returns>True when Entra ID is enforcing.</returns>
    public static bool AddCloudMartServiceAuth(this WebApplicationBuilder builder, string requiredRole)
    {
        var config = builder.Configuration;
        var entraEnabled = !string.IsNullOrEmpty(config["AzureAd:ClientId"]);
        if (entraEnabled)
        {
            builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
                .AddMicrosoftIdentityWebApi(
                    jwt =>
                    {
                        config.Bind("AzureAd", jwt);
                        jwt.TokenValidationParameters.RoleClaimType = "roles";
                    },
                    identity => config.Bind("AzureAd", identity));
        }
        else
        {
            ThrowUnlessDevModeAllowed(builder);
            builder.Services.AddAuthentication(DevAuthenticationHandler.SchemeName)
                .AddScheme<DevAuthenticationOptions, DevAuthenticationHandler>(
                    DevAuthenticationHandler.SchemeName,
                    options => options.Roles = [requiredRole]);
        }

        builder.Services.AddAuthorizationBuilder()
            .AddPolicy(ServicePolicies.Caller, policy => policy.RequireAuthenticatedUser().RequireRole(requiredRole));
        return entraEnabled;
    }

    public static void ThrowUnlessDevModeAllowed(WebApplicationBuilder builder)
    {
        if (!builder.Environment.IsDevelopment() && !builder.Configuration.GetValue<bool>("Auth:AllowAnonymousDevMode"))
        {
            throw new InvalidOperationException(
                "AzureAd:ClientId is not configured. Configure Entra ID (phase 6), or set Auth:AllowAnonymousDevMode=true " +
                "for a throwaway lab environment.");
        }
    }

    public static IServiceCollection AddCloudMartHealth(this IServiceCollection services)
    {
        services.AddHealthChecks().AddCheck<DependencyHealthCheck>("dependencies", tags: ["ready"]);
        return services;
    }

    /// <summary>/health/live (is the process up?) and /health/ready (can it reach its dependencies?).</summary>
    public static WebApplication MapCloudMartHealth(this WebApplication app)
    {
        app.MapHealthChecks("/health/live", new HealthCheckOptions { Predicate = _ => false });
        app.MapHealthChecks("/health/ready", new HealthCheckOptions
        {
            Predicate = check => check.Tags.Contains("ready"),
            ResponseWriter = DependencyHealthCheck.WriteResponseAsync,
        });
        return app;
    }

    public static IServiceCollection AddCloudMartChaos(this IServiceCollection services, IConfiguration config) =>
        services.Configure<ChaosOptions>(config.GetSection("Chaos"));

    /// <summary>Applies <see cref="ChaosOptions"/> to every request except the health probes.</summary>
    public static WebApplication UseCloudMartChaos(this WebApplication app)
    {
        var options = app.Services.GetRequiredService<IOptionsMonitor<ChaosOptions>>();
        app.Use(async (ctx, next) =>
        {
            var chaos = options.CurrentValue;
            if (ctx.Request.Path.StartsWithSegments("/health") || (chaos.FailureRate <= 0 && chaos.DelayMs <= 0))
            {
                await next();
                return;
            }

            if (chaos.DelayMs > 0)
                await Task.Delay(chaos.DelayMs, ctx.RequestAborted);

            if (Random.Shared.NextDouble() < chaos.FailureRate)
            {
                app.Logger.LogWarning("Chaos: failing {Method} {Path} with 503", ctx.Request.Method, ctx.Request.Path);
                await Results.Problem("Injected failure (Chaos:FailureRate).", statusCode: StatusCodes.Status503ServiceUnavailable)
                    .ExecuteAsync(ctx);
                return;
            }

            await next();
        });
        return app;
    }
}
