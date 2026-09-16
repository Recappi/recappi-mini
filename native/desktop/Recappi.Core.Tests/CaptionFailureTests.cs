using System.Collections.Concurrent;
using System.Text.Json;
using System.Threading.Channels;
using Recappi.Core;

internal static class CaptionFailureTests
{
    public static async Task RunAsync(string root)
    {
        await FailedItemsReleaseCapacityAsync(root);
        await FailedTextRemainsExplicitAsync(root);
        await FailedStopTailDrainsAsync();
    }

    private static async Task FailedItemsReleaseCapacityAsync(string root)
    {
        var socket = new Connection();
        var observed = new ConcurrentQueue<CaptionDelta>();
        var attempts = 0;
        await using var captions = new LiveCaptions(new(), _ =>
        {
            Interlocked.Increment(ref attempts);
            return Task.FromResult<ICaptionConnection>(socket);
        }, [], autoStart: false);
        await using var engine = new RecordingEngine(new LocalRecordingStore(Path.Combine(root, "caption-item-failure")), _ => [new ConstantInput()]);
        var audioSeen = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        engine.Audio += _ => audioSeen.TrySetResult();
        engine.Audio += captions.Append;
        captions.Delta += observed.Enqueue;
        try
        {
            captions.Start();
            await engine.StartAsync(new("Failed sentence isolation", true, false));
            await audioSeen.Task.WaitAsync(TimeSpan.FromSeconds(3));
            for (var i = 0; i < 160; i++)
            {
                socket.Push(new { type = "input_audio_buffer.committed", item_id = "failed-" + i });
                socket.Push(new { type = "conversation.item.input_audio_transcription.failed", item_id = "failed-" + i, content_index = 0,
                    error = new { type = "transcription_error", code = "audio_unintelligible", message = "Provider diagnostic must not appear" } });
            }
            socket.Push(new { type = "conversation.item.input_audio_transcription.completed", item_id = "recovered", transcript = "Following sentence" });
            await WaitAsync(() => captions.Status.State == "failed" || observed.Any(x => x.Text == "Following sentence"));
            if (captions.Status.State != "live" || attempts != 1 || !observed.Any(x => x.Text == "Following sentence"))
                throw new Exception("Failed transcription items retained waiting capacity and interrupted the healthy connection.");
            if (observed.Count(x => x.IsFailed) != 160 || observed.Any(x => x.IsFailed && x.IsFinal))
                throw new Exception("Failed items were dropped or represented as successful final captions.");
            if (engine.Snapshot.State != RecordingState.Recording) throw new Exception("A failed transcription item stopped local recording.");
            var saved = await engine.StopAsync();
            if (saved is not { State: RecordingState.Done } || new FileInfo(saved.AudioPath).Length <= 44)
                throw new Exception("Per-item caption failures prevented WAV finalization.");
        }
        finally { await captions.AbortAsync(); }
    }

