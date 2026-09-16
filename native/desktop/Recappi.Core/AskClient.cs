using System.Net.Http.Json;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.Json;

namespace Recappi.Core;

public sealed record AskCitation(string? SegmentId, int? Index, long? StartMs, long? EndMs, string? Label, string? Speaker, string? Snippet)
{
    public string Display => (Label ?? Speaker ?? "引用") + (StartMs is >= 0 ? " · " + TimeSpan.FromMilliseconds(StartMs.Value).ToString(@"hh\:mm\:ss") : "") + " · " + Snippet;
}
public sealed record AskMessage(string Id, string Role, string Content, string? Status, AskCitation[]? Citations);
public sealed record AskEvent(string Name, string? Text, AskCitation[] Citations);

public sealed partial class CloudClient
{
    public async Task<AskMessage[]> AskHistoryAsync(string id, CancellationToken cancellation = default)
    {
        var value = await SendJsonAsync(HttpMethod.Get, RecordingPath(id) + "/ask-thread", null, cancellation);
        return value.GetProperty("messages").Deserialize<AskMessage[]>(Json) ?? [];
    }
    public async Task<string[]> AskSuggestionsAsync(string id, CancellationToken cancellation = default)
    {
        var value = await SendJsonAsync(HttpMethod.Get, RecordingPath(id) + "/ask-suggestions", null, cancellation);
        return value.GetProperty("suggestions").EnumerateArray()
            .Select(item => item.ValueKind == JsonValueKind.String ? item.GetString() : CloudFields.Text(item, "question"))
            .Where(question => !string.IsNullOrWhiteSpace(question))
            .Select(question => question!.Trim()).ToArray();
    }
    public async IAsyncEnumerable<AskEvent> AskAsync(string id, string question, bool webSearch = false, string? model = null, [EnumeratorCancellation] CancellationToken cancellation = default)
    {
        if (string.IsNullOrWhiteSpace(question)) throw new ArgumentException("请输入问题。");
        using var content = JsonContent.Create(new { question, webSearch, model }, options: Json);
        using var response = await SendAsync(HttpMethod.Post, RecordingPath(id) + "/ask-thread/messages", content, cancellation, "text/event-stream");
        if (response.Content.Headers.ContentType?.MediaType != "text/event-stream") throw new InvalidDataException("问答响应格式不正确。");
        using var stream = await response.Content.ReadAsStreamAsync(cancellation);
        await foreach (var frame in AskEventReader.ReadAsync(stream, cancellation))
        {
            if (frame.Name is not ("metadata" or "answer_delta" or "citation" or "done" or "error")) continue;
            using var data = JsonDocument.Parse(frame.Data);
            var value = data.RootElement;
            if (frame.Name == "error") throw new InvalidDataException("问答生成失败，请稍后重试。");
            var citations = frame.Name == "citation" ? new[] { value.GetProperty("citation").Deserialize<AskCitation>(Json) ?? throw new InvalidDataException("引用缺失。") } :
                frame.Name == "done" && value.TryGetProperty("citations", out var list) ? list.Deserialize<AskCitation[]>(Json) ?? [] : [];
            var text = value.TryGetProperty(frame.Name == "answer_delta" ? "delta" : "content", out var raw) && raw.ValueKind == JsonValueKind.String ? raw.GetString() : null;
            yield return new(frame.Name, text, citations);
            if (frame.Name == "done") yield break;
        }
        throw new EndOfStreamException("回答连接已中断，已收到的内容可能不完整。请刷新历史后重试。");
    }
}

public static class AskEventReader
{
    public sealed record Frame(string Name, string Data);
    public static async IAsyncEnumerable<Frame> ReadAsync(Stream stream, [EnumeratorCancellation] CancellationToken cancellation = default)
    {
        using var reader = new StreamReader(stream, new UTF8Encoding(false, true), true, 4096, leaveOpen: true);
        var buffer = new char[4096];
        var line = new StringBuilder();
        var data = new StringBuilder();
        var name = "message";
        bool previousCr = false;
        Frame? Consume()
        {
            var value = line.ToString(); line.Clear();
            if (value.Length == 0)
            {
                var frame = data.Length == 0 ? null : new Frame(name, data.ToString().TrimEnd('\n'));
                data.Clear(); name = "message"; return frame;
            }
            if (value.StartsWith(':')) return null;
            var colon = value.IndexOf(':');
            var field = colon < 0 ? value : value[..colon];
            var body = colon < 0 ? "" : value[(colon + 1)..];
            if (body.StartsWith(' ')) body = body[1..];
            if (field == "event") name = body;
            else if (field == "data") { data.Append(body).Append('\n'); if (data.Length > 4 * 1024 * 1024) throw new InvalidDataException("问答事件过大。"); }
            return null;
        }
        while (true)
        {
            using var idle = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
            idle.CancelAfter(TimeSpan.FromSeconds(60));
            var count = await reader.ReadAsync(buffer.AsMemory(), idle.Token);
            if (count == 0) break;
            for (var i = 0; i < count; i++)
            {
                var ch = buffer[i];
                if (ch == '\n' && previousCr) { previousCr = false; continue; }
                previousCr = ch == '\r';
                if (ch is '\r' or '\n') { var frame = Consume(); if (frame is not null) yield return frame; }
                else { line.Append(ch); if (line.Length > 1024 * 1024) throw new InvalidDataException("问答行过长。"); }
            }
        }
        if (line.Length > 0) Consume();
        if (data.Length > 0) yield return new(name, data.ToString().TrimEnd('\n'));
    }
}
