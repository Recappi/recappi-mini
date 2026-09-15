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

    // Startup only: the exclusive handle refuses a still-running capture/import.
    // Preserve every payload byte; only reconcile the native writer's size fields.
    internal static long RecoverInterrupted(FileStream stream)
    {
        Span<byte> header = stackalloc byte[36];
        if (stream.Length < header.Length) throw new InvalidDataException("Incomplete WAV header.");
        stream.ReadExactly(header);
        var formatSize = BinaryPrimitives.ReadUInt32LittleEndian(header[16..]);
        if (!header[..4].SequenceEqual("RIFF"u8) || !header[8..16].SequenceEqual("WAVEfmt "u8) || formatSize is not (16 or 18) ||
            BinaryPrimitives.ReadUInt16LittleEndian(header[20..]) != 1 ||
            BinaryPrimitives.ReadUInt16LittleEndian(header[22..]) != 1 ||
            BinaryPrimitives.ReadUInt32LittleEndian(header[24..]) != SampleRate ||
            BinaryPrimitives.ReadUInt32LittleEndian(header[28..]) != SampleRate * 2 ||
            BinaryPrimitives.ReadUInt16LittleEndian(header[32..]) != 2 ||
            BinaryPrimitives.ReadUInt16LittleEndian(header[34..]) != 16)
            throw new InvalidDataException("Unrecognized native WAV format.");
        // NAudio's import writer emits PCM fmt length 18 with an empty extension;
        // the recording writer emits length 16. Neither emits trailing chunks.
        var dataOffset = 28L + formatSize;
        if (stream.Length < dataOffset) throw new InvalidDataException("Incomplete WAV header.");
        if (formatSize == 18 && (stream.ReadByte() != 0 || stream.ReadByte() != 0))
            throw new InvalidDataException("Unrecognized PCM extension.");
        Span<byte> dataHeader = stackalloc byte[8];
        stream.ReadExactly(dataHeader);
        if (!dataHeader[..4].SequenceEqual("data"u8)) throw new InvalidDataException("Unrecognized WAV chunks.");
        var audioBytes = (stream.Length - dataOffset) / 2 * 2;
        if (audioBytes > uint.MaxValue - (dataOffset - 8)) throw new InvalidDataException("Native WAV is oversized.");
        Span<byte> size = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(size, (uint)(dataOffset - 8 + audioBytes));
        stream.Position = 4; stream.Write(size);
        BinaryPrimitives.WriteUInt32LittleEndian(size, (uint)audioBytes);
        stream.Position = dataOffset - 4; stream.Write(size);
        stream.Flush(true);
        return audioBytes * 1000 / (SampleRate * 2);
    }

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
