using System.Net;
using CloudMart.Core.Domain;
using Microsoft.Azure.Cosmos;

namespace CloudMart.Core.Azure;

/// <summary>
/// Products live in Cosmos DB for NoSQL, partitioned by /category. Listing one category is a single-partition
/// query; looking a product up by id alone is a cross-partition query (fine for a small catalog, worth
/// re-thinking at scale; that trade-off is the heart of Cosmos DB data modelling).
/// </summary>
public sealed class CosmosProductRepository(CosmosClient client, CloudMartSettings settings) : IProductRepository, IHealthProbe
{
    private readonly Container _container = client.GetContainer(settings.CosmosDatabase, settings.ProductsContainer);

    public string Name => "cosmos-products";

    public Task<IReadOnlyList<Product>> ListAsync(string? category, CancellationToken ct = default)
    {
        if (category is null)
            return _container.QueryAllAsync<Product>(new QueryDefinition("SELECT * FROM c ORDER BY c.name"), null, ct);

        return _container.QueryAllAsync<Product>(
            new QueryDefinition("SELECT * FROM c WHERE c.category = @category ORDER BY c.name").WithParameter("@category", category),
            new QueryRequestOptions { PartitionKey = new PartitionKey(category) },
            ct);
    }

    public async Task<Product?> GetAsync(string id, CancellationToken ct = default)
    {
        var matches = await _container.QueryAllAsync<Product>(
            new QueryDefinition("SELECT * FROM c WHERE c.id = @id").WithParameter("@id", id), null, ct);
        return matches.FirstOrDefault();
    }

    public async Task<Product> UpsertAsync(Product product, CancellationToken ct = default)
    {
        var response = await _container.UpsertItemAsync(product, new PartitionKey(product.Category), cancellationToken: ct);
        return response.Resource;
    }

    public Task CheckAsync(CancellationToken ct) => _container.ReadContainerAsync(cancellationToken: ct);
}

public sealed class CosmosProductStatsRepository(CosmosClient client, CloudMartSettings settings) : IProductStatsRepository
{
    private readonly Container _container = client.GetContainer(settings.CosmosDatabase, settings.StatsContainer);

    public async Task IncrementViewsAsync(IReadOnlyDictionary<string, int> viewsByProduct, CancellationToken ct = default)
    {
        foreach (var (productId, count) in viewsByProduct)
        {
            var partitionKey = new PartitionKey(productId);
            try
            {
                await PatchAsync(productId, partitionKey, count, ct);
            }
            catch (CosmosException ex) when (ex.StatusCode == HttpStatusCode.NotFound)
            {
                try
                {
                    var stats = new ProductStats { Id = productId, Views = count, UpdatedUtc = DateTimeOffset.UtcNow };
                    await _container.CreateItemAsync(stats, partitionKey, cancellationToken: ct);
                }
                catch (CosmosException conflict) when (conflict.StatusCode == HttpStatusCode.Conflict)
                {
                    // Another consumer created the document first; apply our increment on top of theirs.
                    await PatchAsync(productId, partitionKey, count, ct);
                }
            }
        }
    }

    public Task<IReadOnlyList<ProductStats>> TopAsync(int count, CancellationToken ct = default) =>
        // count is an int, so inlining it into TOP is injection-safe.
        _container.QueryAllAsync<ProductStats>(new QueryDefinition($"SELECT TOP {count} * FROM c ORDER BY c.views DESC"), null, ct);

    // Partial document update: increments server-side, so concurrent consumers don't overwrite each other.
    private Task PatchAsync(string productId, PartitionKey partitionKey, int count, CancellationToken ct) =>
        _container.PatchItemAsync<ProductStats>(
            productId,
            partitionKey,
            [PatchOperation.Increment("/views", count), PatchOperation.Set("/updatedUtc", DateTimeOffset.UtcNow)],
            cancellationToken: ct);
}

internal static class CosmosQueryExtensions
{
    public static async Task<IReadOnlyList<T>> QueryAllAsync<T>(
        this Container container, QueryDefinition query, QueryRequestOptions? options, CancellationToken ct)
    {
        var results = new List<T>();
        using var iterator = container.GetItemQueryIterator<T>(query, requestOptions: options);
        while (iterator.HasMoreResults)
            results.AddRange(await iterator.ReadNextAsync(ct));
        return results;
    }
}
