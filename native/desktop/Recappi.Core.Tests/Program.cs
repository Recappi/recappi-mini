using System.Buffers.Binary;
using System.Text.Json;
using Recappi.Core;

var root = Path.Combine(Path.GetFullPath("build/native-desktop-validation"), "core-tests-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
if (args.Length == 2 && args[0] == "--interrupted-recording-child")
{
    await InterruptedRecordingTests.RunChildAsync(Path.GetFullPath(args[1]));
    return;
}
if (args.Length >= 2 && args[0] is "--prepare-desktop-caption-fixture" or "--verify-desktop-caption-fixture" or "--clear-desktop-caption-fixture")
{
    try
    {
        if (args[0] == "--prepare-desktop-caption-fixture" && args.Length == 3) await DesktopCaptionFixture.PrepareAsync(args[1], int.Parse(args[2]));
        else if (args[0] == "--verify-desktop-caption-fixture" && args.Length == 2) DesktopCaptionFixture.Verify(args[1]);
        else if (args[0] == "--clear-desktop-caption-fixture" && args.Length == 2) DesktopCaptionFixture.ClearAccount(args[1]);
        else throw new ArgumentException("Invalid fixture arguments.");
    }
    catch (Exception error) { Console.Error.WriteLine("Desktop caption fixture failed: " + error.GetType().Name + ". Identity, credentials and server payloads omitted."); Environment.ExitCode = 1; }
    return;
}
if (args.Length == 1 && args[0] == "--billing-smoke")
{
    try { await BillingSmoke.RunAsync(root); }
    catch (Exception error) { Console.Error.WriteLine("Billing smoke failed: " + error.GetType().Name + (error is CloudException cloud ? " HTTP " + (int)cloud.Status : "") + ". Credentials and server payloads omitted."); Environment.ExitCode = 1; }
    Console.WriteLine("Results: " + root); return;
}
if (args.Length == 1 && args[0] == "--update-source-smoke")
{
    try
    {
        using var updates = new DesktopUpdates();
        var result = await updates.CheckAsync("0.1.0-preview.1", "win-x64");
        var report = new { checkedAt = DateTimeOffset.UtcNow, source = DesktopUpdates.ReleasesPage, runtime = "win-x64", result.HasCompatibleRelease, version = result.Update?.Version };
        File.WriteAllText(Path.Combine(root, "update-source-smoke.json"), JsonSerializer.Serialize(report));
        Console.WriteLine(JsonSerializer.Serialize(report));
    }
    catch (Exception error)
    {
        var report = new { checkedAt = DateTimeOffset.UtcNow, source = DesktopUpdates.ReleasesPage, error = error.GetType().Name, status = error is HttpRequestException http ? (int?)http.StatusCode : null };
        File.WriteAllText(Path.Combine(root, "update-source-smoke.json"), JsonSerializer.Serialize(report));
        Console.Error.WriteLine(JsonSerializer.Serialize(report)); Environment.ExitCode = 1;
    }
    Console.WriteLine("Results: " + root); return;
}
if (args.Length == 2 && args[0] == "--cloud-pipeline-smoke")
{
    try { await CloudPipelineSmoke.RunAsync(Path.GetFullPath(args[1]), root); }
    catch (Exception error) { Console.Error.WriteLine("Cloud pipeline smoke failed: " + error.GetType().Name + (error is CloudException cloud ? " HTTP " + (int)cloud.Status : "") + ". Credentials and server payloads omitted."); Environment.ExitCode = 1; }
    Console.WriteLine("Results: " + root); return;
}
if (args.Length == 2 && args[0] is "--cloud-smoke" or "--translation-smoke")
{
    try { await CloudSmoke.RunAsync(Path.GetFullPath(args[1]), root, args[0] == "--translation-smoke"); Console.WriteLine("Results: " + root); }
    catch (Exception error) { Console.Error.WriteLine("Cloud smoke failed: " + error.GetType().Name + ". Credentials and server payloads omitted."); Environment.ExitCode = 1; }
    return;
}
var results = new List<string>();
async Task Test(string name, Func<Task> body)
{
    await body(); results.Add(name); Console.WriteLine("PASS " + name);
}
void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
LocalRecordingStore Store() => new(Path.Combine(root, Guid.NewGuid().ToString("N")));
async Task Throws(Func<Task> body)
{
    try { await body(); } catch { return; }
    throw new Exception("Expected an exception.");
}

await Test("Native WebSocket handshake preserves rejection status; caption authorization failures do not reconnect", CaptionHandshakeTests.RunAsync);
await Test("Current API rejection expires account; delayed old-token rejection cannot expire renewed or signed-out state", () => AccountExpiryTests.RunAsync(root));
await Test("Billing quota semantics, periods, authenticated portal, safe links and free-plan fallback", BillingTests.RunAsync);

await Test("Library copies merge only confirmed unambiguous account-scoped upload links", () =>
{
    var local = Store().Create("Same title");
    var remote = new CloudRecordingItem("remote", "Same title", "ready", 1000);
    var link = new ProcessingEntry(local.Id, "account-a", local.Title, ProcessingStage.Completed, new("remote", 1, 1), UploadCompleted: true);
    IReadOnlyList<LibraryRecording> Merge(IReadOnlyList<ProcessingEntry> links, string? partition = "account-a") => LibraryRecording.Merge([local], [remote], links, partition);
    Check(Merge([]).Count == 2, "Matching titles merged unrelated recordings.");
    Check(Merge([link]).Single() is { Local: not null, Cloud: not null }, "Confirmed copy association was lost.");
    Check(Merge([link], "account-b").Count == 2 && Merge([link], null).Count == 2, "Copy association crossed an account boundary.");
    Check(Merge([link with { UploadCompleted = false }]).Count == 2, "Unconfirmed upload hid a recording.");
    Check(LibraryRecording.Merge([local], [], [link], "account-a").Single().Local == local, "Missing remote hid local audio.");
    var second = local with { Id = Guid.NewGuid().ToString("N") };
    Check(LibraryRecording.Merge([local, second], [remote], [link, link with { LocalId = second.Id }], "account-a").Count == 3, "Ambiguous remote association hid a copy.");
    Check(LibraryRecording.Merge([local], [remote, remote with { Id = "other" }], [link, link with { Ticket = new("other", 1, 1) }], "account-a").Count == 3, "Ambiguous local association hid a copy.");
    return Task.CompletedTask;
});

await Test("WAV clamps nonfinite and out-of-range PCM and updates header before close", () =>
{
    var path = Path.Combine(root, "pcm.wav");
    using var writer = new PcmWaveWriter(path);
    writer.Append(new float[] { -2, -1, 0, 1, 2, float.NaN, float.PositiveInfinity });
    using var reader = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
    var bytes = new byte[reader.Length];
    reader.ReadExactly(bytes);
    Check(BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(40)) == 14, "Recoverable data length is wrong.");
    short[] expected = [-32768, -32768, 0, 32767, 32767, 0, 0];
    for (var i = 0; i < expected.Length; i++) Check(BinaryPrimitives.ReadInt16LittleEndian(bytes.AsSpan(44 + i * 2)) == expected[i], "PCM conversion mismatch.");
    writer.Dispose();
    try { writer.Append(new float[] { 1 }); throw new Exception("Closed writer accepted samples."); } catch (ObjectDisposedException) { }
    return Task.CompletedTask;
});

