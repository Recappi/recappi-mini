using System.Text;
using System.Text.Json;
using System.Threading.Channels;

namespace Recappi.Core;

public sealed record ArchivedCaption(string SegmentId, string Stream, string Text, DateTimeOffset ReceivedAt, CaptionPosition? Position = null, bool IsFailed = false, bool IsRevision = false);

public sealed class CaptionArchive : IAsyncDisposable
{
    private readonly Channel<ArchivedCaption[]> pending = Channel.CreateBounded<ArchivedCaption[]>(128);
    private int pendingCaptions;
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
                await foreach (var batch in pending.Reader.ReadAllAsync())
                {
                    try
                    {
                        foreach (var item in batch) await output.WriteLineAsync(JsonSerializer.Serialize(item));
                        await output.FlushAsync();
                    }
                    finally { Interlocked.Add(ref pendingCaptions, -batch.Length); }
                }
            }
            catch (Exception)
            {
                ReportError(L.T("字幕归档写入失败；本地音频仍会保留。", "Couldn’t write the caption archive. Local audio is still kept.")); pending.Writer.TryComplete();
                while (pending.Reader.TryRead(out var discarded)) Interlocked.Add(ref pendingCaptions, -discarded.Length);
            }
        });
    }
    public void Append(CaptionDelta value)
    {
        if (!value.IsFailed && (!value.IsFinal || string.IsNullOrWhiteSpace(value.Text))) return;
        AppendCore([new(value.SegmentId, value.Stream, value.Text, DateTimeOffset.UtcNow, value.Position, value.IsFailed)]);
    }
    public void AppendRevisions(IReadOnlyList<CaptionDelta> values)
    {
        AppendCore(values.Where(x => x.IsFailed || x.IsFinal && !string.IsNullOrWhiteSpace(x.Text))
            .Select(x => new ArchivedCaption(x.SegmentId, x.Stream, x.Text, DateTimeOffset.UtcNow, x.Position, x.IsFailed, IsRevision: true)).ToArray());
    }
    private void AppendCore(ArchivedCaption[] batch)
    {
        if (batch.Length == 0) return;
        // Reordering can revise up to 512 retained content parts at once. Bound
        // actual queued captions as well as batch count; a batch is accepted whole.
        var count = Interlocked.Add(ref pendingCaptions, batch.Length);
        if (count > 1024 || !pending.Writer.TryWrite(batch))
        {
            Interlocked.Add(ref pendingCaptions, -batch.Length);
            ReportError(L.T("字幕归档未能保存全部内容；本地音频仍会保留。", "The caption archive couldn’t save everything. Local audio is still kept."));
        }
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
