using System.Collections.Concurrent;
using System.Net;
using System.Text.Json;
using System.Threading.Channels;

namespace Recappi.Core;

public sealed record CaptionDelta(string SegmentId, string Stream, string Text, bool IsFinal);
public sealed record CaptionStatus(string State, string? Message = null);

/// <summary>Independent, bounded best-effort audio consumer. Never blocks the WAV writer.</summary>
public sealed class LiveCaptions : IAsyncDisposable
{
    private readonly CaptionOptions options;
    private readonly string streamId = Guid.NewGuid().ToString("N");
    private readonly Func<CancellationToken, Task<ICaptionConnection>> connect;
    private readonly TimeSpan[] reconnectDelays;
    private readonly Channel<byte[]> audio = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(50) { FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true, SingleWriter = false });
    private readonly CancellationTokenSource lifetime = new();
    private readonly CaptionPcmEncoder encoder = new();
    private readonly object encoderLock = new();
    private readonly Task worker;
    private readonly TaskCompletionSource startSignal = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private int closing;
    private int stopped;
    private int disposed;
    private int retries;
    private int generation;
    private Task? finish;
    private TaskCompletionSource<bool>? pendingRetry;
    private CaptionStatus status = new("connecting");
    public CaptionStatus Status => Volatile.Read(ref status);
    public int BufferedChunks => audio.Reader.Count;
    public event Action<CaptionDelta>? Delta;
    public event Action<CaptionStatus>? Changed;
    public bool TryRetry()
    {
        if (Volatile.Read(ref closing) != 0) return false;
        return Interlocked.Exchange(ref pendingRetry, null)?.TrySetResult(true) == true;
    }

    public LiveCaptions(CaptionOptions options, Func<CancellationToken, Task<ICaptionConnection>> connect, TimeSpan[]? reconnectDelays = null, bool autoStart = true)
    {
        this.options = options; this.connect = connect;
        this.reconnectDelays = reconnectDelays ?? [TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(30)];
        worker = Task.Run(async () => { await startSignal.Task; await RunAsync(); });
        if (autoStart) Start();
    }
    /// <summary>Release a deferred stream only after window and archive observers are attached.</summary>
    public bool Start() => Volatile.Read(ref closing) == 0 && startSignal.TrySetResult();
    public void Append(float[] samples)
    {
        if (Volatile.Read(ref closing) != 0 || Volatile.Read(ref stopped) != 0) return;
        lock (encoderLock)
        {
            if (Volatile.Read(ref closing) != 0 || Volatile.Read(ref stopped) != 0) return;
            // Each queued item is at most 100 ms: fifty items cannot exceed five seconds.
            for (var offset = 0; offset < samples.Length; offset += 4800)
            {
                var pcm = encoder.Encode(samples.AsSpan(offset, Math.Min(4800, samples.Length - offset)));
                if (pcm.Length > 0) audio.Writer.TryWrite(pcm);
            }
        }
    }
    private async Task RunAsync()
    {
        try
        {
            while (!lifetime.IsCancellationRequested && Volatile.Read(ref closing) == 0)
            {
                try
                {
                    Publish(new(generation == 0 ? "connecting" : "reconnecting"));
                    await using var connection = await connect(lifetime.Token);
                    if (Volatile.Read(ref closing) != 0) break;
                    var current = ++generation;
                    Publish(new("live"));
                    using var session = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                    var state = new ConnectionState();
                    var receive = ReceiveAsync(connection, current, state, session.Token);
                    var send = SendAudioAsync(connection, state, session.Token);
                    try
                    {
                        var completed = await Task.WhenAny(receive, send);
                        if (completed == send)
                        {
                            await send;
                            // A final commit may be acknowledged after the local recording has stopped.
                            await Task.WhenAny(receive, state.Drained.Task, Task.Delay(1500, lifetime.Token));
                            if (receive.IsCompleted) await receive;
                        }
                        else { await receive; if (Volatile.Read(ref closing) == 0) throw new IOException("字幕连接已断开。"); }
                    }
                    finally
                    {
                        session.Cancel();
                        try { await Task.WhenAll(receive, send); } catch (Exception) { }
                        FinishTranslation(current, state);
                    }
                    if (Volatile.Read(ref closing) != 0) break;
                    throw new IOException("字幕连接已结束。");
                }
                catch (Exception error) when (!lifetime.IsCancellationRequested && Volatile.Read(ref closing) == 0)
                {
                    var retryable = error is not CaptionUnavailableException && (error is not CloudException cloud || cloud.Status == HttpStatusCode.TooManyRequests || (int)cloud.Status >= 500);
                    var attempt = Volatile.Read(ref retries);
                    if (!retryable || attempt >= reconnectDelays.Length)
                    {
                        Interlocked.Exchange(ref stopped, 1);
                        var retry = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                        Volatile.Write(ref pendingRetry, retry);
                        Publish(new("failed", error switch
                        {
                            CaptionUnavailableException => "当前地区无法使用实时字幕。录音继续，可在结束后转写。",
                            CloudException { Status: HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden } => "字幕连接授权失败，本地录音继续。",
                            _ => "实时字幕无法继续。本地录音不受影响。"
                        }));
                        if (Volatile.Read(ref closing) != 0 || !await retry.Task.WaitAsync(lifetime.Token)) return;
                        while (audio.Reader.TryRead(out _)) { }
                        Interlocked.Exchange(ref retries, 0);
                        Interlocked.Exchange(ref stopped, 0);
                        continue;
                    }
                    Publish(new("reconnecting", "字幕连接中断，正在重连。本地录音继续。"));
                    Interlocked.Increment(ref retries);
                    await Task.Delay(reconnectDelays[attempt], lifetime.Token);
                }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception) { Publish(new("failed", "实时字幕已停止，本地录音继续。")); }
        finally
        {
            Interlocked.Exchange(ref stopped, 1);
            Interlocked.Exchange(ref pendingRetry, null)?.TrySetResult(false);
            audio.Writer.TryComplete(); while (audio.Reader.TryRead(out _)) { }
            if (Status.State != "failed") Publish(new("stopped"));
        }
    }
    private sealed class ConnectionState
    {
        public int PendingCommits;
        public int SenderDone;
        public ConcurrentDictionary<string, byte> Awaiting { get; } = new();
        public Dictionary<string, string> Segments { get; } = [];
        public string Source = "";
        public string Translation = "";
        public int TranslationSegment;
        public TaskCompletionSource Drained { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    }
    private async Task SendAudioAsync(ICaptionConnection connection, ConnectionState state, CancellationToken cancellation)
    {
        var uncommitted = 0;
        async Task Commit()
        {
            if (Volatile.Read(ref state.PendingCommits) + state.Awaiting.Count >= 128) throw new IOException("字幕服务未响应。");
            Interlocked.Increment(ref state.PendingCommits);
            await connection.SendAsync(new { type = "input_audio_buffer.commit" }, cancellation); uncommitted = 0;
        }
        await foreach (var pcm in audio.Reader.ReadAllAsync(cancellation))
        {
            await connection.SendAsync(new { type = options.Translate ? "session.input_audio_buffer.append" : "input_audio_buffer.append", audio = Convert.ToBase64String(pcm) }, cancellation);
            if (!options.Translate) { uncommitted += pcm.Length; if (uncommitted >= 67200) await Commit(); }
        }
        if (options.Translate) await connection.SendAsync(new { type = "session.close" }, cancellation);
        else
        {
            if (uncommitted > 0)
            {
                if (uncommitted < 4800) await connection.SendAsync(new { type = "input_audio_buffer.append", audio = Convert.ToBase64String(new byte[4800 - uncommitted]) }, cancellation);
                await Commit();
            }
            Volatile.Write(ref state.SenderDone, 1); CheckDrained(state);
        }
    }
    private async Task ReceiveAsync(ICaptionConnection connection, int current, ConnectionState state, CancellationToken cancellation)
    {
        while (await connection.ReceiveAsync(cancellation) is { } value)
        {
            var type = CloudFields.Text(value, "type");
            var key = current + ":" + (CloudFields.Text(value, "item_id") ?? "current") + (value.TryGetProperty("content_index", out var index) && index.ValueKind == JsonValueKind.Number && index.TryGetInt32(out var contentIndex) && contentIndex != 0 ? "#" + contentIndex : "");
            var delta = value.TryGetProperty("delta", out var raw) && raw.ValueKind == JsonValueKind.String ? raw.GetString() ?? "" : "";
            if (type == "input_audio_buffer.committed")
            {
                state.Awaiting[key] = 0; Interlocked.Decrement(ref state.PendingCommits);
                if (state.Awaiting.Count > 128) throw new IOException("字幕服务未响应。");
            }
            else if (type == "conversation.item.input_audio_transcription.delta")
            {
                Interlocked.Exchange(ref retries, 0);
                var text = Limit(state.Segments.GetValueOrDefault(key, "") + delta, 16000);
                state.Segments[key] = text; Emit(new(key, "source", text, false));
                if (state.Segments.Count > 128) state.Segments.Remove(state.Segments.Keys.First());
            }
            else if (type == "conversation.item.input_audio_transcription.completed")
            {
                Interlocked.Exchange(ref retries, 0);
                Emit(new(key, "source", Limit(CloudFields.Text(value, "transcript") ?? state.Segments.GetValueOrDefault(key, ""), 16000), true));
                state.Segments.Remove(key); state.Awaiting.TryRemove(key, out _); CheckDrained(state);
            }
            else if (type is "session.input_transcript.delta" or "session.output_transcript.delta")
            {
                Interlocked.Exchange(ref retries, 0);
                var source = type == "session.input_transcript.delta";
                if (source) state.Source = Limit(state.Source + delta, 16000); else state.Translation = Limit(state.Translation + delta, 16000);
                Emit(new(current + ":translation-" + state.TranslationSegment, source ? "source" : "translation", source ? state.Source : state.Translation, false));
                if (state.Source.Length > 2000 || state.Translation.Length > 2000) FinishTranslation(current, state);
            }
            else if (type == "error")
            {
                if (value.TryGetProperty("error", out var error) && CloudFields.Text(error, "code") == "unsupported_country_region_territory") throw new CaptionUnavailableException();
                throw new IOException("字幕服务错误。");
            }
        }
    }
    private static string Limit(string value, int count) => value.Length <= count ? value : value[^count..];
    private void FinishTranslation(int current, ConnectionState state)
    {
        var key = current + ":translation-" + state.TranslationSegment++;
        Emit(new(key, "source", state.Source, true)); Emit(new(key, "translation", state.Translation, true)); state.Source = state.Translation = "";
    }
    private void CheckDrained(ConnectionState state) { if (Volatile.Read(ref state.SenderDone) != 0 && Volatile.Read(ref state.PendingCommits) <= 0 && state.Awaiting.IsEmpty) state.Drained.TrySetResult(); }
    private void Emit(CaptionDelta value)
    {
        if (string.IsNullOrEmpty(value.Text)) return;
        value = value with { SegmentId = streamId + "/" + value.SegmentId };
        foreach (Action<CaptionDelta> observer in Delta?.GetInvocationList() ?? []) try { observer(value); } catch (Exception) { }
    }
    private void Publish(CaptionStatus value)
    {
        Volatile.Write(ref status, value);
        foreach (Action<CaptionStatus> observer in Changed?.GetInvocationList() ?? []) try { observer(value); } catch (Exception) { }
    }
    public Task StopAsync()
    {
        lock (encoderLock)
        {
            if (finish is not null) return finish;
            Interlocked.Exchange(ref closing, 1); audio.Writer.TryComplete(); lifetime.CancelAfter(TimeSpan.FromSeconds(5));
            startSignal.TrySetResult();
            Interlocked.Exchange(ref pendingRetry, null)?.TrySetResult(false);
            return finish = worker;
        }
    }
    public async Task AbortAsync()
    {
        lock (encoderLock)
        {
            if (Volatile.Read(ref disposed) != 0) return;
            Interlocked.Exchange(ref closing, 1); audio.Writer.TryComplete(); lifetime.Cancel(); finish ??= worker;
            startSignal.TrySetResult();
        }
        await worker;
    }
    public async ValueTask DisposeAsync() { await StopAsync(); if (Interlocked.Exchange(ref disposed, 1) == 0) lifetime.Dispose(); }
    private sealed class CaptionUnavailableException : Exception;
}
