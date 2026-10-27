using CloudMart.Core;
using CloudMart.Core.Domain;
using CloudMart.Core.InMemory;
using CloudMart.Core.Services;
using Microsoft.Extensions.Caching.Hybrid;
using Microsoft.FeatureManagement;

namespace CloudMart.Api.Endpoints;

public static class CatalogEndpoints
{
    private const string ProductsTag = "products";

    public static void MapCatalogEndpoints(this IEndpointRouteBuilder app)
    {
        var products = app.MapGroup("/api/products").WithTags("Catalog");

        products.MapGet("/", async (string? category, IProductRepository repo, HybridCache cache, CancellationToken ct) =>
            await cache.GetOrCreateAsync(
                $"products:{category?.ToLowerInvariant() ?? "all"}",
                async token => await repo.ListAsync(category, token),
                tags: [ProductsTag],
                cancellationToken: ct));

        products.MapGet("/trending", async (
            int? top, IProductStatsRepository stats, IProductRepository repo, IFeatureManager features, IFeatureDefinitionProvider definitions, CancellationToken ct) =>
        {
            if (!await FeatureFlags.IsTrendingEnabledAsync(features, definitions))
                return Results.Ok(Array.Empty<TrendingProduct>());

            var trending = new List<TrendingProduct>();
            foreach (var entry in await stats.TopAsync(Math.Clamp(top ?? 5, 1, 20), ct))
            {
                if (await repo.GetAsync(entry.Id, ct) is { } product)
                    trending.Add(new TrendingProduct(product, entry.Views));
            }
            return Results.Ok(trending);
        });

        products.MapGet("/{id}", async (string id, IProductRepository repo, CancellationToken ct) =>
            await repo.GetAsync(id, ct) is { } product ? Results.Ok(product) : Results.NotFound());

        products.MapPost("/", async (UpsertProductRequest request, IProductRepository repo, HybridCache cache, CancellationToken ct) =>
        {
            if (string.IsNullOrWhiteSpace(request.Name) || string.IsNullOrWhiteSpace(request.Category) || request.Price <= 0 || request.Stock < 0)
                return Results.Problem("Name, category, a positive price and a non-negative stock are required.", statusCode: 400);

            var id = string.IsNullOrWhiteSpace(request.Id) ? ProductIds.FromName(request.Name) : request.Id.Trim();
            var category = request.Category.Trim().ToLowerInvariant();
            var existing = await repo.GetAsync(id, ct);
            if (existing is not null && existing.Category != category)
            {
                // In Cosmos DB the partition key is immutable: a "move" is a delete in one partition plus an insert
                // in another. A plain upsert would silently create a duplicate.
                return Results.Problem($"Category is the partition key and cannot change ({existing.Category} -> {category}).", statusCode: 409);
            }

            var saved = await repo.UpsertAsync(new Product
            {
                Id = id,
                Category = category,
                Name = request.Name.Trim(),
                Description = request.Description?.Trim() ?? "",
                Price = request.Price,
                Stock = request.Stock,
                ImageUrl = existing?.ImageUrl,
                UpdatedUtc = DateTimeOffset.UtcNow,
            }, ct);
            await cache.RemoveByTagAsync(ProductsTag, ct);
            return Results.Ok(saved);
        }).RequireAuthorization(Policies.Admin);

        products.MapPost("/{id}/image-upload", async (string id, ImageUploadRequest request, IProductRepository repo, IImageStore images, CancellationToken ct) =>
        {
            if (await repo.GetAsync(id, ct) is null)
                return Results.NotFound();
            if (!ImageRules.IsAllowedContentType(request.ContentType))
                return Results.Problem("Upload a PNG, JPEG, WebP or GIF image.", statusCode: 400);

            return Results.Ok(await images.CreateUploadTargetAsync(id, request.FileName, request.ContentType, ct));
        }).RequireAuthorization(Policies.Admin);
    }

    public static void MapImageEndpoints(this IEndpointRouteBuilder app)
    {
        // Images are served through the API so the storage account can stay private. Front Door caches them at the edge.
        app.MapGet("/api/images/{**name}", async (string name, IImageStore images, HttpContext http, CancellationToken ct) =>
        {
            if (await images.OpenReadAsync(name, ct) is not { } image)
                return Results.NotFound();
            http.Response.Headers.CacheControl = "public, max-age=86400";
            return Results.Stream(image.Content, image.ContentType);
        }).WithTags("Catalog");

        // Local stand-in for "browser PUTs to Blob Storage, Event Grid triggers a Function". Only mapped without Azure Storage.
        if (app.ServiceProvider.GetRequiredService<IImageStore>() is InMemoryImageStore localStore)
        {
            app.MapPut("/api/local-uploads/{**name}", async (string name, HttpRequest request, ProductImageProcessor processor, HybridCache cache, CancellationToken ct) =>
            {
                if (request.ContentLength is null or > ImageRules.MaxBytes)
                    return Results.Problem($"Images must be under {ImageRules.MaxBytes / 1024 / 1024} MB.", statusCode: 400);

                using var buffer = new MemoryStream();
                await request.Body.CopyToAsync(buffer, ct);
                localStore.SaveUpload(name, buffer.ToArray(), request.ContentType ?? "application/octet-stream");
                var accepted = await processor.ProcessUploadAsync(name, ct);
                await cache.RemoveByTagAsync(ProductsTag, ct);
                return accepted ? Results.StatusCode(StatusCodes.Status201Created) : Results.Problem("Upload rejected.", statusCode: 400);
            }).RequireAuthorization(Policies.Admin).WithTags("Catalog");
        }
    }
}
