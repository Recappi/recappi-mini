using System.Net;
using System.Text;
using System.Text.Json;
using Recappi.Core;

internal static class BillingTests
{
    public static async Task RunAsync()
    {
        static BillingStatus Parse(string json) { using var doc = JsonDocument.Parse(json); return BillingStatus.Parse(doc.RootElement); }
        const string finite = """{"tier":"pro","storageBytes":1500,"storageCapBytes":1000,"minutesUsed":12.5,"minutesCap":20,"isOverStorage":true,"isOverMinutes":false,"periodEnd":"2026-10-01T00:00:00Z"}""";
        var status = Parse(finite);
        if (!status.OverLimit || status.StoragePercent != 100 || status.MinutesPercent != 62.5 || status.PeriodEnd?.Year != 2026) throw new Exception("Finite usage or period decoding failed.");
        var unlimited = Parse(finite.Replace("\"pro\"", "\"unlimited\""));
        if (unlimited.OverLimit || !unlimited.UnlimitedStorage || !unlimited.UnlimitedMinutes || unlimited.MinutesPercent != 0) throw new Exception("Unlimited plan displayed a false quota violation.");
        var missingCaps = Parse("""{"tier":"free","storageBytes":0,"minutesUsed":0,"isOverStorage":true,"isOverMinutes":true}""");
        if (!missingCaps.UnlimitedStorage || !missingCaps.UnlimitedMinutes || missingCaps.OverLimit) throw new Exception("Missing limits did not match the macOS unlimited contract.");
        foreach (var date in new[] { "1790812800", "1790812800000" })
            if (Parse(finite.Replace("\"2026-10-01T00:00:00Z\"", date)).PeriodEnd != status.PeriodEnd) throw new Exception("Billing epoch units differ.");
        foreach (var invalid in new[] { "{}", finite.Replace("1500", "-1"), finite.Replace("12.5", "-1"), finite.Replace("12.5", "1e999"), finite.Replace("2026-10-01T00:00:00Z", "not a date") })
        {
            var rejected = false;
            try { Parse(invalid); } catch (Exception) { rejected = true; }
            if (!rejected) throw new Exception("Malformed usage was accepted.");
        }
        foreach (var url in new[] { "https://billing.stripe.com/p/session?secret=test", "https://example.test/plans" })
        {
            using var client = PortalClient(HttpStatusCode.OK, JsonSerializer.Serialize(new { url }));
            if ((await client.BillingPortalAsync()).AbsoluteUri != url) throw new Exception("Trusted portal was not returned.");
        }
        foreach (var url in new[] { "javascript:alert(1)", "file:///C:/test", "http://billing.stripe.com/session", "https://billing.stripe.com.evil.test/session", "https://user@billing.stripe.com/session", "https://billing.stripe.com:8443/session", "https://evil.test/session" })
        {
            using var client = PortalClient(HttpStatusCode.OK, JsonSerializer.Serialize(new { url }));
            var rejected = false;
            try { await client.BillingPortalAsync(); } catch (InvalidDataException) { rejected = true; }
            if (!rejected) throw new Exception("Untrusted billing portal was accepted.");
        }
        using (var client = PortalClient(HttpStatusCode.Conflict, "{}"))
            if ((await client.BillingPortalAsync()).AbsoluteUri != "https://example.test/plans") throw new Exception("Free account did not fall back to its plans page.");
        using (var client = PortalClient(HttpStatusCode.ServiceUnavailable, "{}"))
        {
            var rejected = false;
            try { await client.BillingPortalAsync(); } catch (CloudException e) when (e.Status == HttpStatusCode.ServiceUnavailable) { rejected = true; }
            if (!rejected) throw new Exception("Portal failure silently opened a page.");
        }
    }
    private static CloudClient PortalClient(HttpStatusCode status, string body) => new("https://example.test", "test-token", new Handler(status, body));
    private sealed class Handler(HttpStatusCode status, string body) : HttpMessageHandler
    {
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            if (request.Method != HttpMethod.Post || request.RequestUri?.AbsolutePath != "/api/billing/portal" || request.Headers.Authorization?.Scheme != "Bearer" ||
                await request.Content!.ReadAsStringAsync(cancellationToken) != "{}") throw new Exception("Portal request contract mismatch.");
            return new(status) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
        }
    }
}
