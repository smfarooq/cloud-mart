using System.Reflection;
using System.Text.Json;
using CloudMart.Core;
using Microsoft.FeatureManagement;

namespace CloudMart.Api;

public sealed record HostingInfo(string Model, string? Region, string Instance, string? Detail);

public sealed record PlatformInfo(
    string Version,
    string Environment,
    string Framework,
    HostingInfo Hosting,
    string AuthMode,
    CloudMartProviders Providers,
    IReadOnlyDictionary<string, bool> Integrations,
    IReadOnlyDictionary<string, bool> Features,
    string? BannerMessage);

public static class FeatureFlags
{
    public const string Trending = "Trending";

    /// <summary>
    /// On by default, so the Event Hubs lab works before App Configuration exists. Once a "Trending" feature flag is
    /// defined (phase 12), the flag decides.
    /// </summary>
    public static async Task<bool> IsTrendingEnabledAsync(IFeatureManager features, IFeatureDefinitionProvider definitions) =>
        await definitions.GetFeatureDefinitionAsync(Trending) is null || await features.IsEnabledAsync(Trending);
}

/// <summary>
/// Answers "where am I running and what is wired up?" The Platform page in the SPA renders this, so each lab
/// phase has a visible result: hosting model, region, which Azure services are active.
/// </summary>
public sealed class PlatformInfoProvider(
    IConfiguration config,
    IWebHostEnvironment environment,
    CloudMartProviders providers,
    IHttpClientFactory httpClients,
    ILogger<PlatformInfoProvider> logger)
{
    private readonly Lazy<Task<HostingInfo>> _hosting = new(() => DetectHostingAsync(httpClients, logger));

    public async Task<PlatformInfo> GetAsync(IFeatureManager features, IFeatureDefinitionProvider definitions)
    {
        var region = Environment.GetEnvironmentVariable("CLOUDMART_REGION");
        var hosting = await _hosting.Value;

        return new PlatformInfo(
            Assembly.GetExecutingAssembly().GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "dev",
            environment.EnvironmentName,
            System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription,
            hosting with { Region = hosting.Region ?? region },
            string.IsNullOrEmpty(config["AzureAd:ClientId"]) ? "Disabled (local developer bypass)" : "Entra ID",
            providers,
            new Dictionary<string, bool>
            {
                ["keyVault"] = !string.IsNullOrEmpty(config["KeyVault:Uri"]),
                ["paymentKeyLoaded"] = !string.IsNullOrEmpty(config["PaymentGateway:ApiKey"]),
                ["appConfiguration"] = !string.IsNullOrEmpty(config["AppConfig:Endpoint"]),
                ["redisCache"] = !string.IsNullOrEmpty(config["Redis:Endpoint"]),
                ["applicationInsights"] = !string.IsNullOrEmpty(config["APPLICATIONINSIGHTS_CONNECTION_STRING"]),
                ["frontDoorLock"] = !string.IsNullOrEmpty(config["FrontDoor:Id"]),
            },
            new Dictionary<string, bool> { [FeatureFlags.Trending] = await FeatureFlags.IsTrendingEnabledAsync(features, definitions) },
            config["CloudMart:BannerMessage"]);
    }

    private static async Task<HostingInfo> DetectHostingAsync(IHttpClientFactory httpClients, ILogger logger)
    {
        static string? Env(string name) => Environment.GetEnvironmentVariable(name);

        if (Env("WEBSITE_SITE_NAME") is { } site)
            return new HostingInfo("App Service", Env("REGION_NAME"), Short(Env("WEBSITE_INSTANCE_ID")) ?? Environment.MachineName, $"{site} ({Env("WEBSITE_SKU")})");

        if (Env("CONTAINER_APP_NAME") is { } containerApp)
            return new HostingInfo("Container Apps", null, Env("CONTAINER_APP_REPLICA_NAME") ?? Environment.MachineName, $"{containerApp} rev {Env("CONTAINER_APP_REVISION")}");

        if (Env("KUBERNETES_SERVICE_HOST") is not null)
            return new HostingInfo("Kubernetes (AKS)", null, Env("HOSTNAME") ?? Environment.MachineName, Env("POD_NAMESPACE"));

        // Azure VMs answer on the Instance Metadata Service, the same link-local endpoint managed identity uses.
        try
        {
            var http = httpClients.CreateClient();
            http.Timeout = TimeSpan.FromSeconds(1);
            using var request = new HttpRequestMessage(HttpMethod.Get, "http://169.254.169.254/metadata/instance/compute?api-version=2021-02-01");
            request.Headers.Add("Metadata", "true");
            using var response = await http.SendAsync(request);
            if (response.IsSuccessStatusCode)
            {
                using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync());
                var root = doc.RootElement;
                return new HostingInfo("Virtual machine", root.GetProperty("location").GetString(), root.GetProperty("name").GetString() ?? Environment.MachineName, root.GetProperty("vmSize").GetString());
            }
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException or KeyNotFoundException)
        {
            logger.LogDebug("Not an Azure VM: {Message}", ex.Message);
        }

        return new HostingInfo("Local", null, Environment.MachineName, null);
    }

    private static string? Short(string? value) => value is { Length: > 8 } ? value[..8] : value;
}
