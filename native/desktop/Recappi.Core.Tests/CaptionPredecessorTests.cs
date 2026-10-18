using System.Collections.Concurrent;
using System.Text.Json;
using System.Threading.Channels;
using Recappi.Core;

internal static class CaptionPredecessorTests
{
    public static async Task RunAsync(string root)
    {
        await VerifyAsync(root, "missing-predecessor", [
            Completed("B", "Bravo", "A"), Completed("A", "Alpha")
        ], ["Alpha", "Bravo"]);
        await VerifyAsync(root, "commit-backfill", [
            Commit("C", "B"), Commit("A"), Commit("B", "A"),
            Completed("C", "Charlie second", content: 1), Completed("A", "Alpha"),
            Completed("C", "Charlie first"), Completed("B", "Bravo")
        ], ["Alpha", "Bravo", "Charlie first", "Charlie second"]);
        await VerifyAsync(root, "late-commit", [
            Completed("B", "Bravo"), Completed("C", "Charlie", "B"), Completed("A", "Alpha"),
            Commit("B", "A"), Commit("B", "A"), Completed("tail", "Tail", "C")
        ], ["Alpha", "Bravo", "Charlie", "Tail"]);
        await VerifyAsync(root, "insert-after-known", [
            Completed("A", "Alpha"), Completed("C", "Charlie"), Completed("B", "Bravo", "A")
        ], ["Alpha", "Bravo", "Charlie"]);
        await LargeRevisionAsync(root);

        long sequence = 0;
        var bounded = new CaptionTimeline(() => ++sequence);
        for (var index = 0; index < 700; index++)
        {
            var id = "item-" + index;
            if (bounded.Register(id, index == 0 ? null : "item-" + (index - 1), _ => false).Count != 0)
                throw new Exception("Normal append revised historical captions.");
            bounded.Remember(id, new(id, "source", id, true, bounded.Position(id, "session", 0)));
            if (bounded.Count > 256 || bounded.ContentCount > 512) throw new Exception("Caption predecessor cache grew without a bound.");
        }
        var unresolved = new CaptionTimeline(() => ++sequence);
        for (var index = 0; index < 256; index++) unresolved.Register("pending-" + index, null, _ => true);
        try { unresolved.Register("overflow", null, _ => true); throw new Exception("Unresolved timeline silently retired a pending prefix."); }
        catch (IOException) { }
        var cycle = new CaptionTimeline(() => ++sequence);
        cycle.Register("A", "B", _ => false);
        try { cycle.Register("B", "A", _ => false); throw new Exception("Caption predecessor cycle was accepted."); }
        catch (InvalidDataException) { }
        Console.WriteLine("PASS caption predecessor backfill, late commits, insertion, content parts, archive revisions and bounded/cyclic timelines.");
    }

    private static async Task LargeRevisionAsync(string root)
    {
        long next = 0;
        var timeline = new CaptionTimeline(() => ++next);
        var originals = new List<ArchivedCaption>();
        for (var index = 0; index < 250; index++)
        {
            var id = "B" + index;
            timeline.Register(id, index == 0 ? null : "B" + (index - 1), _ => false);
            var caption = new CaptionDelta(id, "source", id, true, timeline.Position(id, "large", 0));
            timeline.Remember(id, caption);
            originals.Add(new(id, "source", id, DateTimeOffset.UtcNow, caption.Position));
        }
        timeline.Register("A", null, _ => false);
        var first = new CaptionDelta("A", "source", "A", true, timeline.Position("A", "large", 0));
        timeline.Remember("A", first);
        originals.Add(new("A", "source", "A", DateTimeOffset.UtcNow, first.Position));
        var changes = timeline.Register("B0", "A", _ => false);
        if (changes.Count != 251) throw new Exception("Large predecessor repair did not revise the whole affected subtree.");
        var path = Path.Combine(root, "large-revision.jsonl");
        await File.WriteAllLinesAsync(path, originals.Select(x => JsonSerializer.Serialize(x)));
        var archive = new CaptionArchive(path, resume: true);
        await using (archive)
        {
            archive.AppendRevisions(changes);
        }
        if (archive.Error is not null) throw new Exception("A single valid order revision exceeded archive capacity.");
        var expected = new[] { "A" }.Concat(Enumerable.Range(0, 250).Select(x => "B" + x));
        if (!CaptionArchiveOrder.Read(path).Select(x => x.Text).SequenceEqual(expected) || CaptionArchive.Read(path).Count(x => x.IsRevision) != 251)
            throw new Exception("Large correction lost revision history or duplicated final exported text.");
    }

    private static async Task VerifyAsync(string root, string name, object[] events, string[] expected)
    {
        var path = Path.Combine(root, name + ".jsonl");
        var latest = new ConcurrentDictionary<string, CaptionDelta>();
        var connection = new Connection();
        await using (var archive = new CaptionArchive(path))
        await using (var captions = new LiveCaptions(new(), _ => Task.FromResult<ICaptionConnection>(connection), [], autoStart: false))
        {
            captions.Delta += value => latest[value.SegmentId] = value;
            captions.Delta += archive.Append;
            captions.Reordered += values => { foreach (var value in values) latest[value.SegmentId] = value; };
            captions.Reordered += archive.AppendRevisions;
            captions.Start();
            foreach (var value in events) connection.Push(value);
            for (var attempt = 0; attempt < 200 && latest.Count != expected.Length; attempt++) await Task.Delay(10);
            var actual = latest.Values.OrderBy(x => x.Position!.Sequence).ThenBy(x => x.Position!.ContentIndex).Select(x => x.Text).ToArray();
            if (!actual.SequenceEqual(expected)) throw new Exception(name + " did not follow predecessor order: " + string.Join(" | ", actual));
            // In late-commit mode every item is already terminal. Repeated or late
            // acknowledgements must not create a fresh unresolved drain obligation.
            if (name == "late-commit") await captions.StopAsync().WaitAsync(TimeSpan.FromMilliseconds(600));
            else await captions.AbortAsync();
            if (archive.Error is not null) throw new Exception("Position correction overflowed caption archive: " + archive.Error);
        }
        if (!CaptionArchiveOrder.Read(path).Select(x => x.Text).SequenceEqual(expected))
            throw new Exception(name + " archive exported stale or duplicate caption revisions.");
    }

    private static object Commit(string item, string? previous = null) => new { type = "input_audio_buffer.committed", item_id = item, previous_item_id = previous };
    private static object Completed(string item, string text, string? previous = null, int content = 0) => new
        { type = "conversation.item.input_audio_transcription.completed", item_id = item, previous_item_id = previous, content_index = content, transcript = text };
    private sealed class Connection : ICaptionConnection
    {
        private readonly Channel<JsonElement> messages = Channel.CreateUnbounded<JsonElement>();
        public void Push(object value) => messages.Writer.TryWrite(JsonSerializer.SerializeToElement(value));
        public Task SendAsync(object value, CancellationToken cancellation) => Task.CompletedTask;
        public async Task<JsonElement?> ReceiveAsync(CancellationToken cancellation) => await messages.Reader.ReadAsync(cancellation);
        public ValueTask DisposeAsync() { messages.Writer.TryComplete(); return ValueTask.CompletedTask; }
    }
}
