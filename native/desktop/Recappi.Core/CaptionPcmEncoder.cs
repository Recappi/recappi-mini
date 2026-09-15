using System.Buffers.Binary;

namespace Recappi.Core;

public sealed class CaptionPcmEncoder
{
    private float? previous;
    public byte[] Encode(ReadOnlySpan<float> samples)
    {
        var bytes = new byte[((samples.Length + (previous.HasValue ? 1 : 0)) / 2) * 2]; var offset = 0;
        foreach (var sample in samples)
        {
            var finite = float.IsFinite(sample) ? Math.Clamp(sample, -1, 1) : 0;
            if (previous is not { } first) { previous = finite; continue; }
            var value = (first + finite) / 2d;
            BinaryPrimitives.WriteInt16LittleEndian(bytes.AsSpan(offset), (short)Math.Floor(value * (value < 0 ? 32768 : 32767) + .5));
            offset += 2; previous = null;
        }
        return bytes;
    }
}
