using System.Globalization;

namespace CloudMart.Core.Analytics;

// Phase 14. The app never writes the data lake: Data Factory copies the orders database into it every night, and Event
// Hubs Capture lands the click stream. The API only lists what arrived, so the Platform page can show it.

/// <summary>A file in the data lake.</summary>
public sealed record LakeFile(string Path, DateTimeOffset LastModified, long SizeBytes);

/// <summary>What one container (or one folder of it) holds: how many files of one kind, their size, the newest.</summary>
public sealed record LakeFolderSummary(string Container, string? Prefix, int Files, long TotalBytes, LakeFile? Latest, string? Error = null)
{
    /// <summary>
    /// Counts only the files with this extension. A hierarchical namespace lists its directories as empty blobs too,
    /// and tools such as Spark leave marker files (_SUCCESS) next to their output.
    /// </summary>
    public static LakeFolderSummary From(string container, string? prefix, string extension, IEnumerable<LakeFile> files)
    {
        var matching = files.Where(f => f.Path.EndsWith(extension, StringComparison.OrdinalIgnoreCase)).ToList();
        return new LakeFolderSummary(container, prefix, matching.Count, matching.Sum(f => f.SizeBytes), matching.MaxBy(f => f.LastModified));
    }

    public static LakeFolderSummary Failed(string container, string? prefix, string error) => new(container, prefix, 0, 0, null, error);
}

public static class LakePaths
{
    /// <summary>
    /// The folder Event Hubs Capture writes one UTC day's files to. Matches the archive name format in
    /// messaging.bicep, which puts {Year}/{Month}/{Day} first so that a day is one prefix.
    /// </summary>
    public static string CaptureDayPrefix(DateTimeOffset now) =>
        now.UtcDateTime.ToString("yyyy/MM/dd/", CultureInfo.InvariantCulture);
}

/// <summary>Lists what has landed in the data lake (phase 14).</summary>
public interface IDataLakeCatalog
{
    Task<LakeFolderSummary> SummarizeAsync(string container, string? prefix, string extension, CancellationToken ct = default);
}
