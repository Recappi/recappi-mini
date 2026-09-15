using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Recappi.Core;
using Recappi.Desktop;

internal static class ReviewPanelTests
{
    public static async Task RunAsync(string root, Dispatcher dispatcher)
    {
        var store = new AccountStore(Path.Combine(root, "review-account"));
        var account = new CloudAccount("https://example.test", "review-user", null, "test-token"); store.Save(account);
        var retries = 0; var summaries = 0; var transcriptions = 0; var jobStatus = "failed";
        var started = new TaskCompletionSource(); var pending = new TaskCompletionSource<HttpResponseMessage>();
        var session = new AccountSession(store, (origin, token) => new CloudClient(origin, token, new Handler(async request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path.EndsWith("get-session")) return Json("""{"session":{},"user":{"id":"review-user"}}""");
            if (path.EndsWith("/r2/jobs")) return Json("""{"items":[]}""");
            if (path.EndsWith("/jobs")) return Json(JsonSerializer.Serialize(new { items = new object[] {
                new { id = "old", status = "succeeded", transcriptId = "t-old", enqueuedAt = 1000 },
                new { id = "retry", status = jobStatus, transcriptId = "t-new", chunkProgress = new { percent = 50, failedChunks = new[] { new { retryable = true } } } }
            } }));
            if (path.EndsWith("retry-failed-chunks")) { retries++; jobStatus = "queued"; return Json("""{"jobId":"retry","status":"queued"}"""); }
            if (path.EndsWith("summarize")) { summaries++; return Json("""{"transcriptId":"t-new","summaryStatus":"queued"}"""); }
            if (path.EndsWith("/transcript")) return Json("""{"id":"t-new","text":"Transcript","summary":"Updated","summaryStatus":"succeeded"}""");
            if (path.EndsWith("/transcribe"))
            {
                transcriptions++;
                using var body = JsonDocument.Parse(await request.Content!.ReadAsStringAsync());
                if (!body.RootElement.GetProperty("force").GetBoolean() || body.RootElement.GetProperty("language").GetString() != "zh") throw new Exception("Retranscription options lost.");
                started.TrySetResult(); return await pending.Task;
            }
            throw new Exception("Unexpected review route.");
        })));
        await session.RestoreAsync();
        var panel = new ReviewPanel { Confirm = _ => true, ProcessingOptions = () => new("zh", "test context") };
        var window = new Window { Content = panel, ShowActivated = false }; window.Show();
        string? selectedVersion = null; panel.VersionSelected += id => selectedVersion = id;
        await panel.SelectAsync(session, account, new("r1", "Meeting", "ready", 1000));
        var jobs = (ComboBox)panel.FindName("Jobs"); jobs.SelectedIndex = 0;
        if (selectedVersion != "old") throw new Exception("History selection lost job ID.");
        jobs.SelectedIndex = 1;
        Click("RetryButton"); await Idle();
        if (retries != 1 || ((Button)panel.FindName("TranscribeButton")).IsEnabled) throw new Exception("Active retry did not block duplicate transcription.");
        jobStatus = "succeeded"; Click("RefreshButton"); await Idle();
        panel.UpdateSummaryStatus("succeeded"); panel.Confirm = _ => false;
        Click("SummaryButton"); if (summaries != 0) throw new Exception("Cancelled confirmation sent a request.");
        panel.Confirm = _ => true; Click("SummaryButton"); await Idle();
        if (summaries != 1 || selectedVersion != "retry") throw new Exception("Summary refresh overwrote historical selection.");
        Click("TranscribeButton"); await started.Task.WaitAsync(TimeSpan.FromSeconds(3)); Click("TranscribeButton");
        if (transcriptions != 1) throw new Exception("Busy processing allowed duplicate POST.");
        await panel.SelectAsync(session, account, new("r2", "Another meeting", "ready", 1000));
        pending.SetResult(Json("""{"jobId":"new","status":"queued"}""")); await Idle();
        if (jobs.Items.Count != 0) throw new Exception("Old processing response crossed recording selection.");
        panel.Clear(); window.Close();
        Console.WriteLine("PASS native review history, confirmation cancellation, retry, summary, duplicate submit prevention and recording isolation.");
        void Click(string name) => ((Button)panel.FindName(name)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        async Task Idle() => await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
    }
    private static HttpResponseMessage Json(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) => send(request);
    }
}
