using System.Text.Json.Serialization;
using Azure.Identity;
using Azure.Monitor.OpenTelemetry.AspNetCore;
using CloudMart.Api;
using CloudMart.Api.Endpoints;
using CloudMart.Core;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.Extensions.Caching.Hybrid;
using Microsoft.FeatureManagement;
using Microsoft.Identity.Web;
using OpenTelemetry.Metrics;
using OpenTelemetry.Trace;
using StackExchange.Redis;

var builder = WebApplication.CreateBuilder(args);
var config = builder.Configuration;
var credential = new DefaultAzureCredential();

// ---------------------------------------------------------------------------------------------------------------
// Configuration sources. Phase 6: Key Vault. Gap topic: App Configuration + feature flags.
// ---------------------------------------------------------------------------------------------------------------
if (config["KeyVault:Uri"] is { Length: > 0 } keyVaultUri)
{
    // Secret "PaymentGateway--ApiKey" becomes configuration key "PaymentGateway:ApiKey".
    config.AddAzureKeyVault(new Uri(keyVaultUri), credential);
}

var appConfigEndpoint = config["AppConfig:Endpoint"];
if (!string.IsNullOrEmpty(appConfigEndpoint))
{
    config.AddAzureAppConfiguration(options => options
        .Connect(new Uri(appConfigEndpoint), credential)
        .Select("CloudMart:*")
        .ConfigureRefresh(refresh => refresh.RegisterAll().SetRefreshInterval(TimeSpan.FromSeconds(30)))
        .UseFeatureFlags(flags => flags.SetRefreshInterval(TimeSpan.FromSeconds(30))));
    builder.Services.AddAzureAppConfiguration();
}

builder.Services.AddFeatureManagement();

// ---------------------------------------------------------------------------------------------------------------
// Observability (phase 7): OpenTelemetry, exported to Application Insights when a connection string is present.
// ---------------------------------------------------------------------------------------------------------------
var otel = builder.Services.AddOpenTelemetry()
    .WithTracing(tracing => tracing.AddSource(CloudMartTelemetry.SourceName))
    .WithMetrics(metrics => metrics.AddMeter(CloudMartTelemetry.SourceName));
if (!string.IsNullOrEmpty(config["APPLICATIONINSIGHTS_CONNECTION_STRING"]))
    otel.UseAzureMonitor();

// ---------------------------------------------------------------------------------------------------------------
// Authentication (phase 6): Entra ID bearer tokens, or a local developer bypass until Entra is configured.
// ---------------------------------------------------------------------------------------------------------------
var entraEnabled = !string.IsNullOrEmpty(config["AzureAd:ClientId"]);
if (entraEnabled)
{
    builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
        .AddMicrosoftIdentityWebApi(
            jwt =>
            {
                config.Bind("AzureAd", jwt);
                jwt.TokenValidationParameters.NameClaimType = "name";
                jwt.TokenValidationParameters.RoleClaimType = "roles";
            },
            identity => config.Bind("AzureAd", identity));
}
else
{
    if (!builder.Environment.IsDevelopment() && !config.GetValue<bool>("Auth:AllowAnonymousDevMode"))
    {
        throw new InvalidOperationException(
            "AzureAd:ClientId is not configured. Configure Entra ID (phase 6), or set Auth:AllowAnonymousDevMode=true " +
            "for a throwaway lab environment.");
    }

    builder.Services.AddAuthentication(DevAuthenticationHandler.SchemeName)
        .AddScheme<AuthenticationSchemeOptions, DevAuthenticationHandler>(DevAuthenticationHandler.SchemeName, null);
}

builder.Services.AddAuthorizationBuilder()
    .AddPolicy(Policies.User, policy =>
    {
        policy.RequireAuthenticatedUser();
        if (entraEnabled)
            policy.RequireAssertion(ctx => ctx.User.HasScope(Policies.ApiScope));
    })
    .AddPolicy(Policies.Admin, policy => policy.RequireAuthenticatedUser().RequireRole(Roles.Admin));

