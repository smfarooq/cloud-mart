using System.Text.RegularExpressions;
using CloudMart.Core.Domain;
using Microsoft.Extensions.Logging;

namespace CloudMart.Core.Services;

/// <summary>Turns raw click-stream events into view counters. Runs behind Event Hubs in Azure.</summary>
public sealed class ProductViewAggregator(IProductStatsRepository stats)
{
    public async Task<int> ApplyAsync(IEnumerable<TelemetryEvent> events, CancellationToken ct = default)
    {
        var views = events
            .Where(e => e.Type == TelemetryEvent.ProductView && !string.IsNullOrWhiteSpace(e.ProductId))
            .GroupBy(e => e.ProductId!)
            .ToDictionary(g => g.Key, g => g.Count());

        if (views.Count == 0)
            return 0;

        await stats.IncrementViewsAsync(views, ct);
        var total = views.Values.Sum();
        CloudMartTelemetry.ProductViews.Add(total);
        return total;
    }
}

/// <summary>Validates a browser upload and attaches it to its product. Runs behind Event Grid in Azure.</summary>
public sealed class ProductImageProcessor(IImageStore images, IProductRepository products, ILogger<ProductImageProcessor> logger)
{
    public async Task<bool> ProcessUploadAsync(string uploadName, CancellationToken ct = default)
    {
        var productId = ImageRules.ProductIdFromUploadName(uploadName);
        var product = productId is null ? null : await products.GetAsync(productId, ct);
        if (product is null)
        {
            logger.LogWarning("Upload {UploadName} does not belong to a known product", uploadName);
            return false;
        }

        var imageName = await images.PromoteUploadAsync(uploadName, ct);
        if (imageName is null)
        {
            logger.LogWarning("Upload {UploadName} was rejected (missing, wrong type or too large)", uploadName);
            return false;
        }

        await products.UpsertAsync(product with { ImageUrl = $"/api/images/{imageName}", UpdatedUtc = DateTimeOffset.UtcNow }, ct);
        logger.LogInformation("Product {ProductId} now uses image {ImageName}", product.Id, imageName);
        return true;
    }
}

public static partial class ImageRules
{
    public const long MaxBytes = 5 * 1024 * 1024;

    private static readonly HashSet<string> AllowedContentTypes =
        new(["image/png", "image/jpeg", "image/webp", "image/gif"], StringComparer.OrdinalIgnoreCase);

    public static bool IsAllowedContentType(string? contentType) => contentType is not null && AllowedContentTypes.Contains(contentType);

    public static bool IsAllowed(string? contentType, long length) => IsAllowedContentType(contentType) && length is > 0 and <= MaxBytes;

    /// <summary>Upload names are "{productId}/{random}-{fileName}" so the processor can find the product.</summary>
    public static string CreateUploadName(string productId, string fileName)
    {
        var safe = UnsafeFileNameChars().Replace(Path.GetFileName(fileName), "-");
        if (safe.Length > 80)
            safe = safe[^80..];
        return $"{productId}/{Guid.NewGuid():N}-{safe}";
    }

    public static string? ProductIdFromUploadName(string uploadName)
    {
        var slash = uploadName.IndexOf('/');
        return slash > 0 ? uploadName[..slash] : null;
    }

    [GeneratedRegex("[^A-Za-z0-9._-]")]
    private static partial Regex UnsafeFileNameChars();
}

public static partial class ProductIds
{
    public static string FromName(string name) => NonSlugChars().Replace(name.Trim().ToLowerInvariant(), "-").Trim('-');

    [GeneratedRegex("[^a-z0-9]+")]
    private static partial Regex NonSlugChars();
}

public static class CatalogSeed
{
    public static IReadOnlyList<Product> Products { get; } =
    [
        new() { Id = "contoso-ultrabook-14", Category = "laptops", Name = "Contoso Ultrabook 14", Description = "14\" lightweight laptop, 32 GB RAM.", Price = 1499m, Stock = 25 },
        new() { Id = "contoso-workstation-16", Category = "laptops", Name = "Contoso Workstation 16", Description = "Mobile workstation. Buy three to see the payment limit reject an order.", Price = 4999m, Stock = 10 },
        new() { Id = "fabrikam-anc-headphones", Category = "audio", Name = "Fabrikam ANC Headphones", Description = "Over-ear, active noise cancelling.", Price = 249m, Stock = 60 },
        new() { Id = "fabrikam-studio-mic", Category = "audio", Name = "Fabrikam Studio Mic", Description = "USB-C condenser microphone. Only 3 left: order more to see a stock rejection.", Price = 129m, Stock = 3 },
        new() { Id = "northwind-mech-keyboard", Category = "accessories", Name = "Northwind Mechanical Keyboard", Description = "Hot-swappable switches.", Price = 119m, Stock = 80 },
        new() { Id = "northwind-4k-monitor", Category = "accessories", Name = "Northwind 27\" 4K Monitor", Description = "USB-C power delivery. One of these makes a high-value order.", Price = 549m, Stock = 15 },
        new() { Id = "tailspin-smart-speaker", Category = "home", Name = "Tailspin Smart Speaker", Description = "Room-filling sound, voice assistant built in.", Price = 89m, Stock = 120 },
        new() { Id = "woodgrove-desk-lamp", Category = "home", Name = "Woodgrove Desk Lamp", Description = "Dimmable LED with wireless charging base. Order 11 to see shipping fail and the saga refund you.", Price = 59m, Stock = 200 },
    ];
}
