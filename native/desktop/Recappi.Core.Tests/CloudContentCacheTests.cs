using Recappi.Core;

internal static class CloudContentCacheTests
{
    public static async Task RunAsync(string root)
    {
        var directory = Path.Combine(root, "content-cache");
        var cache = new CloudContentCache(directory);
        var a = new CloudAccount("https://recappi.test", "a", null, "fixture").Partition;
        var b = new CloudAccount("https://recappi.test", "b", null, "fixture").Partition;
        var first = new CloudRecordingItem("first", "Budget meeting", "ready", 20000);
        cache.Save(a, first, new CloudTranscript("Plan release", "Review budget", "succeeded") { Segments = [new("Plan release", "Alice", 1000, 2000)] });
        cache.Save(a, new("second", "Engineering", "ready", 20000), new CloudTranscript("Ship release", "", "") { Segments = [new("Ship release", "Bob", 2000, 3000)] });
        var result = await cache.SearchAsync(a, "release");
        if (result.Hits.Count != 2 || result.CachedRecordings != 2 || result.Hits.Any(x => x.StartMs is null)) throw new Exception("Cross-recording cached transcript search failed.");
        if ((await cache.SearchAsync(a, "release", "Alice")).Hits.Count != 1 || (await cache.SearchAsync(a, "budget")).Hits.Count != 2) throw new Exception("Speaker/title/summary cache search failed.");
        if ((await cache.SearchAsync(b, "release")).CachedRecordings != 0 || cache.Load(b, "first") is not null) throw new Exception("Cache leaked across accounts.");
        if (new CloudContentCache(directory).Load(a, "first")?.Transcript.Segments.Single().Speaker != "Alice") throw new Exception("Cache did not survive reload.");
        await File.WriteAllBytesAsync(Path.Combine(directory, a, "damaged.dpapi"), [1, 2, 3]);
        result = await cache.SearchAsync(a, "release");
        if (result.Hits.Count != 2 || result.UnreadableRecordings != 1) throw new Exception("Damaged entry prevented intact cache search.");
        using var cancellation = new CancellationTokenSource(); cancellation.Cancel();
        try { await cache.SearchAsync(a, "release", cancellation: cancellation.Token); throw new Exception("Canceled search succeeded."); } catch (OperationCanceledException) { }
        cache.Delete(a, "first");
        var lateWriter = new CloudContentCache(directory);
        lateWriter.Save(a, first, new("Stale budget response", "", ""));
        if (lateWriter.Load(a, "first") is not null) throw new Exception("Late response resurrected a deleted recording.");
        var racing = new CloudRecordingItem("racing", "Race", "ready", 1000);
        await Task.WhenAll(Enumerable.Range(0, 20).Select(index => Task.Run(() =>
        {
            var contender = new CloudContentCache(directory);
            if (index % 3 == 0) contender.Delete(a, racing.Id); else contender.Save(a, racing, new("budget", "", ""));
        })));
        if (new CloudContentCache(directory).Load(a, racing.Id) is not null) throw new Exception("Concurrent cache save defeated remote deletion.");
        if ((await cache.SearchAsync(a, "budget")).Hits.Count != 0) throw new Exception("Deleted recording retained search results.");
    }
}
