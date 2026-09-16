using Recappi.Core;

internal static class CaptionExportTests
{
    public static async Task RunAsync(string root)
    {
        var directory = Path.Combine(root, "caption-export");
        var store = new LocalRecordingStore(Path.Combine(directory, "recordings"));
        var recording = store.Create("Export test");
        var source = store.CaptionPath(recording);
        File.WriteAllText(source, "{\"SegmentId\":\"1\",\"Stream\":\"original\",\"Text\":\"Hello\"}\n{\"SegmentId\":\"2\",\"Stream\":\"translation\",\"Text\":\"你好\"}\n");
        var target = Path.Combine(directory, "export.txt");
        File.WriteAllText(target, "existing");
        using (var lockedSource = new FileStream(source, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            try { CaptionExport.Save(store, recording, target, false); throw new Exception("Locked source accepted."); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        if (File.ReadAllText(target) != "existing") throw new Exception("Source failure destroyed destination.");
        using (var lockedTarget = new FileStream(target, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            try { CaptionExport.Save(store, recording, target, false); throw new Exception("Locked destination accepted."); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
        if (File.ReadAllText(target) != "existing" || Directory.EnumerateFiles(directory, ".recappi-export-*.tmp").Any())
            throw new Exception("Failed commit destroyed destination or leaked temporary output.");
        foreach (var protectedPath in new[] { source, recording.AudioPath, Path.Combine(recording.Directory, "desktop-session.json") })
        {
            try { CaptionExport.Save(store, recording, protectedPath, false); throw new Exception("Library destination accepted."); }
            catch (InvalidOperationException) { }
        }
        CaptionExport.Save(store, recording, target, false);
        if (File.ReadAllText(target) != "[原文] Hello" + Environment.NewLine + "[译文] 你好" + Environment.NewLine)
            throw new Exception("Bilingual text export changed content.");
        CaptionExport.Save(store, recording, target, true);
        if (!File.ReadAllBytes(target).SequenceEqual(File.ReadAllBytes(source))) throw new Exception("Archive export changed bytes.");
        File.Delete(source);
        var before = File.ReadAllBytes(target);
        try { CaptionExport.Save(store, recording, target, false); throw new Exception("Missing source accepted."); }
        catch (FileNotFoundException) { }
        if (!before.SequenceEqual(File.ReadAllBytes(target))) throw new Exception("Missing source destroyed destination.");
        var entries = new List<ArchivedCaption> { new("legacy", "source", "Legacy first", DateTimeOffset.UtcNow) };
        // More than sixteen batches exercises multiple external merge levels. A resumed
        // process may restart its numeric sequence and must still follow the old session.
        foreach (var session in new[] { "first", "resumed" })
            for (var i = 2050; i >= 0; i--)
                entries.Add(new(session + i, "source", session + " " + i, DateTimeOffset.UtcNow, new(session, i)));
        entries.Add(new("legacy-last", "translation", "Legacy last", DateTimeOffset.UtcNow));
        await File.WriteAllLinesAsync(source, entries.Select(x => System.Text.Json.JsonSerializer.Serialize(x)));
        await File.AppendAllTextAsync(source, "{\"partial\":");
        var scratchBefore = Directory.GetDirectories(Path.GetTempPath(), "recappi-caption-sort-*").Order().ToArray();
        CaptionExport.Save(store, recording, target, false);
        var expected = new[] { "[原文] Legacy first" }
            .Concat(new[] { "first", "resumed" }.SelectMany(session => Enumerable.Range(0, 2051).Select(i => "[原文] " + session + " " + i)))
            .Append("[译文] Legacy last");
        if (!File.ReadLines(target).SequenceEqual(expected)) throw new Exception("Long caption export lost commit/session order or intact captions before a partial line.");
        if (!CaptionArchiveOrder.Read(source).Take(1).Select(x => x.Text).SequenceEqual(new[] { "Legacy first" })) throw new Exception("Early reader disposal changed the first caption.");
        if (!scratchBefore.SequenceEqual(Directory.GetDirectories(Path.GetTempPath(), "recappi-caption-sort-*").Order()))
            throw new Exception("Caption external sort leaked temporary files after completion or early disposal.");
        CaptionExport.Save(store, recording, target, true);
        if (!File.ReadAllBytes(target).SequenceEqual(File.ReadAllBytes(source))) throw new Exception("Ordered caption metadata changed raw archive export.");
        await Task.CompletedTask;
    }
}
