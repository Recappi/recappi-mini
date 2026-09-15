using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Recappi.Core;

internal static class CaptionTransportTests
{
    public static async Task RunAsync(string root)
    {
        foreach (var translate in new[] { false, true }) await ReconnectAsync(root, translate);
    }

    private static async Task ReconnectAsync(string root, bool translate)
    {
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        var cancellation = deadline.Token;
        using var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        var reconnectAccepted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var resumeHandshake = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var providerDone = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var stopRequested = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var beforeDisconnectReceived = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var server = ServeAsync();
        var directory = Path.Combine(root, translate ? "translation-transport" : "transcription-transport");
        Directory.CreateDirectory(directory);
        var archivePath = Path.Combine(directory, "captions.jsonl");
        var observed = new ConcurrentQueue<CaptionDelta>();
        var statuses = new ConcurrentQueue<string>();
        var attempts = 0;
        await using var engine = new RecordingEngine(new LocalRecordingStore(directory), _ => [new ConstantInput()]);
        await using var captions = new LiveCaptions(new("en", translate ? "zh" : null), token =>
        {
            Interlocked.Increment(ref attempts);
            return CaptionConnection.ConnectAsync(new($"ws://127.0.0.1:{port}/caption", "Bearer", "local-fixture"), "https://example.test", token);
        }, [TimeSpan.Zero], autoStart: false);
        var archive = new CaptionArchive(archivePath);
        captions.Delta += observed.Enqueue;
        captions.Delta += _ =>
        {
            if (observed.Any(x => x.Text == "Before reconnect") && (!translate || observed.Any(x => x.Text == "断开之前")))
                beforeDisconnectReceived.TrySetResult();
        };
        captions.Delta += archive.Append;
        captions.Changed += value => statuses.Enqueue(value.State);
        engine.Audio += captions.Append;
        var clock = Stopwatch.StartNew();
        try
        {
            captions.Start();
            await engine.StartAsync(new("Socket reconnect fixture", true, false));
            await reconnectAccepted.Task.WaitAsync(cancellation);
            if (engine.Snapshot.State != RecordingState.Recording || !statuses.Contains("reconnecting"))
                throw new Exception("Transport loss failed to enter reconnecting while recording remained active.");
            var audioPath = engine.Snapshot.Recording!.AudioPath;
            var bytesBefore = new FileInfo(audioPath).Length;
            await WaitAsync(() => new FileInfo(audioPath).Length > bytesBefore + 9600, cancellation);
            if (engine.Snapshot.State != RecordingState.Recording) throw new Exception("Waiting for the actual reconnect handshake stopped local recording.");
            resumeHandshake.TrySetResult();
            await WaitAsync(() => observed.Any(x => x.Text == "After reconnect") && (!translate || observed.Any(x => x.Text == "重连之后")), cancellation);
            stopRequested.TrySetResult();
            var saved = await engine.StopAsync();
            var elapsedMs = clock.Elapsed.TotalMilliseconds;
            await captions.StopAsync().WaitAsync(cancellation);
            await providerDone.Task.WaitAsync(cancellation);
            await server;
            await archive.DisposeAsync();

            var finals = CaptionArchive.Read(archivePath).ToArray();
            foreach (var text in translate ? new[] { "Before reconnect", "断开之前", "After reconnect", "重连之后", "停止尾句" } : new[] { "Before reconnect", "After reconnect", "Stop tail" })
                if (!finals.Any(x => x.Text.Contains(text, StringComparison.Ordinal))) throw new Exception("Actual transport reconnect/stop lost an archived segment: " + text);
            if (finals.Where(x => x.Stream == "source").Select(x => x.SegmentId).Distinct().Count() < 2 || attempts != 2 || captions.BufferedChunks != 0 || archive.Error is not null)
                throw new Exception("Reconnect reused segment identity, leaked audio, or failed archive persistence.");
            if (saved is not { State: RecordingState.Done, Error: null } || Math.Abs(saved.DurationMs - elapsedMs) > 500)
                throw new Exception("Transport loss truncated the recording timeline.");
            var wav = File.ReadAllBytes(saved.AudioPath);
            if (wav.Length < 44 + 9600 || BinaryPrimitives.ReadUInt32LittleEndian(wav.AsSpan(40)) != wav.Length - 44 || Math.Abs((wav.Length - 44) / 96.0 - saved.DurationMs) > 1)
                throw new Exception("Transport recovery produced an incomplete WAV.");
            var sample = BinaryPrimitives.ReadInt16LittleEndian(wav.AsSpan(44));
            if (sample < 100) throw new Exception("Controlled input was absent.");
            for (var offset = 44; offset < wav.Length; offset += 2)
                if (BinaryPrimitives.ReadInt16LittleEndian(wav.AsSpan(offset)) != sample) throw new Exception("Transport loss introduced a gap in the controlled PCM.");
            File.WriteAllText(Path.Combine(directory, "transport-report.json"), JsonSerializer.Serialize(new
            {
                passed = true, translate, connections = attempts, saved.DurationMs, wavBytes = wav.Length,
                archivedSegments = finals.Length, recordingGrewDuringHandshake = true,
                scope = "Actual loopback TCP/WebSocket transport and production caption/recording/archive classes; synthetic PCM and provider protocol, no WASAPI, public service, account or desktop UI."
            }));
        }
        finally
        {
            deadline.Cancel();
            listener.Stop();
            await engine.StopAsync();
            await captions.AbortAsync();
            await archive.DisposeAsync();
            try { await server; } catch (Exception) when (cancellation.IsCancellationRequested) { }
        }

        async Task ServeAsync()
        {
            for (var generation = 0; generation < 2; generation++)
            {
                using var peer = await listener.AcceptTcpClientAsync(cancellation);
                await using var network = peer.GetStream();
                using var reader = new StreamReader(network, Encoding.ASCII, leaveOpen: true);
                var headers = new List<string>();
                while (await reader.ReadLineAsync(cancellation) is { Length: > 0 } line) headers.Add(line);
                if (!headers.Contains("Authorization: Bearer local-fixture") || !headers.Contains("Origin: https://example.test")) throw new Exception("Actual socket handshake omitted expected headers.");
                var key = headers.Single(x => x.StartsWith("Sec-WebSocket-Key:", StringComparison.OrdinalIgnoreCase)).Split(':', 2)[1].Trim();
                if (generation == 1) { reconnectAccepted.TrySetResult(); await resumeHandshake.Task.WaitAsync(cancellation); }
                var accept = Convert.ToBase64String(SHA1.HashData(Encoding.ASCII.GetBytes(key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11")));
                await network.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {accept}\r\n\r\n"), cancellation);
                using var socket = WebSocket.CreateFromStream(network, isServer: true, subProtocol: null, keepAliveInterval: Timeout.InfiniteTimeSpan);
                var published = false;
                var commit = 0;
                while (true)
                {
                    using var message = new MemoryStream();
                    var buffer = new byte[8192];
                    ValueWebSocketReceiveResult received;
                    do
                    {
                        received = await socket.ReceiveAsync(buffer.AsMemory(), cancellation);
                        if (received.MessageType != WebSocketMessageType.Text) throw new Exception("Unexpected socket frame from caption client.");
                        message.Write(buffer, 0, received.Count);
                    } while (!received.EndOfMessage);
                    using var json = JsonDocument.Parse(message.ToArray());
                    var type = json.RootElement.GetProperty("type").GetString();
                    if (type is "input_audio_buffer.append" or "session.input_audio_buffer.append")
                    {
                        if (Convert.FromBase64String(json.RootElement.GetProperty("audio").GetString()!).Length == 0) throw new Exception("Empty caption audio.");
                        if (translate && !published)
                        {
                            await Send(new { type = "session.input_transcript.delta", delta = generation == 0 ? "Before reconnect" : "After reconnect" });
                            await Send(new { type = "session.output_transcript.delta", delta = generation == 0 ? "断开之前" : "重连之后" });
                            published = true;
                        }
                    }
                    else if (type == "input_audio_buffer.commit")
                    {
                        var item = "same-" + commit++;
                        await Send(new { type = "input_audio_buffer.committed", item_id = item });
                        var finishing = generation == 1 && stopRequested.Task.IsCompleted;
                        await Send(new { type = "conversation.item.input_audio_transcription.completed", item_id = item, transcript = generation == 0 ? "Before reconnect" : finishing ? "Stop tail" : "After reconnect" });
                        published = true;
                        if (finishing) { providerDone.TrySetResult(); return; }
                    }
                    else if (type == "session.close")
                    {
                        await Send(new { type = "session.output_transcript.delta", delta = "停止尾句" });
                        await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, "fixture complete", cancellation);
                        providerDone.TrySetResult(); return;
                    }
                    if (generation == 0 && published)
                    {
                        // Only assert preservation of text the client actually received before loss.
                        await beforeDisconnectReceived.Task.WaitAsync(cancellation);
                        socket.Abort(); break;
                    }

                    async Task Send(object value)
                    {
                        var bytes = JsonSerializer.SerializeToUtf8Bytes(value, new JsonSerializerOptions { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
                        // Exercise transport reassembly, including a split inside a UTF-8 character.
                        var split = Array.FindIndex(bytes, x => x >= 128);
                        split = split < 0 ? bytes.Length / 2 : split + 1;
                        await socket.SendAsync(bytes.AsMemory(0, split), WebSocketMessageType.Text, false, cancellation);
                        await socket.SendAsync(bytes.AsMemory(split), WebSocketMessageType.Text, true, cancellation);
                    }
                }
            }
        }
    }

    private static async Task WaitAsync(Func<bool> condition, CancellationToken cancellation)
    {
        while (!condition()) await Task.Delay(10, cancellation);
    }

    private sealed class ConstantInput : IAudioInput
    {
        public string Input => "system";
        public Exception? Error => null;
        public void Start() { }
        public void Read(float[] destination) => Array.Fill(destination, 0.25f);
        public void Stop() { }
        public void Dispose() { }
    }
}
