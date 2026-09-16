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

internal static class ReviewRequestRecoveryTests
{
    public static async Task RunAsync(string root, Dispatcher dispatcher)
    {
        foreach (var action in new[] { "TranscribeButton", "SummaryButton", "RetryButton" })
        {
            var store = new AccountStore(Path.Combine(root, "review-recovery-" + action));
            var account = new CloudAccount("https://example.test", "recovery-user", null, "test-token");
            store.Save(account);
            var posts = 0;
            var loseResponse = true;
            var failJobs = false;
            var failTranscript = false;
            var jobStatus = "failed";
            var summaryStatus = "succeeded";
            var session = new AccountSession(store, (origin, token) => new CloudClient(origin, token, new Handler(request =>
            {
                var path = request.RequestUri!.AbsolutePath;
                if (path.EndsWith("get-session")) return Json("""{"session":{},"user":{"id":"recovery-user"}}""");
                if (request.Method == HttpMethod.Post)
                {
                    posts++;
                    if (path.EndsWith("/summarize")) summaryStatus = "queued";
                    else jobStatus = "queued";
                    if (loseResponse) throw new HttpRequestException("Response lost after accepting the request.");
                    return Json("{}");
                }
                if (path.EndsWith("/jobs"))
                {
                    if (failJobs) throw new HttpRequestException("History temporarily unavailable.");
                    return Json(JsonSerializer.Serialize(new { items = new[] { new {
                        id = "job", status = jobStatus,
                        chunkProgress = new { failedChunks = new[] { new { retryable = true } } }
                    } } }));
                }
                if (path.EndsWith("/transcript"))
                {
                    if (failTranscript) throw new HttpRequestException("Summary status temporarily unavailable.");
                    return Json(JsonSerializer.Serialize(new { id = "transcript", text = "Text", summaryStatus }));
                }
                throw new Exception("Unexpected recovery route: " + path);
            })));
            await session.RestoreAsync();
            var panel = new ReviewPanel { Confirm = _ => true };
            var window = new Window { Content = panel, ShowActivated = false };
            window.Show();
            try
            {
                await panel.SelectAsync(session, account, new("r1", "Meeting", "ready", 1000));
                panel.UpdateSummaryStatus("succeeded");
                ((ComboBox)panel.FindName("Jobs")).SelectedIndex = 0;
                if (!Enabled(action)) throw new Exception("Recovery fixture action was not available: " + action);
                Click(action); await Idle();
                AssertBlocked();
                foreach (var button in new[] { "TranscribeButton", "SummaryButton", "RetryButton" }) Click(button);
                await Idle();
                if (posts != 1) throw new Exception("Unconfirmed request allowed another POST: " + action);
                failJobs = true; Click("RefreshButton"); await Idle(); AssertBlocked();
                failJobs = false;
                if (action == "SummaryButton")
                {
                    failTranscript = true; Click("RefreshButton"); await Idle(); AssertBlocked();
                    failTranscript = false;
                }
                Click("RefreshButton"); await Idle();
                if (Enabled(action)) throw new Exception("Accepted active work became repeatable after reconciliation: " + action);
                if (posts != 1) throw new Exception("Refresh resubmitted an unconfirmed request.");
                jobStatus = "succeeded"; summaryStatus = "succeeded";
                Click("RefreshButton"); await Idle();
                if (!Enabled("TranscribeButton") || !Enabled("SummaryButton"))
                    throw new Exception("Completed work did not restore explicit processing actions: " + action);
                loseResponse = false; Click("TranscribeButton"); await Idle();
                if (posts != 2) throw new Exception("Fresh explicit processing did not recover after reconciliation.");
            }
            finally { panel.Clear(); window.Close(); }
            bool Enabled(string name) => ((Button)panel.FindName(name)).IsEnabled;
            void Click(string name) => ((Button)panel.FindName(name)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            async Task Idle() => await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            void AssertBlocked()
            {
                if (new[] { "TranscribeButton", "SummaryButton", "RetryButton" }.Any(Enabled) || !Enabled("RefreshButton"))
                    throw new Exception("Unconfirmed processing must require refresh before another mutation: " + action);
            }
        }
        Console.WriteLine("PASS lost cloud processing responses require successful reconciliation; failed refreshes stay blocked and active work is not resubmitted.");
    }
    private static HttpResponseMessage Json(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) => Task.FromResult(send(request));
    }
}
