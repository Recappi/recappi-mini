using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using Recappi.Core;
using Recappi.Desktop;

internal static class BillingPanelTests
{
    public static async Task RunAsync(string root)
    {
        var store = new AccountStore(Path.Combine(root, "billing-account"));
        store.Save(new("https://example.test", "billing-a", "a@example.test", "test-token"));
        var user = "billing-a";
        var usageRequests = 0;
        var portalRequests = 0;
        var failUsage = false;
        var rejectUsage = false;
        TaskCompletionSource<HttpResponseMessage>? delayed = null;
        TaskCompletionSource<HttpResponseMessage>? delayedPortal = null;
        var session = new AccountSession(store, (origin, token) => new CloudClient(origin, token, new Handler(async request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path.EndsWith("get-session")) return Json(JsonSerializer.Serialize(new { session = new { }, user = new { id = user } }));
            if (path.EndsWith("sign-out")) return Json("{}");
            if (path.EndsWith("/portal")) { portalRequests++; return delayedPortal is { } portal ? await portal.Task : new(HttpStatusCode.Conflict); }
            if (path.EndsWith("/status"))
            {
                usageRequests++;
                if (rejectUsage) return new(HttpStatusCode.Unauthorized);
                if (delayed is { } pending) return await pending.Task;
                if (failUsage) return new(HttpStatusCode.ServiceUnavailable);
                return Usage(user == "billing-a" ? "pro" : "business");
            }
            throw new Exception("Unexpected billing test request.");
        })));
        await session.RestoreAsync();
        var opened = new List<Uri>();
        var panel = new BillingPanel(session, opened.Add);
        var window = new Window { Content = panel, ShowActivated = false, Width = 450, Height = 500 }; window.Show();
        var tier = (TextBlock)panel.FindName("Tier");
        var status = (TextBlock)panel.FindName("Status");
        var usage = (FrameworkElement)panel.FindName("Usage");
        var refresh = (Button)panel.FindName("RefreshButton");
        var manage = (Button)panel.FindName("ManageButton");
        await Until(() => tier.Text == "Pro" && refresh.IsEnabled);
        if (!usage.IsVisible || !((TextBlock)panel.FindName("Minutes")).Text.Contains("12.5") || usageRequests != 1) throw new Exception("Billing did not load and render once.");
        manage.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await Until(() => opened.Count == 1);
        if (opened[0].AbsoluteUri != "https://example.test/plans") throw new Exception("Free plan management did not open the trusted plans URL.");

        failUsage = true; refresh.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await Until(() => status.Text.Contains("失败") && refresh.IsEnabled);
        if (usage.IsVisible) throw new Exception("Failed refresh presented old usage as current.");
        failUsage = false; refresh.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await Until(() => tier.Text == "Pro" && refresh.IsEnabled);

        delayed = new(); var oldUsage = delayed; var count = usageRequests;
        refresh.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        refresh.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await Until(() => usageRequests == count + 1);
        if (refresh.IsEnabled) throw new Exception("Concurrent billing refresh remained enabled.");
        delayed = null; user = "billing-b"; store.Save(new("https://example.test", user, "b@example.test", "new-test-token"));
        await session.RestoreAsync(); await Until(() => tier.Text == "Business" && refresh.IsEnabled);
        oldUsage.SetResult(Usage("old-account")); await Task.Delay(40);
        if (tier.Text != "Business") throw new Exception("Delayed old account usage replaced the new account.");

        delayedPortal = new(); var oldPortal = delayedPortal;
        manage.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Until(() => portalRequests == 2);
        await session.SignOutAsync(); await Until(() => !usage.IsVisible && tier.Text.Length == 0);
        oldPortal.SetResult(Json("""{"url":"https://billing.stripe.com/p/session?secret=test"}""")); await Task.Delay(40);
        if (opened.Count != 1 || manage.IsEnabled || refresh.IsEnabled) throw new Exception("Sign-out retained billing actions or opened a delayed portal.");

        delayedPortal = null; store.Save(new("https://example.test", user, null, "new-test-token")); await session.RestoreAsync();
        await Until(() => tier.Text == "Business" && refresh.IsEnabled);
        delayed = new(); var hiddenResponse = delayed;
        refresh.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        window.Hide(); await Until(() => tier.Text.Length == 0);
        hiddenResponse.SetResult(Usage("hidden")); await Task.Delay(40);
        delayed = null; window.Show(); await Until(() => tier.Text == "Business" && refresh.IsEnabled);
        rejectUsage = true; refresh.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        // Account rejection is synchronous; the window update is dispatched afterwards.
        await Until(() => session.Snapshot.State == AccountState.Expired && status.Text.Contains("过期") && !usage.IsVisible && tier.Text.Length == 0);
        if (manage.IsEnabled || refresh.IsEnabled || !status.Text.Contains("过期")) throw new Exception("Billing authorization failure did not clear usage and require reconnection.");
        window.Close();
        Console.WriteLine("PASS native billing load/error/retry, quotas, duplicate suppression, account isolation, portal cancellation and hide/restore.");
    }
    public static async Task PreviewAsync(string root, bool dark = false)
    {
        DesktopTheme.Apply(dark ? "dark" : "light");
        var store = new AccountStore(Path.Combine(root, "billing-preview"));
        store.Save(new("https://example.test", "preview-user", "preview@example.test", "test-token"));
        var session = new AccountSession(store, (origin, token) => new CloudClient(origin, token, new Handler(request => Task.FromResult(
            request.RequestUri!.AbsolutePath.EndsWith("get-session")
                ? Json("""{"session":{},"user":{"id":"preview-user","email":"preview@example.test"}}""")
                : Json("""{"tier":"pro","storageBytes":1500000000,"storageCapBytes":10000000000,"minutesUsed":72.5,"minutesCap":120,"isOverStorage":false,"isOverMinutes":false,"periodEnd":"2026-10-01T00:00:00Z"}""")))));
        await session.RestoreAsync();
        var window = new AccountWindow(session, "https://example.test") { Title = "账号用量 · 测试数据", ShowActivated = false };
        window.Show();
        Console.WriteLine("Billing account window preview uses synthetic account and usage; no real service calls.");
        await Task.Delay(TimeSpan.FromSeconds(50)); window.Close();
    }
    private static async Task Until(Func<bool> predicate)
    {
        for (var attempt = 0; attempt < 150 && !predicate(); attempt++) await Task.Delay(20);
        if (!predicate()) throw new Exception("Billing UI did not reach the expected state.");
    }
    private static HttpResponseMessage Usage(string tier) => Json($$"""{"tier":"{{tier}}","storageBytes":1500,"storageCapBytes":10000,"minutesUsed":12.5,"minutesCap":60,"isOverStorage":false,"isOverMinutes":false}""");
    private static HttpResponseMessage Json(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> response) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => response(request);
    }
}
