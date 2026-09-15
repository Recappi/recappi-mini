using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Recappi.Core;
using Recappi.Desktop;

internal static class CloudCompletionLayoutTests
{
    public static async Task RunAsync(string root, Dispatcher dispatcher)
    {
        var accountStore = new AccountStore(Path.Combine(root, "completion-account"));
        accountStore.Save(new("https://example.test", "completion-user", null, "test-token"));
        var delayRecording = false;
        var pending = new TaskCompletionSource<HttpResponseMessage>();
        var started = new TaskCompletionSource();
        var session = new AccountSession(accountStore, (origin, token) => new CloudClient(origin, token, new Handler(async request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path.EndsWith("get-session")) return Json("""{"user":{"id":"completion-user"},"session":{}}""");
            if (path.EndsWith("sign-out")) return Json("{}");
            if (path == "/api/recordings") return Json("""{"items":[],"nextCursor":null}""");
            if (path == "/api/recordings/cloud-complete")
            {
                if (delayRecording) { started.TrySetResult(); return await pending.Task; }
                return Json("""{"id":"cloud-complete","title":"A long native validation title which must not consume the transcript viewport","status":"ready","durationMs":9000}""");
            }
            if (path.EndsWith("/transcript")) return Json("""{"segments":[{"text":"The team will review the design tomorrow.","startMs":3000,"endMs":5500,"speaker":"Speaker 1"}],"summary":"Review the design tomorrow."}""");
            return Json("""{"items":[]}""");
        })));
        await session.RestoreAsync();
        var store = new LocalRecordingStore(Path.Combine(root, "completion-recordings"));
        var recording = store.Create("Local synthetic recording") with { State = RecordingState.Done };
        store.Save(recording);
        var entry = new ProcessingEntry(recording.Id, session.Snapshot.Account!.Partition, recording.Title, ProcessingStage.Completed, new("cloud-complete", 1, 1), UploadCompleted: true);
        var window = new CloudLibraryWindow(session, localLibrary: new LocalLibraryView(store, session), contentCache: new(Path.Combine(root, "completion-cache")), processingEntries: _ => [entry]) { ShowActivated = false };
        try
        {
            window.RefreshLocalRecordings(recording.Id); window.Show();
            await dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
            await window.RefreshProcessedRecordingAsync(entry);
            var list = (ListBox)window.FindName("Recordings");
            if (list.Items.Count != 1 || list.SelectedItem is not LibraryRecording { Local: not null, Cloud: not null } ||
                !((FrameworkElement)window.FindName("CopyActions")).IsVisible || !((FrameworkElement)window.FindName("LocalDetail")).IsVisible)
                throw new Exception("Completed upload did not expose its cloud copy without resetting the local selection.");
            ((Button)window.FindName("CloudCopyButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            var transcript = (TranscriptPanel)window.FindName("Transcript");
            for (var n = 0; n < 100 && transcript.Text.Length == 0; n++) await Task.Delay(20);
            if (transcript.Text.Length == 0) throw new Exception("Completed cloud transcript was not loaded.");
            var segments = (ListBox)transcript.FindName("Segments");
            var tabs = (TabControl)window.FindName("DetailTabs");
            var scroll = (ScrollViewer)window.FindName("DetailScroll");
            foreach (var size in new[] { new Size(1120, 760), new Size(800, 540) })
            {
                window.Width = size.Width; window.Height = size.Height; tabs.SelectedIndex = 0;
                await dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
                if (segments.ActualHeight < 60) throw new Exception($"Transcript viewport collapsed at {size}: {segments.ActualHeight}.");
                segments.BringIntoView();
                await dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
                var top = segments.TranslatePoint(new Point(0, 0), scroll).Y;
                if (top >= scroll.ActualHeight || top + segments.ActualHeight <= 0) throw new Exception("Transcript cannot be reached by detail scrolling.");
                tabs.SelectedIndex = 2;
                await dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
                var ask = (AskPanel)window.FindName("Ask");
                var conversation = (TextBox)ask.FindName("Conversation");
                if (conversation.ActualHeight < 60) throw new Exception($"Answer viewport collapsed at {size}: {conversation.ActualHeight}.");
                scroll.ScrollToEnd();
                await dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
                var footer = (Button)window.FindName("ExportButton");
                if (footer.TranslatePoint(new Point(0, footer.ActualHeight), scroll).Y > scroll.ActualHeight + 1)
                    throw new Exception("Cloud footer remains clipped after scrolling.");
            }
            delayRecording = true;
            var delayed = window.RefreshProcessedRecordingAsync(entry);
            await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
            await session.SignOutAsync();
            await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            if (list.Items.Cast<LibraryRecording>().Any(x => x.Cloud is not null)) throw new Exception("Sign-out did not clear cloud rows before the delayed response.");
            pending.SetResult(Json("""{"id":"cloud-complete","title":"Old private recording","status":"ready"}"""));
            await delayed;
            if (list.Items.Cast<LibraryRecording>().Any(x => x.Cloud is not null)) throw new Exception("Delayed completion restored a signed-out account's cloud row.");
        }
        finally { window.Close(); }
        Console.WriteLine("PASS upload completion merges cloud copy, ignores stale accounts and preserves usable transcript/answer viewports.");
    }
    private static HttpResponseMessage Json(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => send(request);
    }
}
