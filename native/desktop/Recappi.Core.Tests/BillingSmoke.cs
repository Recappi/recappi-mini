using System.Text.Json;
using Recappi.Core;

internal static class BillingSmoke
{
    public static async Task RunAsync(string output)
    {
        // Explicit opt-in only; reuse the already-authorized CLI account in memory.
        using var config = JsonDocument.Parse(File.ReadAllText(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config", "recappi", "config.json")));
        var origin = config.RootElement.GetProperty("origin").GetString() ?? throw new InvalidOperationException("Test origin missing.");
        var token = config.RootElement.GetProperty("authToken").GetString() ?? throw new InvalidOperationException("Test account missing.");
        using var client = new CloudClient(origin, token);
        using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var session = await client.SessionAsync(limit.Token);
        if (!session.TryGetProperty("user", out var user) || user.ValueKind != JsonValueKind.Object) throw new InvalidOperationException("Test account is not connected.");
        var status = await client.BillingStatusAsync(limit.Token);
        var report = new { checkedAt = DateTimeOffset.UtcNow, sessionValidated = true, billingParsed = true,
            knownTier = status.Tier is "free" or "starter" or "pro" or "business" or "unlimited", hasPeriodEnd = status.PeriodEnd is not null,
            portalRequested = false, accountIdentityAndUsageOmitted = true };
        File.WriteAllText(Path.Combine(output, "billing-smoke.json"), JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine("PASS real authenticated billing status decoded; identity, quota values and credentials omitted. No portal or subscription write requested.");
    }
}
