using NAudio.Wave;
using Recappi.Core;

internal static class AudioImportTests
{
    public static async Task RunAsync(string root)
    {
        var source = Path.Combine(root, "import-source.wav");
        using (var writer = new PcmWaveWriter(source))
            for (var second = 0; second < 4; second++) writer.Append(Enumerable.Range(0, 48000).Select(i => (float)(.2 * Math.Sin(i * 2 * Math.PI * 440 / 48000))).ToArray());
        var original = await File.ReadAllBytesAsync(source);
        var store = new LocalRecordingStore(Path.Combine(root, "imports"));
        var importer = new AudioImport(store);
        var entry = await importer.ImportAsync(source);
        using (var reader = new WaveFileReader(entry.AudioPath))
        {
            if (entry.State != RecordingState.Done || Math.Abs(entry.DurationMs - 4000) > 30 || reader.WaveFormat.SampleRate != 48000 || reader.WaveFormat.Channels != 1 || reader.WaveFormat.BitsPerSample != 16)
                throw new Exception("Imported media format/duration is invalid.");
            var samples = new byte[4096]; reader.ReadExactly(samples);
            if (samples.All(value => value == 0)) throw new Exception("Import lost source audio.");
        }
        using var cancellation = new CancellationTokenSource();
        try
        {
            await importer.ImportAsync(source, progress: new CallbackProgress(_ => cancellation.Cancel()), cancellation: cancellation.Token);
            throw new Exception("Canceled import succeeded.");
        }
        catch (OperationCanceledException) { }
        if (store.List().Count != 1 || Directory.GetDirectories(store.Root).Length != 1) throw new Exception("Canceled import left a partial recording.");
        var damaged = Path.Combine(root, "invalid-audio.wav");
        await File.WriteAllTextAsync(damaged, "not audio");
        var rejected = false;
        try { await importer.ImportAsync(damaged); } catch { rejected = true; }
        var after = await File.ReadAllBytesAsync(source);
        if (!rejected || store.List().Count != 1 || !original.SequenceEqual(after)) throw new Exception("Import failure damaged the library or source.");
        foreach (var format in new[] { "mp3", "m4a" })
        {
            var compressed = Path.Combine(root, "import-source." + format);
            using (var input = new WaveFileReader(source))
            {
                if (format == "mp3") MediaFoundationEncoder.EncodeToMp3(input, compressed, 128000);
                else MediaFoundationEncoder.EncodeToAac(input, compressed, 128000);
            }
            var decoded = await importer.ImportAsync(compressed);
            using var decodedWave = new WaveFileReader(decoded.AudioPath);
            if (Math.Abs(decoded.DurationMs - 4000) > 150 || decodedWave.Length < 380000)
                throw new Exception("Compressed import duration/data lost: " + format);
        }
    }
    private sealed class CallbackProgress(Action<double> report) : IProgress<double> { public void Report(double value) => report(value); }
}