// ---------------------------------------------------------------------------------------------------------------
// Caching (gap topic): HybridCache = in-process L1, plus Azure Managed Redis as a shared L2 when configured.
// ---------------------------------------------------------------------------------------------------------------
builder.Services.AddHybridCache(options => options.DefaultEntryOptions = new HybridCacheEntryOptions
{
    Expiration = TimeSpan.FromSeconds(30),
    LocalCacheExpiration = TimeSpan.FromSeconds(10),
});
if (config["Redis:Endpoint"] is { Length: > 0 } redisEndpoint)
{
    // Entra ID auth to Redis: no access keys. The identity needs a data access policy assignment on the database.
    var redisOptions = ConfigurationOptions.Parse(redisEndpoint);
    redisOptions.Ssl = true;
    redisOptions.AbortOnConnectFail = false;
    await redisOptions.ConfigureForAzureWithTokenCredentialAsync(credential);
    builder.Services.AddStackExchangeRedisCache(options => options.ConfigurationOptions = redisOptions);
}

// ---------------------------------------------------------------------------------------------------------------
// Application services, CORS, health, OpenAPI.
// ---------------------------------------------------------------------------------------------------------------
builder.Services.AddCloudMartCore(config, CloudMartHost.Api, credential);
builder.Services.AddSingleton<PlatformInfoProvider>();
builder.Services.AddHttpClient();
builder.Services.AddProblemDetails();
builder.Services.ConfigureHttpJsonOptions(o => o.SerializerOptions.Converters.Add(new JsonStringEnumConverter()));

var corsOrigins = (config["Cors:AllowedOrigins"] ?? "http://localhost:5173")
    .Split([',', ';'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
builder.Services.AddCors(o => o.AddDefaultPolicy(p => p.WithOrigins(corsOrigins).AllowAnyHeader().AllowAnyMethod()));

builder.Services.AddHealthChecks().AddCheck<DependencyHealthCheck>("dependencies", tags: ["ready"]);
builder.Services.AddOpenApi();

var app = builder.Build();

using (var startup = new CancellationTokenSource(TimeSpan.FromSeconds(60)))
    await app.Services.InitializeCloudMartDataAsync(app.Logger, startup.Token);

if (!entraEnabled)
    app.Logger.LogWarning("Entra ID is not configured: every caller is treated as an admin. Never expose this beyond a lab.");

app.UseExceptionHandler();
app.UseStatusCodePages();

// Phase 10: when the API sits behind Front Door, reject traffic that did not come through *our* Front Door profile.
// (App Service access restrictions can do this at the platform level; this check also covers Container Apps/AKS.)
if (config["FrontDoor:Id"] is { Length: > 0 } frontDoorId)
{
    app.Use(async (ctx, next) =>
    {
        if (!ctx.Request.Path.StartsWithSegments("/health") && ctx.Request.Headers["X-Azure-FDID"].ToString() != frontDoorId)
        {
            ctx.Response.StatusCode = StatusCodes.Status403Forbidden;
            return;
        }
        await next();
    });
}

app.UseCors();
app.UseAuthentication();
app.UseAuthorization();
if (!string.IsNullOrEmpty(appConfigEndpoint))
    app.UseAzureAppConfiguration();

app.MapOpenApi();
app.MapHealthChecks("/health/live", new HealthCheckOptions { Predicate = _ => false });
app.MapHealthChecks("/health/ready", new HealthCheckOptions
{
    Predicate = check => check.Tags.Contains("ready"),
    ResponseWriter = DependencyHealthCheck.WriteResponseAsync,
});

app.MapCatalogEndpoints();
app.MapImageEndpoints();
app.MapOrderEndpoints();
app.MapTelemetryEndpoints();
app.MapPlatformEndpoints();

app.Run();
