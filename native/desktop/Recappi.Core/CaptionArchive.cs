using System.Text;
using System.Text.Json;
using System.Threading.Channels;

namespace Recappi.Core;

public sealed record ArchivedCaption(string SegmentId, string Stream, string Text, DateTimeOffset ReceivedAt);

public sealed class CaptionArchive : IAsyncDisposable
{
    private readonly Channel<ArchivedCaption> pending = Channel.CreateBounded<ArchivedCaption>(128);
    private readonly Task writer;
    private string? error;
    public string? Error => Volatile.Read(ref error);
    public event Action<string>? ErrorChanged;
    public CaptionArchive(string path, bool resume = false)
    {
        writer = Task.Run(async () =>
        {
            try
            {
                await using var file = new FileStream(path, resume ? FileMode.OpenOrCreate : FileMode.CreateNew, FileAccess.ReadWrite, FileShare.Read, 4096, true);
                if (resume && file.Length > 0)
                {
                    file.Seek(-1, SeekOrigin.End);
                    var last = file.ReadByte();
                    file.Seek(0, SeekOrigin.End);
                    if (last != '\n') await file.WriteAsync(new byte[] { (byte)'\n' });
                }
                await using var output = new StreamWriter(file, new UTF8Encoding(false));
                await foreach (var item in pending.Reader.ReadAllAsync())
                {
                    await output.WriteLineAsync(JsonSerializer.Serialize(item));
                    await output.FlushAsync();
                }
            }
            catch (Exception) { ReportError("字幕归档写入失败；本地音频仍会保留。"); pending.Writer.TryComplete(); }
        });
    }
    public void Append(CaptionDelta value)
    {
        if (!value.IsFinal || string.IsNullOrWhiteSpace(value.Text)) return;
        if (!pending.Writer.TryWrite(new(value.SegmentId, value.Stream, value.Text, DateTimeOffset.UtcNow)))
            ReportError("字幕归档未能保存全部内容；本地音频仍会保留。");
    }
    private void ReportError(string message)
    {
        if (Interlocked.CompareExchange(ref error, message, null) is not null) return;
        foreach (Action<string> observer in ErrorChanged?.GetInvocationList() ?? [])
            try { observer(message); } catch (Exception) { }
    }
    public async ValueTask DisposeAsync() { pending.Writer.TryComplete(); await writer; }
    public static IEnumerable<ArchivedCaption> Read(string path)
    {
        if (!File.Exists(path)) yield break;
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
        using var reader = new StreamReader(file);
        while (reader.ReadLine() is { } line)
        {
            ArchivedCaption? value;
            try { value = JsonSerializer.Deserialize<ArchivedCaption>(line); }
            catch (JsonException) { continue; } // A partial final line must not hide intact earlier captions.
            if (value is not null) yield return value;
        }
    }
}
