using System.Buffers.Binary;
using System.Text;

namespace Recappi.Core;

/// <summary>Single-writer, bounded-memory PCM16 file with an incrementally recoverable header.</summary>
public sealed class PcmWaveWriter : IDisposable
{
    private readonly FileStream stream;
    private long bytes;
    private bool disposed;
    public const int SampleRate = 48000;
    public long DurationMs => bytes * 1000 / (SampleRate * 2);
    public long AudioBytes => bytes;

    public PcmWaveWriter(string path)
    {
        stream = new FileStream(path, FileMode.CreateNew, FileAccess.ReadWrite, FileShare.Read);
        try { Header(); }
        catch { stream.Dispose(); throw; }
    }

    public void Append(ReadOnlySpan<float> samples)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (bytes + samples.Length * 2L > uint.MaxValue - 36) throw new IOException("Recording reached the WAV size limit.");
        // Chunks are bounded by the capture pump, not the meeting duration.
        Span<byte> buffer = samples.Length <= 4800 ? stackalloc byte[samples.Length * 2] : new byte[samples.Length * 2];
        for (var i = 0; i < samples.Length; i++)
        {
            var value = float.IsFinite(samples[i]) ? Math.Clamp(samples[i], -1f, 1f) : 0;
            var pcm = (short)Math.Round(value * (value < 0 ? 32768 : 32767));
            BinaryPrimitives.WriteInt16LittleEndian(buffer[(i * 2)..], pcm);
        }
        stream.Position = 44 + bytes;
        stream.Write(buffer);
        bytes += buffer.Length;
        Header();
        stream.Flush();
    }

    private void Header()
    {
        Span<byte> header = stackalloc byte[44];
        header.Clear();
        Encoding.ASCII.GetBytes("RIFF").CopyTo(header);
        BinaryPrimitives.WriteUInt32LittleEndian(header[4..], (uint)(36 + bytes));
        Encoding.ASCII.GetBytes("WAVEfmt ").CopyTo(header[8..]);
        BinaryPrimitives.WriteUInt32LittleEndian(header[16..], 16);
        BinaryPrimitives.WriteUInt16LittleEndian(header[20..], 1);
        BinaryPrimitives.WriteUInt16LittleEndian(header[22..], 1);
        BinaryPrimitives.WriteUInt32LittleEndian(header[24..], SampleRate);
        BinaryPrimitives.WriteUInt32LittleEndian(header[28..], SampleRate * 2);
        BinaryPrimitives.WriteUInt16LittleEndian(header[32..], 2);
        BinaryPrimitives.WriteUInt16LittleEndian(header[34..], 16);
        Encoding.ASCII.GetBytes("data").CopyTo(header[36..]);
        BinaryPrimitives.WriteUInt32LittleEndian(header[40..], (uint)bytes);
        stream.Position = 0;
        stream.Write(header);
    }

    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        try { Header(); stream.Flush(true); }
        finally { stream.Dispose(); }
    }
}
