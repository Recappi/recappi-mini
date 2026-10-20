using NAudio.Wave;

namespace Recappi.Core;

/// <summary>Decode local media with Windows codecs into the library's PCM format.</summary>
public sealed class AudioImport(LocalRecordingStore store)
{
    public Task<LocalRecording> ImportAsync(string source, ProcessingOptions? options = null,
        IProgress<double>? progress = null, CancellationToken cancellation = default) => Task.Run(() =>
    {
        cancellation.ThrowIfCancellationRequested();
        source = Path.GetFullPath(source);
        if (!File.Exists(source)) throw new FileNotFoundException(L.T("找不到要导入的音频。", "Couldn’t find the audio to import."), source);
        if (store.RestoreRemovedAudio(source, cancellation) is { } restored)
        {
            progress?.Report(1);
            return restored;
        }
        using var reader = new MediaFoundationReader(source);
        using var converter = new MediaFoundationResampler(reader, new WaveFormat(48000, 16, 1));
        var recording = store.Create(Path.GetFileNameWithoutExtension(source), options);
        try
        {
            long bytes = 0;
            using (var output = new WaveFileWriter(recording.AudioPath, converter.WaveFormat))
            {
                var buffer = new byte[96000];
                while (true)
                {
                    cancellation.ThrowIfCancellationRequested();
                    var count = converter.Read(buffer, 0, buffer.Length);
                    if (count == 0) break;
                    bytes += count;
                    if (bytes > uint.MaxValue - 128L) throw new IOException(L.T("音频超过本地 WAV 大小限制。", "The audio exceeds the local WAV size limit."));
                    output.Write(buffer, 0, count);
                    if (reader.Length > 0) progress?.Report(Math.Clamp((double)reader.Position / reader.Length, 0, 0.99));
                }
                if (bytes == 0) throw new InvalidDataException(L.T("文件中没有可导入的音频。", "The file has no audio to import."));
            }
            cancellation.ThrowIfCancellationRequested();
            recording = recording with { State = RecordingState.Done, DurationMs = bytes * 1000 / 96000 };
            store.Save(recording);
            progress?.Report(1);
            return recording;
        }
        catch { store.Discard(recording); throw; }
    }, cancellation);
}
