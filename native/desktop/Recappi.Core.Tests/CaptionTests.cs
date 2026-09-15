using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Net;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using Recappi.Core;

internal static class CaptionTests
{
    public static async Task RunAsync()
    {
        await DeferredStartupAsync();
        var encoder = new CaptionPcmEncoder();
        if (encoder.Encode([1]).Length != 0) throw new Exception("Odd input must carry to next chunk.");
        var encoded = encoder.Encode([1, float.NaN, 0, -2, -1]);
        if (encoded.Length != 6 || BinaryPrimitives.ReadInt16LittleEndian(encoded) != 32767 || BinaryPrimitives.ReadInt16LittleEndian(encoded.AsSpan(2)) != 0 || BinaryPrimitives.ReadInt16LittleEndian(encoded.AsSpan(4)) != -32768) throw new Exception("Caption PCM resampling/clamping failed.");

        using (var client = new CloudClient("https://example.test", "account-token", new ClaimHandler()))
        {
            var claim = await client.CaptionSessionAsync(new("zh-CN", "en-US"));
            if (claim.Validate().Scheme != "wss" || claim.ToString().Contains("ephemeral-token")) throw new Exception("Claim validation/redaction failed.");
        }
        await using (var bounded = new LiveCaptions(new(), async cancellation => { await Task.Delay(Timeout.Infinite, cancellation); throw new Exception(); }))
        {
            for (var i = 0; i < 2000; i++) bounded.Append(new float[4800]);
            if (bounded.BufferedChunks > 50) throw new Exception("Caption queue was unbounded.");
            await bounded.AbortAsync();
            if (bounded.BufferedChunks != 0) throw new Exception("Stopped captions retained audio.");
        }
        var socket = new FakeConnection(); var deltas = new ConcurrentQueue<CaptionDelta>();
        await using (var captions = new LiveCaptions(new(), _ => Task.FromResult<ICaptionConnection>(socket)))
        {
            captions.Delta += deltas.Enqueue;
            captions.Delta += _ => throw new Exception("Closed observer");
            await WaitAsync(() => captions.Status.State == "live");
            captions.Append(new float[960]); // 20 ms input; last commit must be padded to 100 ms.
            await WaitAsync(() => socket.Sent.Count > 0);
            await captions.StopAsync().WaitAsync(TimeSpan.FromSeconds(3));
            if (!deltas.Any(x => x.IsFinal && x.Text == "最终字幕") || captions.Status.State != "stopped") throw new Exception("Final transcript was not drained.");
            var audioBytes = socket.Sent.Where(x => x.GetProperty("type").GetString() == "input_audio_buffer.append").Sum(x => Convert.FromBase64String(x.GetProperty("audio").GetString()!).Length);
            if (audioBytes != 4800 || socket.Sent.Count(x => x.GetProperty("type").GetString() == "input_audio_buffer.commit") != 1) throw new Exception("Final commit audio padding incorrect.");
        }
        var attempts = 0; var reconnected = new FakeConnection();
        await using (var captions = new LiveCaptions(new(), _ => ++attempts == 1 ? Task.FromException<ICaptionConnection>(new IOException()) : Task.FromResult<ICaptionConnection>(reconnected), [TimeSpan.Zero]))
        {
            await WaitAsync(() => captions.Status.State == "live");
            if (attempts != 2) throw new Exception("Caption reconnect count incorrect.");
            await captions.AbortAsync();
        }
        var translation = new FakeConnection(); var translated = new ConcurrentQueue<CaptionDelta>();
        var retryFirst = new FakeConnection(); var retrySecond = new FakeConnection(); var retryAttempts = 0;
        var retryDeltas = new ConcurrentQueue<CaptionDelta>();
        var archivePath = Path.GetFullPath(Path.Combine("build/native-desktop-validation", "retry-captions-" + Guid.NewGuid().ToString("N") + ".jsonl"));
        await using (var archive = new CaptionArchive(archivePath))
        await using (var retried = new LiveCaptions(new(), _ => Task.FromResult<ICaptionConnection>(Interlocked.Increment(ref retryAttempts) == 1 ? retryFirst : retrySecond), []))
        {
            retried.Delta += retryDeltas.Enqueue; retried.Delta += archive.Append;
            await WaitAsync(() => retried.Status.State == "live");
            retryFirst.Push(new { type = "conversation.item.input_audio_transcription.completed", item_id = "same", content_index = 0, transcript = "Before retry" });
            await WaitAsync(() => retryDeltas.Count == 1);
            retryFirst.Close();
            await WaitAsync(() => retried.Status.State == "failed");
            retried.Append(new float[4800]);
            if (retried.BufferedChunks != 0 || !retried.TryRetry() || retried.TryRetry()) throw new Exception("Failed captions buffered audio or accepted duplicate retry.");
            await WaitAsync(() => retried.Status.State == "live");
            retrySecond.Push(new { type = "conversation.item.input_audio_transcription.completed", item_id = "same", content_index = 0, transcript = "After retry" });
            await WaitAsync(() => retryDeltas.Count == 2);
            if (retryAttempts != 2 || retryDeltas.Select(x => x.SegmentId).Distinct().Count() != 2) throw new Exception("Manual retry reused the old connection or segment identity.");
            await retried.AbortAsync();
            if (retried.TryRetry()) throw new Exception("Stopped captions accepted retry.");
        }
        if (!CaptionArchive.Read(archivePath).Select(x => x.Text).SequenceEqual(new[] { "Before retry", "After retry" })) throw new Exception("Manual retry lost existing or new archived captions.");
        await File.AppendAllTextAsync(archivePath, "{\"incomplete\":");
        await using (var resumedArchive = new CaptionArchive(archivePath, resume: true))
            resumedArchive.Append(new("resumed", "source", "After login", true));
        if (!CaptionArchive.Read(archivePath).Select(x => x.Text).SequenceEqual(new[] { "Before retry", "After retry", "After login" })) throw new Exception("Archive resume overwrote prior captions or joined a new entry to a partial line.");
        await using (var captions = new LiveCaptions(new("zh", "en"), _ => Task.FromResult<ICaptionConnection>(translation)))
        {
            captions.Delta += translated.Enqueue;
            await WaitAsync(() => captions.Status.State == "live");
            translation.Push(new { type = "session.input_transcript.delta", delta = "你好" });
            translation.Push(new { type = "session.output_transcript.delta", delta = "Hello" });
            await WaitAsync(() => translated.Count >= 2);
            await captions.StopAsync();
            if (!translated.Any(x => x.Stream == "source" && x.IsFinal && x.Text == "你好") || !translated.Any(x => x.Stream == "translation" && x.IsFinal && x.Text == "Hello")) throw new Exception("Independent translation/source streams were lost.");
        }
    }
    private static async Task DeferredStartupAsync()
    {
        var directory = Path.GetFullPath(Path.Combine("build/native-desktop-validation", "caption-startup-" + Guid.NewGuid().ToString("N")));
        Directory.CreateDirectory(directory);
        var firstPath = Path.Combine(directory, "first.jsonl");
        var firstSocket = new FakeConnection();
        firstSocket.Push(new { type = "conversation.item.input_audio_transcription.completed", item_id = "first", transcript = "Immediate first caption" });
        var connects = 0;
        var observed = new ConcurrentQueue<CaptionDelta>();
        await using (var archive = new CaptionArchive(firstPath))
        await using (var captions = new LiveCaptions(new(), _ => { Interlocked.Increment(ref connects); return Task.FromResult<ICaptionConnection>(firstSocket); }, autoStart: false))
        {
            await Task.Delay(50);
            if (connects != 0) throw new Exception("Deferred captions connected before observers were ready.");
            captions.Delta += observed.Enqueue;
            captions.Delta += archive.Append;
            if (!captions.Start() || captions.Start()) throw new Exception("Deferred startup was not single-use.");
            await WaitAsync(() => observed.Any(x => x.Text == "Immediate first caption"));
            await captions.AbortAsync().WaitAsync(TimeSpan.FromSeconds(3));
        }
        if (connects != 1 || !CaptionArchive.Read(firstPath).Any(x => x.Text == "Immediate first caption"))
            throw new Exception("The first provider caption was lost before archive/window subscription.");

        foreach (var abort in new[] { false, true })
        {
            var earlyConnects = 0;
            await using var captions = new LiveCaptions(new(), _ => { Interlocked.Increment(ref earlyConnects); return Task.FromResult<ICaptionConnection>(new FakeConnection()); }, autoStart: false);
            for (var index = 0; index < 100; index++) captions.Append(new float[4800]);
            if (captions.BufferedChunks is < 1 or > 50) throw new Exception("Deferred startup audio was not bounded.");
            await (abort ? captions.AbortAsync() : captions.StopAsync()).WaitAsync(TimeSpan.FromSeconds(3));
            captions.Append(new float[4800]);
            if (earlyConnects != 0 || captions.BufferedChunks != 0 || captions.Start() || captions.TryRetry() || captions.Status.State != "stopped")
                throw new Exception("Stopping before startup connected, retained audio, or allowed resurrection.");
        }

        // A directory at the destination guarantees a real file-open failure.
        var blockedPath = Path.Combine(directory, "blocked.jsonl");
        Directory.CreateDirectory(blockedPath);
        var warning = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        var liveText = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var failureSocket = new FakeConnection();
        failureSocket.Push(new { type = "conversation.item.input_audio_transcription.completed", item_id = "live", transcript = "Visible without archive" });
        await using (var archive = new CaptionArchive(blockedPath))
        await using (var captions = new LiveCaptions(new(), _ => Task.FromResult<ICaptionConnection>(failureSocket), autoStart: false))
        await using (var recording = new RecordingEngine(new LocalRecordingStore(Path.Combine(directory, "Recordings")), _ => [new SilentInput()]))
        {
            archive.ErrorChanged += error => warning.TrySetResult(error);
            if (archive.Error is { } alreadyFailed) warning.TrySetResult(alreadyFailed);
            captions.Delta += archive.Append;
            captions.Delta += value => { if (value.Text == "Visible without archive") liveText.TrySetResult(); };
            recording.Audio += captions.Append;
            var audioSeen = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            recording.Audio += _ => audioSeen.TrySetResult();
            captions.Start();
            await recording.StartAsync(new("Archive failure isolation", true, false));
            await Task.WhenAll(warning.Task, liveText.Task, audioSeen.Task).WaitAsync(TimeSpan.FromSeconds(3));
            if (captions.Status.State != "live" || recording.Snapshot.State != RecordingState.Recording || string.IsNullOrWhiteSpace(warning.Task.Result))
                throw new Exception("Archive failure stopped the live caption or recording, or lost its warning.");
            var saved = await recording.StopAsync();
            await captions.StopAsync().WaitAsync(TimeSpan.FromSeconds(3));
            if (saved?.State != RecordingState.Done || new FileInfo(saved.AudioPath).Length <= 44)
                throw new Exception("Archive failure prevented the recording from saving audio.");
        }
    }
    private sealed class SilentInput : IAudioInput
    {
        public string Input => "system";
        public Exception? Error => null;
        public void Start() { }
        public void Read(float[] destination) => Array.Clear(destination);
        public void Stop() { }
        public void Dispose() { }
    }
    private static async Task WaitAsync(Func<bool> condition)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(3));
        while (!condition()) await Task.Delay(10, timeout.Token);
    }
    private sealed class FakeConnection : ICaptionConnection
    {
        private readonly Channel<JsonElement> incoming = Channel.CreateUnbounded<JsonElement>();
        public ConcurrentQueue<JsonElement> Sent { get; } = new();
        public void Push(object value) => incoming.Writer.TryWrite(JsonSerializer.SerializeToElement(value));
        public void Close() => incoming.Writer.TryComplete();
        public Task SendAsync(object value, CancellationToken cancellation)
        {
            var message = JsonSerializer.SerializeToElement(value); Sent.Enqueue(message);
            if (message.GetProperty("type").GetString() == "input_audio_buffer.commit")
            {
                Push(new { type = "input_audio_buffer.committed", item_id = "last" });
                Push(new { type = "conversation.item.input_audio_transcription.completed", item_id = "last", content_index = 0, transcript = "最终字幕" });
            }
            if (message.GetProperty("type").GetString() == "session.close") incoming.Writer.TryComplete();
            return Task.CompletedTask;
        }
        public async Task<JsonElement?> ReceiveAsync(CancellationToken cancellation)
        {
            try { return await incoming.Reader.ReadAsync(cancellation); } catch (ChannelClosedException) { return null; }
        }
        public ValueTask DisposeAsync() { incoming.Writer.TryComplete(); return ValueTask.CompletedTask; }
    }
    private sealed class ClaimHandler : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation)
        {
            if (request.Headers.Authorization?.Parameter != "account-token" || request.Headers.GetValues("Origin").Single() != "https://example.test") throw new Exception("Realtime claim auth/origin missing.");
            using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync(cancellation));
            var data = body.RootElement;
            if (data.GetProperty("mode").GetString() != "translation" || data.GetProperty("language").GetString() != "zh" || data.GetProperty("targetLanguage").GetString() != "en" || !data.GetProperty("includeSourceTranscript").GetBoolean()) throw new Exception("Caption claim options incorrect.");
            return new(HttpStatusCode.OK) { Content = new StringContent("""{"websocketUrl":"wss://example.test/realtime","tokenType":"Bearer","token":"ephemeral-token"}""", Encoding.UTF8, "application/json") };
        }
    }
}
