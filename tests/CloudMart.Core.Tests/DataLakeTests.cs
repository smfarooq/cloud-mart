using System.Globalization;
using CloudMart.Core.Analytics;

namespace CloudMart.Core.Tests;

/// <summary>Phase 14: what the Platform page says about the data lake.</summary>
public class DataLakeTests
{
    private static readonly DateTimeOffset Night = new(2026, 10, 30, 2, 1, 0, TimeSpan.Zero);

    [Fact]
    public void Summary_counts_only_files_with_the_extension()
    {
        var files = new[]
        {
            // A hierarchical namespace lists directories as empty blobs.
            new LakeFile("snapshot_date=2026-10-29", Night.AddDays(-1), 0),
            new LakeFile("snapshot_date=2026-10-29/order_lines.parquet", Night.AddDays(-1), 1_000),
            new LakeFile("snapshot_date=2026-10-30/order_lines.PARQUET", Night, 1_500),
            new LakeFile("snapshot_date=2026-10-30/_SUCCESS", Night.AddMinutes(1), 0),
        };

        var summary = LakeFolderSummary.From("orders", null, ".parquet", files);

        Assert.Equal(2, summary.Files);
        Assert.Equal(2_500, summary.TotalBytes);
        Assert.Equal("snapshot_date=2026-10-30/order_lines.PARQUET", summary.Latest!.Path);
        Assert.Null(summary.Error);
    }

    [Fact]
    public void Summary_of_a_folder_with_no_matching_files_has_no_latest_file()
    {
        var summary = LakeFolderSummary.From("clickstream", "2026/10/30/", ".avro", [new LakeFile("2026/10/30", Night, 0)]);

        Assert.Equal(0, summary.Files);
        Assert.Null(summary.Latest);
    }

    [Fact]
    public void Capture_day_prefix_is_the_UTC_date_with_slashes_in_any_culture()
    {
        var original = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = new CultureInfo("de-DE"); // its date separator is "."

            // 23:30 in New York is already the next day in UTC, which is the day Capture files it under.
            var prefix = LakePaths.CaptureDayPrefix(new DateTimeOffset(2026, 10, 30, 23, 30, 0, TimeSpan.FromHours(-4)));

            Assert.Equal("2026/10/31/", prefix);
        }
        finally
        {
            CultureInfo.CurrentCulture = original;
        }
    }
}