await Test("Repeated start is rejected; repeated stop preserves the completed WAV", async () =>
{
    await using var engine = new RecordingEngine(Store(), _ => [new FakeInput("system", 0.4f)]);
    await engine.StartAsync(new("Lifecycle", true, false));
    await Throws(() => engine.StartAsync(new("Duplicate", true, false)));
    await Task.Delay(380);
    var first = await engine.StopAsync(); var second = await engine.StopAsync();
    Check(first == second && first?.State == RecordingState.Done, "Stop was not idempotent.");
    var bytes = File.ReadAllBytes(first!.AudioPath);
    Check(bytes.Length > 44 && BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(40)) == bytes.Length - 44, "WAV was truncated.");
});

await Test("Device startup failure settles state and preserves diagnostic metadata", async () =>
{
    var store = Store();
    await using var engine = new RecordingEngine(store, _ => [new FakeInput("system", 0, failStart: true)]);
    await Throws(() => engine.StartAsync(new("Failure", true, false)));
    Check(engine.Snapshot.State == RecordingState.Error, "Startup failed without Error state.");
    Check(store.List().Single().Error is not null, "Missing recovery metadata.");
});

await Test("Observer exceptions cannot interrupt recording", async () =>
{
    await using var engine = new RecordingEngine(Store(), _ => [new FakeInput("system", 0.2f)]);
    engine.Audio += _ => throw new Exception("Caption observer failed.");
    engine.Changed += _ => throw new Exception("Window was closed.");
    await engine.StartAsync(new("Observers", true, false));
    await Task.Delay(350);
    Check((await engine.StopAsync())?.State == RecordingState.Done, "Observer lost audio.");
});

await Test("Microphone toggle disposes device and can reconnect without restarting system audio", async () =>
{
    var mic = new FakeInput("microphone", 0.6f);
    var system = new FakeInput("system", 0.2f);
    FakeInput? replacement = null;
    await using var engine = new RecordingEngine(Store(), _ => [system, mic], _ => replacement = new FakeInput("microphone", 0.6f));
    await engine.StartAsync(new("Mute"));
    await engine.SetMicrophoneEnabledAsync(false);
    Check(mic.Disposed && !engine.MicrophoneEnabled && !system.Disposed, "Mic toggle did not release device independently.");
    await Task.Delay(250);
    await engine.SetMicrophoneEnabledAsync(true);
    Check(replacement is { Started: true } && engine.MicrophoneEnabled, "Mic did not reconnect.");
    await Task.Delay(150);
    Check((await engine.StopAsync())?.State == RecordingState.Done, "Toggle interrupted capture.");
});

