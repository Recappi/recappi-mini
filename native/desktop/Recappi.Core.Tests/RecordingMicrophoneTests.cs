using System.Buffers.Binary;
using System.Diagnostics;
using Recappi.Core;

internal static class RecordingMicrophoneTests
{
    public static async Task RunAsync(string root)
    {
        var store = new LocalRecordingStore(Path.Combine(root, "microphone-lifecycle"));
        var system = new TestInput("system", 0);
        var microphone = new TestInput("microphone", .6f);
        var replacement = new TestInput("microphone", .4f);
        var rejectEnable = false;
        double microphoneRms = 0;
        await using var engine = new RecordingEngine(store, _ => [system, microphone], _ =>
            rejectEnable ? throw new IOException("Selected microphone unavailable.") : replacement);
        engine.Level += level => { if (level.Input == "microphone") Volatile.Write(ref microphoneRms, Math.Pow(10, level.RmsDb / 20)); };
        await engine.StartAsync(new("Microphone lifecycle"));
        await UntilAsync(() => Volatile.Read(ref microphoneRms) > .5);
        await engine.SetMicrophoneEnabledAsync(false);
        Check(!engine.MicrophoneEnabled && microphone.Disposed && !system.Disposed, "Mute did not release only the microphone.");
        Check(Volatile.Read(ref microphoneRms) <= .015, "Muted microphone retained its last signal level.");

        var attention = new RecordingAttention();
        attention.Evaluate(new(180, true, new HashSet<int>(), null, microphoneRms), new());
        Check(attention.Evaluate(new(360, true, new HashSet<int>(), null, microphoneRms), new()).Contains(AttentionAction.InactiveSource),
            "Muted microphone prevented the silence reminder.");
        var path = engine.Snapshot.Recording!.AudioPath;
        var mutedStart = new FileInfo(path).Length;
        await UntilAsync(() => new FileInfo(path).Length >= mutedStart + 19200);
        var mutedEnd = new FileInfo(path).Length;
        rejectEnable = true;
        try { await engine.SetMicrophoneEnabledAsync(true); throw new Exception("Unavailable microphone was accepted."); }
        catch (IOException) { }
        Check(engine.Snapshot.State == RecordingState.Recording && !engine.MicrophoneEnabled && !system.Disposed,
            "Failed microphone reconnect interrupted system audio or changed enabled state.");
        rejectEnable = false;
        await engine.SetMicrophoneEnabledAsync(true);
        await UntilAsync(() => Volatile.Read(ref microphoneRms) > .3);
        var saved = await engine.StopAsync();
        Check(saved?.State == RecordingState.Done && !engine.MicrophoneEnabled && replacement.Disposed && system.Disposed,
            "Stop retained an enabled microphone or failed to finalize capture.");
        Check(microphoneRms <= .015, "Stop retained microphone signal.");
        var bytes = File.ReadAllBytes(path);
        Check(BinaryPrimitives.ReadUInt32LittleEndian(bytes.AsSpan(40)) == bytes.Length - 44, "Toggle sequence truncated WAV.");
        Check(bytes.AsSpan((int)mutedStart, (int)(mutedEnd - mutedStart)).IndexOfAnyExcept((byte)0) < 0,
            "Muted interval contains microphone samples.");

        var faulty = new TestInput("microphone", .5f);
        await using var failing = new RecordingEngine(new(Path.Combine(root, "microphone-failure")), _ => [faulty]);
        await failing.StartAsync(new("Input failure", false, true));
        await UntilAsync(() => failing.Snapshot.Recording!.DurationMs > 0);
        faulty.Failure = new IOException("Microphone disconnected.");
        await UntilAsync(() => failing.Snapshot.State == RecordingState.Error);
        Check(!failing.MicrophoneEnabled && faulty.Disposed && File.Exists(failing.Snapshot.Recording!.AudioPath),
            "Device failure left microphone enabled or lost partial audio.");
    }

    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static async Task UntilAsync(Func<bool> condition)
    {
        var clock = Stopwatch.StartNew();
        while (!condition())
        {
            if (clock.Elapsed > TimeSpan.FromSeconds(5)) throw new TimeoutException("Microphone lifecycle condition did not settle.");
            await Task.Delay(20);
        }
    }

    private sealed class TestInput(string input, float sample) : IAudioInput
    {
        public string Input { get; } = input;
        public Exception? Failure;
        public Exception? Error => Volatile.Read(ref Failure);
        public bool Disposed;
        public void Start() { }
        public void Read(float[] destination) => Array.Fill(destination, sample);
        public void Stop() { }
        public void Dispose() => Disposed = true;
    }
}
