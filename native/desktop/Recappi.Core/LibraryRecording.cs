namespace Recappi.Core;

public sealed record LibraryRecording(LocalRecording? Local, CloudRecordingItem? Cloud)
{
    public string Key => Local is { } local ? "local/" + local.Id : "cloud/" + Cloud!.Id;
    public string Title => Cloud?.Title ?? Local!.Title;
    public DateTimeOffset? CreatedAt => Local?.StartedAt ?? Cloud?.CreatedAt;
    public string Location => Local is not null && Cloud is not null ? "本机与云端" : Local is not null ? "本机" : "云端";
    public override string ToString() => Title;

    public static IReadOnlyList<LibraryRecording> Merge(IReadOnlyList<LocalRecording> local,
        IReadOnlyList<CloudRecordingItem> cloud, IReadOnlyList<ProcessingEntry> processing, string? partition)
    {
        var availableLocal = local.Select(x => x.Id).ToHashSet(StringComparer.Ordinal);
        var links = processing.Where(x => partition is not null && x.Partition == partition && x.UploadCompleted &&
            x.Ticket is not null && availableLocal.Contains(x.LocalId))
            .GroupBy(x => x.Ticket!.Id, StringComparer.Ordinal)
            .Where(x => x.Select(y => y.LocalId).Distinct(StringComparer.Ordinal).Count() == 1)
            .ToDictionary(x => x.Key, x => x.First().LocalId, StringComparer.Ordinal);
        // Ambiguous local-to-cloud links also remain separate: never hide a recording by guessing.
        var uniqueLocal = links.Values.GroupBy(x => x, StringComparer.Ordinal).Where(x => x.Count() == 1)
            .Select(x => x.Key).ToHashSet(StringComparer.Ordinal);
        var byLocal = cloud.Where(x => links.TryGetValue(x.Id, out var id) && uniqueLocal.Contains(id))
            .DistinctBy(x => x.Id).ToDictionary(x => links[x.Id], StringComparer.Ordinal);
        var mergedCloudIds = byLocal.Values.Select(x => x.Id).ToHashSet(StringComparer.Ordinal);
        return local.Select(x => new LibraryRecording(x, byLocal.GetValueOrDefault(x.Id)))
            .Concat(cloud.DistinctBy(x => x.Id).Where(x => !mergedCloudIds.Contains(x.Id)).Select(x => new LibraryRecording(null, x)))
            .ToArray();
    }
}
