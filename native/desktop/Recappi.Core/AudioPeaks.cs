using NAudio.Wave;

namespace Recappi.Core;

/// <summary>Per-bucket peak levels for the playback scrubber, decoded with Windows codecs.</summary>
public static class AudioPeaks
{
    public static Task<float[]> ComputeAsync(string path, int buckets, CancellationToken cancellation = default) => Task.Run(() =>
    {
        if (buckets <= 0) throw new ArgumentOutOfRangeException(nameof(buckets));
        // Decode from a stream: cached cloud audio uses a neutral ".audio" extension,
        // which Media Foundation cannot resolve from the file name.
        using var file = File.OpenRead(path);
        using var reader = new StreamMediaFoundationReader(file);
        var samples = reader.ToSampleProvider();
        var channels = samples.WaveFormat.Channels;
        var total = reader.Length / Math.Max(1, reader.WaveFormat.BlockAlign);
        var peaks = new float[buckets];
        if (total <= 0) return peaks;
        var buffer = new float[samples.WaveFormat.SampleRate * channels / 10];
        long frame = 0;
        while (true)
        {
            cancellation.ThrowIfCancellationRequested();
            var count = samples.Read(buffer, 0, buffer.Length);
            if (count == 0) break;
            for (var i = 0; i < count; i++)
            {
                var bucket = (int)Math.Min(buckets - 1, (frame + i / channels) * buckets / total);
                var value = Math.Abs(buffer[i]);
                if (value > peaks[bucket]) peaks[bucket] = value;
            }
            frame += count / channels;
        }
        // Normalize to the loudest bucket so quiet recordings still show their shape.
        var max = peaks.Max();
        if (max > 0) for (var i = 0; i < peaks.Length; i++) peaks[i] /= max;
        return peaks;
    }, cancellation);
}
