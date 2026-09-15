using System.Text.Json;

namespace Recappi.Core;

public sealed record CloudJob(string Id, string Status, string? TranscriptId, long? EnqueuedAt, double Progress, bool HasRetryableChunks)
{
    public bool IsActive => Status is "queued" or "running";
    public string Display => (EnqueuedAt is >= 0 and < 253402300800000 ? DateTimeOffset.FromUnixTimeMilliseconds(EnqueuedAt.Value).ToLocalTime().ToString("MM-dd HH:mm") : Id) + " · " + (Status switch { "queued" => "排队中", "running" => $"转写中 {Progress:0}%", "succeeded" => "已完成", "failed" => "失败", _ => Status });
    public static CloudJob Parse(JsonElement value)
    {
        var id = CloudFields.Text(value, "id") ?? throw new InvalidDataException("Job ID missing.");
        var progress = 0d; var retryable = false;
        if (value.TryGetProperty("chunkProgress", out var chunks) && chunks.ValueKind == JsonValueKind.Object)
        {
            if (chunks.TryGetProperty("percent", out var percent) && percent.ValueKind == JsonValueKind.Number && percent.TryGetDouble(out var number)) progress = Math.Clamp(number, 0, 100);
            if (chunks.TryGetProperty("failedChunks", out var failed) && failed.ValueKind == JsonValueKind.Array)
                retryable = failed.EnumerateArray().Any(x => x.ValueKind == JsonValueKind.Object && x.TryGetProperty("retryable", out var canRetry) && canRetry.ValueKind == JsonValueKind.True);
        }
        return new(id, CloudFields.Text(value, "status") ?? "unknown", CloudFields.Text(value, "transcriptId"), value.TryGetProperty("enqueuedAt", out var date) && date.ValueKind == JsonValueKind.Number && date.TryGetInt64(out var ms) ? ms : null, progress, retryable);
    }
}
