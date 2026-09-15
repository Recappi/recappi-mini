using System.Globalization;
using System.Net;
using System.Text.Json;

namespace Recappi.Core;

public sealed record BillingStatus(string Tier, long StorageBytes, long StorageCapBytes,
    double MinutesUsed, double MinutesCap, bool IsOverStorage, bool IsOverMinutes, DateTimeOffset? PeriodEnd)
{
    public bool UnlimitedStorage => Tier == "unlimited" || StorageCapBytes <= 0;
    public bool UnlimitedMinutes => Tier == "unlimited" || MinutesCap <= 0;
    public bool OverLimit => (!UnlimitedStorage && IsOverStorage) || (!UnlimitedMinutes && IsOverMinutes);
    public double StoragePercent => UnlimitedStorage ? 0 : Math.Clamp(100d * StorageBytes / StorageCapBytes, 0, 100);
    public double MinutesPercent => UnlimitedMinutes ? 0 : Math.Clamp(100d * MinutesUsed / MinutesCap, 0, 100);

    public static BillingStatus Parse(JsonElement value)
    {
        var tier = value.GetProperty("tier").GetString();
        var storage = value.GetProperty("storageBytes").GetInt64();
        var minutes = value.GetProperty("minutesUsed").GetDouble();
        var storageCap = value.TryGetProperty("storageCapBytes", out var bytes) && bytes.ValueKind != JsonValueKind.Null ? bytes.GetInt64() : 0;
        var minutesCap = value.TryGetProperty("minutesCap", out var cap) && cap.ValueKind != JsonValueKind.Null ? cap.GetDouble() : 0;
        if (string.IsNullOrWhiteSpace(tier) || tier.Length > 64 || tier.Any(char.IsControl) || storage < 0 || minutes < 0 || !double.IsFinite(minutes) || !double.IsFinite(minutesCap))
            throw new JsonException("Invalid billing usage.");
        DateTimeOffset? end = null;
        if (value.TryGetProperty("periodEnd", out var period) && period.ValueKind != JsonValueKind.Null)
        {
            if (period.ValueKind == JsonValueKind.String && DateTimeOffset.TryParse(period.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date)) end = date;
            else if (period.ValueKind == JsonValueKind.Number && period.TryGetInt64(out var timestamp))
            {
                try { end = Math.Abs((double)timestamp) >= 100_000_000_000 ? DateTimeOffset.FromUnixTimeMilliseconds(timestamp) : DateTimeOffset.FromUnixTimeSeconds(timestamp); }
                catch (ArgumentOutOfRangeException) { throw new JsonException("Invalid billing period."); }
            }
            else throw new JsonException("Invalid billing period.");
        }
        return new(tier, storage, storageCap, minutes, minutesCap,
            value.GetProperty("isOverStorage").GetBoolean(), value.GetProperty("isOverMinutes").GetBoolean(), end);
    }
}

public sealed partial class CloudClient
{
    public async Task<BillingStatus> BillingStatusAsync(CancellationToken cancellation = default) =>
        BillingStatus.Parse(await BillingAsync(cancellation));

    public async Task<Uri> BillingPortalAsync(CancellationToken cancellation = default)
    {
        JsonElement result;
        try { result = await SendJsonAsync(HttpMethod.Post, "/api/billing/portal", new { }, cancellation); }
        catch (CloudException error) when (error.Status == HttpStatusCode.Conflict) { return new Uri(Origin, "/plans"); }
        var raw = result.GetProperty("url").GetString();
        if (raw is null || raw.Any(char.IsControl) || !Uri.TryCreate(raw, UriKind.Absolute, out var uri) || uri.Scheme != "https" ||
            !string.IsNullOrEmpty(uri.UserInfo) || !uri.IsDefaultPort ||
            !(uri.IdnHost.Equals(Origin.IdnHost, StringComparison.OrdinalIgnoreCase) && uri.Port == Origin.Port || uri.IdnHost.Equals("billing.stripe.com", StringComparison.OrdinalIgnoreCase)))
            throw new InvalidDataException("Billing portal returned an untrusted URL.");
        return uri;
    }
}
