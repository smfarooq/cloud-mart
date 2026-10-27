using Azure;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Azure.Storage.Sas;
using CloudMart.Core.Domain;
using CloudMart.Core.Services;
using Microsoft.Extensions.Logging;

namespace CloudMart.Core.Azure;

/// <summary>
/// Images in Blob Storage, with shared-key access disabled on the account. Uploads use the valet-key pattern:
/// the API hands the browser a short-lived, write-only user delegation SAS (signed by an Entra-issued key, not the
/// account key) and the browser PUTs the file straight to Blob Storage. Event Grid then tells a Function about it.
/// </summary>
public sealed class BlobImageStore(BlobServiceClient service, CloudMartSettings settings, ILogger<BlobImageStore> logger)
    : IImageStore, IHealthProbe
{
    private readonly BlobContainerClient _uploads = service.GetBlobContainerClient(settings.UploadContainer);
    private readonly BlobContainerClient _images = service.GetBlobContainerClient(settings.ImageContainer);
    private readonly SemaphoreSlim _keyLock = new(1, 1);
    private UserDelegationKey? _delegationKey;

    public string Name => "blob-storage";

    public async Task<UploadTarget> CreateUploadTargetAsync(string productId, string fileName, string contentType, CancellationToken ct = default)
    {
        var blobName = ImageRules.CreateUploadName(productId, fileName);
        var expires = DateTimeOffset.UtcNow.AddMinutes(10);
        var sas = new BlobSasBuilder(BlobSasPermissions.Create | BlobSasPermissions.Write, expires)
        {
            BlobContainerName = _uploads.Name,
            BlobName = blobName,
            Resource = "b",
            StartsOn = DateTimeOffset.UtcNow.AddMinutes(-5), // tolerate clock skew
        };

        var key = await GetDelegationKeyAsync(ct);
        var uri = new BlobUriBuilder(_uploads.GetBlobClient(blobName).Uri)
        {
            Sas = sas.ToSasQueryParameters(key, service.AccountName),
        }.ToUri();

        return new UploadTarget(
            uri.ToString(),
            "PUT",
            new Dictionary<string, string> { ["x-ms-blob-type"] = "BlockBlob", ["Content-Type"] = contentType },
            blobName,
            expires);
    }

    public async Task<StoredImage?> OpenReadAsync(string imageName, CancellationToken ct = default)
    {
        try
        {
            var download = await _images.GetBlobClient(imageName).DownloadStreamingAsync(cancellationToken: ct);
            return new StoredImage(download.Value.Content, download.Value.Details.ContentType ?? "application/octet-stream");
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            return null;
        }
    }

    public async Task<string?> PromoteUploadAsync(string uploadName, CancellationToken ct = default)
    {
        var source = _uploads.GetBlobClient(uploadName);
        BlobProperties properties;
        try
        {
            properties = await source.GetPropertiesAsync(cancellationToken: ct);
        }
        catch (RequestFailedException ex) when (ex.Status == 404)
        {
            return null; // already processed: Event Grid delivers at least once
        }

        if (!ImageRules.IsAllowed(properties.ContentType, properties.ContentLength))
        {
            logger.LogWarning("Rejecting upload {UploadName}: {ContentType}, {Length} bytes", uploadName, properties.ContentType, properties.ContentLength);
            await source.DeleteIfExistsAsync(cancellationToken: ct);
            return null;
        }

        var content = await source.DownloadContentAsync(ct);
        await _images.GetBlobClient(uploadName).UploadAsync(
            content.Value.Content,
            new BlobUploadOptions
            {
                HttpHeaders = new BlobHttpHeaders { ContentType = properties.ContentType, CacheControl = "public, max-age=86400" },
            },
            ct);
        await source.DeleteIfExistsAsync(cancellationToken: ct);
        return uploadName;
    }

    public Task CheckAsync(CancellationToken ct) => _images.GetPropertiesAsync(cancellationToken: ct);

    private async Task<UserDelegationKey> GetDelegationKeyAsync(CancellationToken ct)
    {
        if (_delegationKey is { } cached && cached.SignedExpiresOn > DateTimeOffset.UtcNow.AddMinutes(15))
            return cached;

        await _keyLock.WaitAsync(ct);
        try
        {
            if (_delegationKey is { } fresh && fresh.SignedExpiresOn > DateTimeOffset.UtcNow.AddMinutes(15))
                return fresh;

            // Needs "Storage Blob Delegator" (or a Blob Data role) on the account for the app's managed identity.
            var now = DateTimeOffset.UtcNow;
            _delegationKey = await service.GetUserDelegationKeyAsync(now.AddMinutes(-5), now.AddHours(1), ct);
            return _delegationKey;
        }
        finally
        {
            _keyLock.Release();
        }
    }
}
