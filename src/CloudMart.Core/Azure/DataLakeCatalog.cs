using Azure;
using Azure.Core;
using Azure.Identity;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using CloudMart.Core.Analytics;
using Microsoft.Extensions.Logging;

namespace CloudMart.Core.Azure;

/// <summary>
/// Lists the data lake through its Blob endpoint. A Data Lake Storage Gen2 account answers on two: blob (this class,
/// and the private endpoint the API uses) and dfs (directory operations, used by Data Factory, Spark and Fabric).
/// The API's identity holds Storage Blob Data Reader on the two containers and nothing else.
/// </summary>
public sealed class DataLakeCatalog(CloudMartSettings settings, TokenCredential credential, ILogger<DataLakeCatalog> logger)
    : IDataLakeCatalog
{
    private readonly BlobServiceClient _lake = new(new Uri(settings.DataLakeEndpoint!), credential);

    public async Task<LakeFolderSummary> SummarizeAsync(string container, string? prefix, string extension, CancellationToken ct = default)
    {
        try
        {
            var files = new List<LakeFile>();
            await foreach (var blob in _lake.GetBlobContainerClient(container).GetBlobsAsync(BlobTraits.None, BlobStates.None, prefix, ct))
                files.Add(new LakeFile(blob.Name, blob.Properties.LastModified ?? DateTimeOffset.MinValue, blob.Properties.ContentLength ?? 0));

            return LakeFolderSummary.From(container, prefix, extension, files);
        }
        catch (RequestFailedException ex)
        {
            // 403 AuthorizationPermissionMismatch: no data role on the container (or not propagated yet).
            // 403 AuthorizationFailure: the lake's firewall, so the request didn't come through the private endpoint.
            return LakeFolderSummary.Failed(container, prefix, $"{ex.Status} {ex.ErrorCode}");
        }
        catch (AuthenticationFailedException ex)
        {
            // The full message lists every credential tried, with local paths: fine for the log, not for an
            // anonymous endpoint.
            logger.LogWarning(ex, "Could not get a token for the data lake");
            return LakeFolderSummary.Failed(container, prefix, "No token for the data lake: see the API's log");
        }
    }
}
