using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using Recappi.Core;
using Recappi.Desktop;

internal static class UpdatePanelTests
{
    public static async Task RunAsync(string root)
    {
        var payload = new byte[] { 1, 2, 3, 4 };
        var hash = Convert.ToHexString(SHA256.HashData(payload));
        var corrupt = false;
        var failCheck = false;
        var requests = 0;
        var panel = new UpdatePanel(() => new DesktopUpdates(new Handler((request, _) =>
        {
            requests++;
            if (request.RequestUri!.Host == "api.github.com")
            {
                if (failCheck) return Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable));
                var feed = new[] { new { tag_name = "v2.0.0", draft = false, prerelease = false, assets = new[] { new { name = "Recappi-Mini-2.0.0-win-x64.zip", state = "uploaded", size = payload.Length, digest = "sha256:" + hash,
                    browser_download_url = "https://github.com/Recappi/recappi-mini/releases/download/v2.0.0/Recappi-Mini-2.0.0-win-x64.zip" } } } };
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(feed)) });
            }
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(corrupt ? [4, 3, 2, 1] : payload) });
        })), "1.0.0", "win-x64");
        var window = new Window { Content = panel, Width = 570, Height = 340, ShowActivated = false }; window.Show(); window.UpdateLayout();
        Button Button(string name) => (Button)panel.FindName(name);
        string Status() => ((TextBlock)panel.FindName("UpdateStatus")).Text;
        if (requests != 0 || Button("DownloadButton").IsEnabled) throw new Exception("Update panel connected without a user check.");
        failCheck = true; await panel.CheckAsync();
        if (Button("DownloadButton").IsEnabled || !Button("CheckButton").IsEnabled || !Status().Contains("无法检查")) throw new Exception("Update check failure did not recover UI.");
        failCheck = false; await panel.CheckAsync();
        if (!Button("DownloadButton").IsEnabled || !Status().Contains("2.0.0")) throw new Exception("Discovered update missing from UI.");
        var destination = Path.Combine(root, "ui-update.zip");
        File.WriteAllText(destination, "existing");
        corrupt = true; await panel.DownloadAsync(destination);
        if (File.ReadAllText(destination) != "existing" || !Status().Contains("失败") || !Button("DownloadButton").IsEnabled) throw new Exception("Failed update damaged destination or blocked retry.");
        corrupt = false; await panel.DownloadAsync(destination);
        if (!File.ReadAllBytes(destination).SequenceEqual(payload) || !Status().Contains("尚未安装") || Button("OpenPackageButton").Visibility != Visibility.Visible)
            throw new Exception("Verified download UI falsely claims installation or omitted saved output.");
        window.Close();
        var started = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var canceled = false;
        var waiting = new UpdatePanel(() => new DesktopUpdates(new Handler(async (_, token) =>
        {
            started.TrySetResult();
            try { await Task.Delay(Timeout.Infinite, token); }
            catch (OperationCanceledException) { canceled = true; throw; }
            return new HttpResponseMessage(HttpStatusCode.OK);
        })), "1.0.0", "win-x64");
        var waitingWindow = new Window { Content = waiting, ShowActivated = false }; waitingWindow.Show();
        var pending = waiting.CheckAsync(); await started.Task.WaitAsync(TimeSpan.FromSeconds(3));
        waitingWindow.Close(); await pending.WaitAsync(TimeSpan.FromSeconds(3));
        if (!canceled) throw new Exception("Closing settings left update request running.");
        Console.WriteLine("PASS native update panel explicit check, failure/retry, verified download and close cancellation.");
    }
    private sealed class Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => send(request, token);
    }
}