    private static async Task FailedTextRemainsExplicitAsync(string root)
    {
        var store = new LocalRecordingStore(Path.Combine(root, "caption-failure-archive"));
        var recording = store.Create("Incomplete caption archive");
        var archivePath = store.CaptionPath(recording);
        var socket = new Connection();
        var observed = new ConcurrentQueue<CaptionDelta>();
        await using (var archive = new CaptionArchive(archivePath))
        await using (var captions = new LiveCaptions(new(), _ => Task.FromResult<ICaptionConnection>(socket), autoStart: false))
        {
            captions.Delta += observed.Enqueue;
            captions.Delta += archive.Append;
            captions.Start();
            for (var i = 0; i < 4; i++) socket.Push(new { type = "input_audio_buffer.committed", item_id = "item-" + i });
            socket.Push(new { type = "conversation.item.input_audio_transcription.delta", item_id = "item-0", delta = "Partial words" });
            Fail("item-0"); Fail("item-0");
            socket.Push(new { type = "conversation.item.input_audio_transcription.delta", item_id = "item-0", delta = "Stale words" });
            socket.Push(new { type = "conversation.item.input_audio_transcription.completed", item_id = "item-0", transcript = "Stale success" });
            Fail("item-1");
            socket.Push(new { type = "conversation.item.input_audio_transcription.completed", item_id = "item-2", transcript = "Recovered sentence" });
            Fail("item-2"); // A success cannot be replaced by a duplicated terminal event either.
            socket.Push(new { type = "conversation.item.input_audio_transcription.delta", item_id = "item-3", content_index = 1, delta = "Other content" });
            Fail("item-3", 1);
            socket.Push(new { type = "conversation.item.input_audio_transcription.completed", item_id = "item-3", content_index = 0, transcript = "Sibling content" });
            await WaitAsync(() => observed.Any(x => x.Text == "Sibling content"));
            await captions.AbortAsync();
            if (archive.Error is not null) throw new Exception("Small failure fixture overflowed or failed to persist.");
        }
        var terminal = observed.Where(x => x.IsFinal || x.IsFailed).ToArray();
        if (terminal.Length != 5 || terminal.Count(x => x.IsFailed) != 3 || terminal.Any(x => x.IsFinal && x.IsFailed) ||
            terminal.Any(x => x.Text.Contains("Stale") || x.Text.Contains("Provider diagnostic")))
            throw new Exception("Failed caption terminal state was duplicated, overwritten or exposed provider diagnostics.");
        var archived = CaptionArchiveOrder.Read(archivePath).ToArray();
        if (archived.Length != 5 || archived.Count(x => x.IsFailed) != 3 || archived[0].Text != "Partial words" ||
            archived[1].Text != "" || archived[2].IsFailed || archived[3].Text != "Sibling content" || !archived[4].IsFailed)
            throw new Exception("Failed/empty/partial/content-index caption archive lost its outcome or position.");
        var destination = Path.Combine(root, "caption-failure-export.txt");
        CaptionExport.Save(store, recording, destination, false);
        if (!File.ReadAllLines(destination).SequenceEqual(new[]
        {
            "[原文] Partial words［字幕未完成］", "[原文] ［此段字幕未能识别］", "[原文] Recovered sentence",
            "[原文] Sibling content", "[原文] Other content［字幕未完成］"
        })) throw new Exception("Text export presented incomplete captions as a successful transcript.");
        CaptionExport.Save(store, recording, destination, true);
        if (!File.ReadAllBytes(destination).SequenceEqual(File.ReadAllBytes(archivePath))) throw new Exception("Raw failure archive export changed bytes.");

        void Fail(string item, int content = 0) => socket.Push(new
        {
            type = "conversation.item.input_audio_transcription.failed", item_id = item, content_index = content,
            error = new { message = "Provider diagnostic must not appear", code = "audio_unintelligible" }
        });
    }

    private static async Task FailedStopTailDrainsAsync()
    {
        var socket = new Connection(failCommits: true);
        var failure = new TaskCompletionSource<CaptionDelta>(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var captions = new LiveCaptions(new(), _ => Task.FromResult<ICaptionConnection>(socket), autoStart: false);
        captions.Delta += value => { if (value.IsFailed) failure.TrySetResult(value); };
        captions.Start();
        await WaitAsync(() => captions.Status.State == "live");
        captions.Append(new float[960]);
        var stopping = captions.StopAsync();
        var tail = await failure.Task.WaitAsync(TimeSpan.FromSeconds(3));
        // Check after the terminal event arrives, excluding connection or send latency.
        await stopping.WaitAsync(TimeSpan.FromSeconds(1));
        if (tail.IsFinal || tail.Text != "Tail words" || captions.Status.State != "stopped" || captions.BufferedChunks != 0)
            throw new Exception("Failed last commit was not drained as an incomplete caption.");
    }

    private static async Task WaitAsync(Func<bool> condition)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        while (!condition()) await Task.Delay(10, timeout.Token);
    }

    private sealed class ConstantInput : IAudioInput
    {
        public string Input => "system";
        public Exception? Error => null;
        public void Start() { }
        public void Read(float[] destination) => Array.Fill(destination, 0.2f);
        public void Stop() { }
        public void Dispose() { }
    }

    private sealed class Connection(bool failCommits = false) : ICaptionConnection
    {
        private readonly Channel<JsonElement> incoming = Channel.CreateUnbounded<JsonElement>();
        public void Push(object value) => incoming.Writer.TryWrite(JsonSerializer.SerializeToElement(value));
        public Task SendAsync(object value, CancellationToken cancellation)
        {
            if (failCommits && JsonSerializer.SerializeToElement(value).GetProperty("type").GetString() == "input_audio_buffer.commit")
            {
                Push(new { type = "input_audio_buffer.committed", item_id = "tail" });
                Push(new { type = "conversation.item.input_audio_transcription.delta", item_id = "tail", delta = "Tail words" });
                Push(new { type = "conversation.item.input_audio_transcription.failed", item_id = "tail", content_index = 0 });
            }
            return Task.CompletedTask;
        }
        public async Task<JsonElement?> ReceiveAsync(CancellationToken cancellation)
        {
            try { return await incoming.Reader.ReadAsync(cancellation); }
            catch (ChannelClosedException) { return null; }
        }
        public ValueTask DisposeAsync() { incoming.Writer.TryComplete(); return ValueTask.CompletedTask; }
    }
}