await Test("Interrupted recordings recover without losing audio or touching active writers", () => InterruptedRecordingTests.RunAsync(root));

await Test("Disposal finalizes active audio even with no window", async () =>
{
    var store = Store();
    var engine = new RecordingEngine(store, _ => [new FakeInput("system", 0.3f)]);
    await engine.StartAsync(new("Dispose", true, false));
    await Task.Delay(350);
    await engine.DisposeAsync();
    Check(store.List().Single().State == RecordingState.Done, "Dispose did not finish recording.");
});

await Test("Confirmed discard only removes this session", async () =>
{
    var store = Store();
    var retained = store.Create("Retain");
    await using var engine = new RecordingEngine(store, _ => [new FakeInput("system", 0.3f)]);
    await engine.StartAsync(new("Discard", true, false));
    var removedPath = engine.Snapshot.Recording!.AudioPath;
    await Task.Delay(350);
    await engine.DiscardAsync();
    Check(!File.Exists(removedPath) && store.List().Single().Id == retained.Id, "Discard affected the wrong recording.");
});

await Test("Metadata path traversal cannot write or discard outside library", async () =>
{
    var store = Store(); var entry = store.Create("Safe");
    var outside = entry with { Directory = root };
    await Throws(() => { store.Save(outside); return Task.CompletedTask; });
    await Throws(() => { store.Discard(outside); return Task.CompletedTask; });
    Check(store.List().Single().Id == entry.Id, "Path rejection damaged the library.");
});

await Test("Desktop updates pin official source, compare channels/architectures and preserve files on invalid or canceled downloads", () => DesktopUpdateTests.RunAsync(root));
await Test("Cloud multipart upload, account headers, escaped IDs and safe failures follow existing API", () => CloudClientTests.RunAsync(root));
await Test("Background upload resumes across restart without duplicates or account leakage", () => ProcessingTests.RunAsync(root));
await Test("Ask streams split UTF8, CRLF/LF/CR frames, citations and rejects incomplete or oversized events", AskTests.RunAsync);
await Test("Audio download authenticates, preserves content/type and rejects truncated replacement", () => AudioDownloadTests.RunAsync(root));
await Test("Native audio import decodes PCM, preserves source and cleans canceled or invalid input", () => AudioImportTests.RunAsync(root));
await Test("Speaker profiles persist protected, isolate account/recording and preserve prior value on invalid save", () => SpeakerProfileTests.RunAsync(root));
await Test("Cloud content cache searches all cached recordings, survives reload, isolates accounts and tolerates damage", () => CloudContentCacheTests.RunAsync(root));
await Test("Captions resample PCM, bound queues, drain final text, reconnect and preserve bilingual streams", CaptionTests.RunAsync);
await Test("Preferences persist, recording options stay immutable and caption archives survive partial final lines", () => PreferencesArchiveTests.RunAsync(root));
await Test("Recording reminders respect visibility, grace/reset/once rules and native activity enumeration", AttentionTests.RunAsync);
await Test("Caption failure does not interrupt local recording", async () =>
{
    await using var captions = new LiveCaptions(new(), _ => Task.FromException<ICaptionConnection>(new CloudException(System.Net.HttpStatusCode.Unauthorized)), []);
    await using var engine = new RecordingEngine(Store(), _ => [new FakeInput("system", .2f)]);
    engine.Audio += captions.Append;
    await engine.StartAsync(new("Caption failure", true, false));
    await Task.Delay(350);
    var saved = await engine.StopAsync();
    Check(captions.Status.State == "failed" && saved?.State == RecordingState.Done && new FileInfo(saved.AudioPath).Length > 44, "Caption failure damaged the recording.");
});

if (args.Contains("--native-smoke"))
{
    await Test("Real WASAPI system loopback records a valid time-aligned WAV", async () =>
    {
        await using var engine = new RecordingEngine(Store());
        await engine.StartAsync(new("Native smoke", true, false));
        await Task.Delay(1500);
        var recording = await engine.StopAsync();
        Check(recording is { State: RecordingState.Done, DurationMs: >= 1400 and <= 2500 }, "Native recording duration or state invalid.");
        Check(new FileInfo(recording!.AudioPath).Length > 44, "Native WAV has no data.");
    });
}
File.WriteAllText(Path.Combine(root, "results.json"), JsonSerializer.Serialize(new { completedAt = DateTimeOffset.Now, passed = results, count = results.Count }));
Console.WriteLine($"{results.Count} tests passed. Results: {root}");

sealed class FakeInput(string input, float value, bool failStart = false) : IAudioInput
{
    public string Input => input;
    public Exception? Error => null;
    public bool Started { get; private set; }
    public bool Disposed { get; private set; }
    public void Start() { if (failStart) throw new IOException("Test device unavailable."); Started = true; }
    public void Read(float[] destination) => Array.Fill(destination, value);
    public void Stop() { }
    public void Dispose() => Disposed = true;
}
