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
        await VerifyConfirmationIsolationAsync(root, dispatcher);
        Console.WriteLine("PASS native review history, confirmation cancellation, retry, summary, duplicate submit prevention and recording isolation.");
        void Click(string name) => ((Button)panel.FindName(name)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        async Task Idle() => await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
    }
    private static async Task VerifyConfirmationIsolationAsync(string root, Dispatcher dispatcher)
    {
        var store = new AccountStore(Path.Combine(root, "review-confirmation-account"));
        var account = new CloudAccount("https://example.test", "confirmation-user", null, "test-token");
        store.Save(account);
        var mutations = new List<string>();
        var activeJob = false;
        var session = new AccountSession(store, (origin, token) => new CloudClient(origin, token, new Handler(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path.EndsWith("get-session")) return Task.FromResult(Json("""{"session":{},"user":{"id":"confirmation-user"}}"""));
            if (path.EndsWith("sign-out")) return Task.FromResult(Json("{}"));
            if (path.EndsWith("/jobs")) return Task.FromResult(Json(activeJob ? """{"items":[{"id":"new-job","status":"queued"}]}""" : """{"items":[]}"""));
            if (request.Method == HttpMethod.Post)
            {
                mutations.Add(path);
                return Task.FromResult(Json("{}"));
            }
            if (path.EndsWith("/transcript")) return Task.FromResult(Json("""{"id":"t","text":"Transcript","summaryStatus":"succeeded"}"""));
            throw new Exception("Unexpected confirmation route: " + path);
        })));
        await session.RestoreAsync();
        var panel = new ReviewPanel();
        var window = new Window { Content = panel, ShowActivated = false };
        window.Show();
        try
        {
            foreach (var button in new[] { "TranscribeButton", "SummaryButton" })
            {
                await panel.SelectAsync(session, account, new("r1", "Original meeting", "ready", 1000));
                panel.UpdateSummaryStatus("succeeded");
                panel.Confirm = _ =>
                {
                    // MessageBox runs a nested dispatcher: selection/account events can
                    // finish while confirmation is open, before it returns Yes.
                    DuringConfirmation(() => panel.SelectAsync(session, account, new("r2", "Another meeting", "ready", 1000)));
                    return true;
                };
                ((Button)panel.FindName(button)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                if (mutations.Count != 0) throw new Exception(button + " submitted to a changed recording after confirmation: " + string.Join(", ", mutations));
            }
            foreach (var button in new[] { "TranscribeButton", "SummaryButton" })
            {
                store.Save(account); await session.RestoreAsync();
                await panel.SelectAsync(session, account, new("r1", "Original meeting", "ready", 1000));
                panel.UpdateSummaryStatus("succeeded");
                panel.Confirm = _ => { DuringConfirmation(() => session.SignOutAsync()); return true; };
                ((Button)panel.FindName(button)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                if (mutations.Count != 0) throw new Exception(button + " submitted after sign-out during confirmation.");
            }
            store.Save(account); await session.RestoreAsync();
            foreach (var button in new[] { "TranscribeButton", "SummaryButton" })
            {
                activeJob = false;
                await panel.SelectAsync(session, account, new("r1", "Original meeting", "ready", 1000));
                panel.UpdateSummaryStatus("succeeded");
                panel.Confirm = _ =>
                {
                    activeJob = true;
                    DuringConfirmation(async () =>
                    {
                        ((Button)panel.FindName("RefreshButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                        await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                    });
                    if (((Button)panel.FindName(button)).IsEnabled) throw new Exception("Active job did not invalidate the pending action.");
                    return true;
                };
                ((Button)panel.FindName(button)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                if (mutations.Count != 0) throw new Exception(button + " ignored refreshed active work during confirmation.");
            }
            activeJob = false;
            await panel.SelectAsync(session, account, new("r1", "Original meeting", "ready", 1000));
            panel.UpdateSummaryStatus("succeeded"); panel.Confirm = _ => true;
            foreach (var button in new[] { "TranscribeButton", "SummaryButton" })
            {
                ((Button)panel.FindName(button)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            }
            if (!mutations.SequenceEqual(new[] { "/api/recordings/r1/transcribe", "/api/recordings/r1/summarize" }))
                throw new Exception("Valid confirmation failed to recover after invalidated actions.");
            Console.WriteLine("PASS review confirmation rejects changed recordings, sign-out and newly active jobs, then permits valid requests.");
        }
        finally { panel.Clear(); window.Close(); }
        void DuringConfirmation(Func<Task> change)
        {
            var frame = new DispatcherFrame();
            Exception? failure = null;
            dispatcher.BeginInvoke(new Action(async () =>
            {
                try { await change(); }
                catch (Exception error) { failure = error; }
                finally { frame.Continue = false; }
            }));
            Dispatcher.PushFrame(frame);
            if (failure is not null) throw failure;
        }
    }
    private static HttpResponseMessage Json(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) => send(request);
    }
}
