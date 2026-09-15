using System.Buffers.Binary;
using System.Diagnostics;
using Recappi.Core;

internal static class InterruptedRecordingTests
{
    public static async Task RunAsync(string root)
    {
        var store = new LocalRecordingStore(Path.Combine(root, "interrupted"));
        var entry = store.Create("Interrupted recording");
        using (var writer = new PcmWaveWriter(entry.AudioPath)) writer.Append(new float[4800]);
        store.Save(entry with { State = RecordingState.Recording, DurationMs = 0 });
        var reopened = new LocalRecordingStore(store.Root);
        Check(reopened.RecoverInterruptedRecordings() == 1, "Missing recovery result.");
        var recovered = reopened.List().Single();
        Check(recovered.State == RecordingState.Error && recovered.DurationMs == 100 && recovered.Error is not null,
            "Interrupted recording remains active and unavailable for playback after restart.");
        Check(reopened.RecoverInterruptedRecordings() == 0, "Recovery is not idempotent.");

        var stale = store.Create("Header lagged the payload");
        using (var writer = new PcmWaveWriter(stale.AudioPath)) writer.Append(Enumerable.Repeat(.25f, 9600).ToArray());
        var bytes = File.ReadAllBytes(stale.AudioPath);
        bytes.AsSpan(4, 4).Clear(); bytes.AsSpan(40, 4).Clear();
        File.WriteAllBytes(stale.AudioPath, [.. bytes, 0x7f]); // Incomplete final PCM sample must not destroy earlier audio.
        var payload = File.ReadAllBytes(stale.AudioPath)[44..];
        var archive = store.CaptionPath(stale); File.WriteAllText(archive, "retained caption\n");
        Check(store.RecoverInterruptedRecordings() == 1, "Stale header was not recovered.");
        var fixedBytes = File.ReadAllBytes(stale.AudioPath);
        Check(fixedBytes.AsSpan(44).SequenceEqual(payload), "Recovery changed or truncated audio payload.");
        Check(BinaryPrimitives.ReadUInt32LittleEndian(fixedBytes.AsSpan(40)) == 19200 &&
            BinaryPrimitives.ReadUInt32LittleEndian(fixedBytes.AsSpan(4)) == 19236, "Recovered WAV lengths are incorrect.");
        Check(store.List().Single(x => x.Id == stale.Id).DurationMs == 200 && File.ReadAllText(archive) == "retained caption\n", "Duration or captions were damaged.");

        var live = store.Create("Active writer");
        using (var writer = new PcmWaveWriter(live.AudioPath))
        {
            writer.Append(new float[4800]);
            Check(store.RecoverInterruptedRecordings() == 0 && store.List().Single(x => x.Id == live.Id).State == RecordingState.Starting,
                "Recovery altered an active writer.");
            writer.Append(new float[4800]);
        }
        Check(store.RecoverInterruptedRecordings() == 1 && store.List().Single(x => x.Id == live.Id).DurationMs == 200, "Deferred recovery did not retry.");

        var malformed = store.Create("Unknown format");
        File.WriteAllBytes(malformed.AudioPath, Enumerable.Repeat((byte)0x42, 80).ToArray());
        var malformedBytes = File.ReadAllBytes(malformed.AudioPath);
        var missing = store.Create("No audio file");
        Check(store.RecoverInterruptedRecordings() == 2, "Missing or malformed audio left a stale active session.");
        Check(File.ReadAllBytes(malformed.AudioPath).SequenceEqual(malformedBytes) && !File.Exists(missing.AudioPath), "Recovery fabricated or changed invalid audio.");
        Check(store.List().Where(x => x.Id == malformed.Id || x.Id == missing.Id).All(x => x.State == RecordingState.Error && x.DurationMs == 0), "Invalid audio was marked complete.");

        var done = store.Create("Completed");
        using (var writer = new PcmWaveWriter(done.AudioPath)) writer.Append(new float[4800]);
        store.Save(done with { State = RecordingState.Done, DurationMs = 100 });
        var metadata = File.ReadAllBytes(Path.Combine(done.Directory, "desktop-session.json"));
        var audioBytes = File.ReadAllBytes(done.AudioPath);
        Check(store.RecoverInterruptedRecordings() == 0 && File.ReadAllBytes(done.AudioPath).SequenceEqual(audioBytes) &&
            File.ReadAllBytes(Path.Combine(done.Directory, "desktop-session.json")).SequenceEqual(metadata), "Recovery changed a completed recording.");
        var childRoot = Path.Combine(root, "interrupted-process");
        Directory.CreateDirectory(childRoot);
        var start = new ProcessStartInfo(Path.Combine(AppContext.BaseDirectory, "Recappi.Core.Tests.exe")) { UseShellExecute = false, CreateNoWindow = true };
        start.ArgumentList.Add("--interrupted-recording-child"); start.ArgumentList.Add(childRoot);
        using var child = Process.Start(start) ?? throw new Exception("Could not start isolated recording fixture.");
        try
        {
            var ready = Path.Combine(childRoot, "ready");
            for (var attempt = 0; attempt < 300 && !File.Exists(ready) && !child.HasExited; attempt++) await Task.Delay(100);
            Check(File.Exists(ready) && !child.HasExited, "Child did not start recording.");
            child.Kill(); // Only the process created above; deliberately bypass normal recording finalization.
            await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));
            var childStore = new LocalRecordingStore(childRoot);
            var interrupted = childStore.List().Single();
            Check(interrupted.State == RecordingState.Recording, "Child finalized before abrupt termination.");
            // Process termination can precede release of in-flight filesystem handles.
            byte[]? originalPayload = null;
            for (var attempt = 0; attempt < 100; attempt++)
            {
                try
                {
                    using var released = new FileStream(interrupted.AudioPath, FileMode.Open, FileAccess.Read, FileShare.None);
                    var retained = new byte[released.Length]; released.ReadExactly(retained);
                    originalPayload = retained[44..]; break;
                }
                catch (IOException error) when ((error.HResult & 0xffff) is 32 or 33) { await Task.Delay(50); }
            }
            Check(originalPayload is not null, "Terminated recording retained a file lock.");
            Check(childStore.RecoverInterruptedRecordings() == 1, "Abruptly terminated recording did not recover.");
            var restored = childStore.List().Single();
            Check(restored.State == RecordingState.Error && restored.DurationMs >= 300 &&
                File.ReadAllBytes(restored.AudioPath).AsSpan(44).SequenceEqual(originalPayload), "Abrupt termination recovery lost retained audio.");
        }
        finally
        {
            if (!child.HasExited) { child.Kill(); await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10)); }
        }
    }

    public static async Task RunChildAsync(string root)
    {
        await using var engine = new RecordingEngine(new LocalRecordingStore(root), _ => [new ToneInput()]);
        await engine.StartAsync(new("Interrupted process fixture", true, false));
        await Task.Delay(600);
        File.WriteAllText(Path.Combine(root, "ready"), Environment.ProcessId.ToString());
        await Task.Delay(TimeSpan.FromSeconds(60));
    }

    private sealed class ToneInput : IAudioInput
    {
        private long sample;
        public string Input => "system";
        public Exception? Error => null;
        public void Start() { }
        public void Stop() { }
        public void Dispose() { }
        public void Read(float[] destination)
        {
            for (var i = 0; i < destination.Length; i++) destination[i] = (float)(.1 * Math.Sin(2 * Math.PI * 440 * sample++ / PcmWaveWriter.SampleRate));
        }
    }

    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
}
