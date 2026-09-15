using System.Text.Json;

namespace Recappi.Core;

public sealed record CloudRecordingItem(string Id, string Title, string Status, long DurationMs)
{
    public DateTimeOffset? CreatedAt { get; init; }
    public static CloudRecordingItem Parse(JsonElement value) => new(
        CloudFields.Text(value, "id") ?? throw new InvalidDataException("Recording ID missing."),
        CloudFields.Text(value, "summaryTitle") ?? CloudFields.Text(value, "title") ?? "未命名录音",
        CloudFields.Text(value, "status") ?? "unknown",
        value.TryGetProperty("durationMs", out var duration) && duration.ValueKind == JsonValueKind.Number && duration.TryGetInt64(out var ms) ? ms : 0)
        { CreatedAt = ParseCreatedAt(value) };
    private static DateTimeOffset? ParseCreatedAt(JsonElement value)
    {
        if (!value.TryGetProperty("createdAt", out var timestamp)) return null;
        var raw = timestamp.ValueKind is JsonValueKind.Number or JsonValueKind.String ? timestamp.ToString() : null;
        if (double.TryParse(raw, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var numeric))
        {
            if (!double.IsFinite(numeric)) return null;
            // Match the macOS decoder's seconds/milliseconds compatibility.
            var milliseconds = numeric > 10_000_000_000 ? numeric : numeric * 1000;
            if (milliseconds < -62135596800000d || milliseconds > 253402300799999d) return null;
            return DateTimeOffset.FromUnixTimeMilliseconds((long)milliseconds);
        }
        return DateTimeOffset.TryParse(raw, System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal, out var date) ? date : null;
    }
}

public sealed record CloudRecordingPage(IReadOnlyList<CloudRecordingItem> Items, string? NextCursor)
{
    public static CloudRecordingPage Parse(JsonElement value) => new(
        value.GetProperty("items").EnumerateArray().Select(CloudRecordingItem.Parse).ToArray(), CloudFields.Text(value, "nextCursor"));
}

public sealed record CloudTranscript(string Text, string Summary, string SummaryStatus)
{
    public IReadOnlyList<CloudTranscriptSegment> Segments { get; init; } = [];
    public static CloudTranscript Parse(JsonElement value)
    {
        var segments = CloudFields.Structured(value, "segments", "segmentsJson");
        var parsed = segments.ValueKind == JsonValueKind.Array ? segments.EnumerateArray().Select(CloudTranscriptSegment.Parse).Where(x => !string.IsNullOrWhiteSpace(x.Text)).ToArray() : [];
        // Match the legacy timeline normalization used by TranscriptResponse.swift.
        var durations = parsed.Where(x => x.StartMs is not null && x.EndMs > x.StartMs).Select(x => x.EndMs!.Value - x.StartMs!.Value).Order().ToArray();
        if (durations.Length > 0 && parsed.Max(x => x.EndMs ?? 0) < 86400 && durations[durations.Length / 2] <= 120)
            parsed = parsed.Select(x => x with { StartMs = x.StartMs * 1000, EndMs = x.EndMs * 1000 }).ToArray();
        var lines = parsed.Select(x => x.Text).ToArray();
        var text = lines.Length > 0 ? string.Join(Environment.NewLine, lines) : CloudFields.Text(value, "text") ?? "";
        var insights = CloudFields.Structured(value, "summaryInsights", "summaryJson");
        var summary = new List<string>();
        var overview = CloudFields.Text(value, "summary") ?? CloudFields.Text(insights, "tldr") ?? CloudFields.Text(insights, "summary");
        if (overview is not null) summary.Add(overview);
        foreach (var (key, title) in new[] { ("keyPoints", "要点"), ("topics", "话题"), ("decisions", "决策"), ("actionItems", "行动项"), ("quotes", "引用"), ("timeline", "时间线") })
        {
            var items = key == "actionItems" ? CloudFields.Structured(value, "actionItems", "actionItemsJson") : default;
            if (items.ValueKind != JsonValueKind.Array || items.GetArrayLength() == 0) items = CloudFields.Structured(insights, key, key + "Json");
            if (items.ValueKind != JsonValueKind.Array) continue;
            var rendered = items.EnumerateArray().Select(item => item.ValueKind == JsonValueKind.String ? item.GetString() :
                key == "actionItems" ? Join(CloudFields.Text(item, "who"), CloudFields.Text(item, "what")) :
                key == "quotes" ? Join(CloudFields.Text(item, "speaker"), CloudFields.Text(item, "text")) :
                Join(CloudFields.Text(item, "title"), CloudFields.Text(item, "summary"))).Where(x => !string.IsNullOrWhiteSpace(x)).ToArray();
            if (rendered.Length > 0) summary.Add(title + Environment.NewLine + string.Join(Environment.NewLine, rendered.Select(x => "• " + x)));
        }
        return new(text, string.Join(Environment.NewLine + Environment.NewLine, summary), CloudFields.Text(value, "summaryStatus") ?? "") { Segments = parsed };
    }
    private static string Join(string? first, string? second) => string.Join("：", new[] { first, second }.Where(x => !string.IsNullOrWhiteSpace(x)));
}

public sealed record CloudTranscriptSegment(string Text, string? Speaker, long? StartMs, long? EndMs)
{
    public SpeakerProfile? Profile { get; init; }
    public string Label => (StartMs is { } ms ? TimeSpan.FromMilliseconds(ms).ToString(@"hh\:mm\:ss") + " · " : "") + (Profile is { } profile ? profile.Emoji + " " + profile.Name : Speaker ?? "未标注说话人");
    internal static CloudTranscriptSegment Parse(JsonElement value) => new(CloudFields.Text(value, "text") ?? "",
        CloudFields.Text(value, "speaker") ?? CloudFields.Text(value, "speakerLabel"),
        Time(value, "startMs", "startTimeMs", "start"), Time(value, "endMs", "endTimeMs", "end"));
    private static long? Time(JsonElement value, params string[] keys)
    {
        if (value.ValueKind != JsonValueKind.Object) return null;
        foreach (var key in keys)
            if (value.TryGetProperty(key, out var field) && double.TryParse(field.ToString(), System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var number) && double.IsFinite(number) && number >= 0 && number <= 604800000)
                return (long)Math.Round(number);
        return null;
    }
}

internal static class CloudFields
{
    public static string? Text(JsonElement value, string name) => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var item) && item.ValueKind == JsonValueKind.String && !string.IsNullOrWhiteSpace(item.GetString()) ? item.GetString() : null;
    public static JsonElement Structured(JsonElement value, string name, string legacy)
    {
        if (value.ValueKind != JsonValueKind.Object) return default;
        if (value.TryGetProperty(name, out var item) && item.ValueKind is JsonValueKind.Array or JsonValueKind.Object) return item;
        var raw = Text(value, legacy);
        if (raw is null) return default;
        try { using var parsed = JsonDocument.Parse(raw); return parsed.RootElement.Clone(); }
        catch (JsonException) { return default; }
    }
}
