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

internal static class CloudLibraryTests
{
    public static async Task RunAsync(string root, Dispatcher dispatcher)
    {
        CheckDateCompatibility();
        var accountStore = new AccountStore(Path.Combine(root, "account"));
        accountStore.Save(new("https://example.test", "user-a", null, "test-token"));
        var pendingTranscript = new TaskCompletionSource<HttpResponseMessage>();
        var transcriptStarted = new TaskCompletionSource();
        var calendarDay = DateTime.Today;
        var cloudCreatedAt = new DateTimeOffset(calendarDay.AddHours(12)).ToUnixTimeMilliseconds();
        var rejectAuthentication = false;
        var session = new AccountSession(accountStore, (origin, token) => new CloudClient(origin, token, new Handler(async request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (rejectAuthentication) return new(HttpStatusCode.Unauthorized);
            if (path.EndsWith("get-session")) return Json("""{"session":{},"user":{"id":"user-a"}}""");
            if (path.EndsWith("sign-out")) return Json("{}");
            if (path.EndsWith("/transcript")) { transcriptStarted.TrySetResult(); return await pendingTranscript.Task; }
            return Json($$"""{"items":[{"id":"r1","title":"Account A meeting","status":"ready","durationMs":null,"createdAt":{{cloudCreatedAt}}}],"nextCursor":null}""");
        })));
        await session.RestoreAsync();
        var localStore = new LocalRecordingStore(Path.Combine(root, "unified-library"));
        var localRecording = localStore.Create("Local recording remains available");
        var localView = new LocalLibraryView(localStore, session);
        var cache = new CloudContentCache(Path.Combine(root, "unified-search-cache"));
        cache.Save(session.Snapshot.Account!.Partition, new("cached-r", "Cached recording", "ready", 1000), new("Transcript search words", "Summary", "completed"));
        cache.Save(new CloudAccount("https://example.test", "user-b", null, "test-token").Partition, new("other-r", "Other account recording", "ready", 1000), new("Private", "", "completed"));
        calendarDay = localRecording.StartedAt.LocalDateTime.Date;
        IReadOnlyList<ProcessingEntry> links = [];
        var accountOpens = 0;
        var window = new CloudLibraryWindow(session, localLibrary: localView, contentCache: cache, localToday: () => calendarDay, processingEntries: _ => links, showAccount: () => accountOpens++) { ShowActivated = false };
        window.RefreshLocalRecordings(localRecording.Id);
        window.Show();
        await dispatcher.InvokeAsync(() => window.UpdateLayout(), DispatcherPriority.ApplicationIdle);
        var list = (ListBox)window.FindName("Recordings");
        if (((TextBlock)window.FindName("AccountIdentity")).Text != "user-a" || !((TextBlock)window.FindName("AccountConnection")).Text.Contains("已连接")) throw new Exception("Library header did not identify the current connected account.");
        ((Button)window.FindName("AccountButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (accountOpens != 1) throw new Exception("Library account header did not open account management.");
        if (list.Items.Count != 2) throw new Exception("Combined local and cloud list was not rendered.");
        var localList = list;
        var restoredRecording = 0;
        window.SetCurrentMeeting(new(RecordingState.Recording, localRecording with { DurationMs = 12000 }), () => restoredRecording++);
        if (!((FrameworkElement)window.FindName("CurrentMeeting")).IsVisible || !((TextBlock)window.FindName("CurrentMeetingLabel")).Text.Contains("00:00:12")) throw new Exception("Active meeting entry or elapsed time missing.");
        ((Button)window.FindName("CurrentMeetingButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (restoredRecording != 1) throw new Exception("Current meeting did not restore the recorder.");
        window.SetCurrentMeeting(new(RecordingState.Done, localRecording), () => restoredRecording++);
        ((Button)window.FindName("CurrentMeetingButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (((FrameworkElement)window.FindName("CurrentMeeting")).IsVisible || restoredRecording != 1) throw new Exception("Completed meeting retained an active recording action.");
        if ((localList.SelectedItem as LibraryRecording)?.Local?.Id != localRecording.Id || !((FrameworkElement)window.FindName("LocalDetail")).IsVisible)
            throw new Exception("Unified library did not select the requested local entry.");
        string LocalGroup() => ((System.Windows.Data.CollectionViewGroup)localList.Items.Groups![0]).Name.ToString()!;
        if (LocalGroup() != "今天") throw new Exception("Initial calendar group missing.");
        calendarDay = calendarDay.AddDays(1);
        window.RefreshDateGroups();
        if (((System.Windows.Data.CollectionViewGroup)list.Items.Groups![0]).Name.ToString() != "昨天") throw new Exception("Cloud calendar group did not refresh with the local list.");
        if (LocalGroup() != "昨天" || (localList.SelectedItem as LibraryRecording)?.Local?.Id != localRecording.Id || !((FrameworkElement)window.FindName("LocalDetail")).IsVisible)
            throw new Exception($"Midnight regrouping failed: group={LocalGroup()}, selected={(localList.SelectedItem as LibraryRecording)?.Local?.Id}, visible={((FrameworkElement)window.FindName("LocalDetail")).IsVisible}.");
        calendarDay = calendarDay.AddDays(2);
        window.RefreshDateGroups();
        if (LocalGroup() != localRecording.StartedAt.LocalDateTime.ToString("yyyy-MM-dd")) throw new Exception("Multi-day resume did not refresh calendar labels.");
        calendarDay = calendarDay.AddDays(-3);
        window.RefreshDateGroups();
        if (LocalGroup() != "今天") throw new Exception("Backward calendar change retained a stale group.");
        var query = (TextBox)window.FindName("LibraryQuery");
        var searchResults = (ListBox)window.FindName("LibrarySearchResults");
        query.Text = "recording"; await window.SearchLibraryAsync();
        if (searchResults.Items.Count != 2 || searchResults.Items.Cast<LibrarySearchEntry>().Any(x => x.Title.Contains("Other account"))) throw new Exception("Unified search omitted local/cache results or leaked another account.");
        query.Text = "absent-query"; var superseded = window.SearchLibraryAsync();
        query.Text = "recording"; await window.SearchLibraryAsync(); await superseded;
        if (searchResults.Items.Count != 2) throw new Exception("A superseded search overwrote current results.");
        query.Text = ""; await window.SearchLibraryAsync();
        links = [new(localRecording.Id, session.Snapshot.Account!.Partition, localRecording.Title, ProcessingStage.Completed, new("r1", 1, 1), UploadCompleted: true)];
        window.RebuildLibrary();
        if (list.Items.Count != 1 || list.SelectedItem is not LibraryRecording { Local: not null, Cloud: not null } || !((FrameworkElement)window.FindName("CopyActions")).IsVisible)
            throw new Exception("A confirmed upload did not merge copies and preserve the selected local recording.");
        cache.Save(session.Snapshot.Account!.Partition, new("r1", "Account A meeting", "ready", 1000), new("recording transcript", "Summary", "completed"));
        query.Text = "recording"; await window.SearchLibraryAsync();
        if (searchResults.Items.Count != 2 || searchResults.Items.Cast<LibrarySearchEntry>().Count(x => x.Cloud?.Recording.Id == "r1") != 1 || searchResults.Items.Cast<LibrarySearchEntry>().Any(x => x.LocalId == localRecording.Id))
            throw new Exception("Search displayed both copies of a linked recording.");
        query.Text = ""; await window.SearchLibraryAsync();
        ((Button)window.FindName("CloudCopyButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await transcriptStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        if (((FrameworkElement)window.FindName("LocalDetail")).IsVisible || !((FrameworkElement)window.FindName("CloudDetail")).IsVisible)
            throw new Exception("Selecting cloud recording did not switch the shared detail pane.");
        ((Button)window.FindName("LocalCopyButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (!((FrameworkElement)window.FindName("LocalDetail")).IsVisible || ((Button)window.FindName("DeleteButton")).IsEnabled) throw new Exception("Local copy did not restore local detail and disable cloud actions.");
        query.Text = "recording"; await window.SearchLibraryAsync();
        searchResults.SelectedItem = searchResults.Items.Cast<LibrarySearchEntry>().Single(x => x.Cloud?.Recording.Id == "r1");
        if (list.Items.Count != 1 || !((FrameworkElement)window.FindName("CloudDetail")).IsVisible) throw new Exception("Merged search hit did not open cloud content on the same library row.");
        rejectAuthentication = true;
        using (var rejectedClient = session.Client(session.Snapshot.Account!))
        {
            try { await rejectedClient.BillingAsync(); throw new Exception("Expected auth rejection."); }
            catch (CloudException error) when (error.Status == HttpStatusCode.Unauthorized) { }
        }
        await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        if (session.Snapshot.State != AccountState.Expired || !((TextBlock)window.FindName("AccountConnection")).Text.Contains("过期") || list.Items.Cast<LibraryRecording>().Any(x => x.Cloud is not null) || !((FrameworkElement)window.FindName("LocalDetail")).IsVisible)
            throw new Exception("Expired account retained cloud rows or hid the local copy.");
        await session.SignOutAsync();
        await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        pendingTranscript.SetResult(Json("""{"id":"t1","text":"Account A private transcript"}"""));
        await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        if (list.Items.Cast<LibraryRecording>().Any(x => x.Cloud is not null) || ((TranscriptPanel)window.FindName("Transcript")).Text.Length != 0)
            throw new Exception("Old account data remained after sign out.");
        if (!((Button)window.FindName("RefreshButton")).IsEnabled) throw new Exception("Refresh remained disabled after cancellation.");
        if (((TextBlock)window.FindName("AccountIdentity")).Text != "尚未登录" || ((Button)window.FindName("AccountButton")).ToolTip.ToString()!.Contains("user-a")) throw new Exception("Signed-out header retained the prior account identity.");
        if (localList.Items.Count != 1 || !((FrameworkElement)window.FindName("LocalDetail")).IsVisible) throw new Exception("Signing out hid local recordings.");
        query.Text = "recording"; await window.SearchLibraryAsync();
        if (searchResults.Items.Count != 1 || ((LibrarySearchEntry)searchResults.Items[0]).LocalId != localRecording.Id) throw new Exception("Signed-out search lost local data or retained cloud data.");
        window.Close();

        using var document = JsonDocument.Parse("""{"segmentsJson":"[{\"text\":\"Legacy segment\"}]","text":"fallback","summaryJson":"{\"tldr\":\"Overview\",\"actionItems\":[{\"who\":\"Alex\",\"what\":\"Ship\"}]}"}""");
        var transcript = CloudTranscript.Parse(document.RootElement);
        if (transcript.Text != "Legacy segment" || !transcript.Summary.Contains("Alex：Ship") || !transcript.Summary.Contains("Overview")) throw new Exception("Legacy transcript/summary fields were lost.");
        Console.WriteLine("PASS native cloud list, legacy transcript/summary decoding, sign-out clears data and rejects delayed responses.");
    }
    private static void CheckDateCompatibility()
    {
        var expected = DateTimeOffset.FromUnixTimeMilliseconds(1700000000000);
        foreach (var raw in new[] { "1700000000000", "1700000000", "\"1700000000000\"", "\"2023-11-14T22:13:20Z\"" })
        {
            using var json = JsonDocument.Parse("{\"id\":\"dated\",\"createdAt\":" + raw + "}");
            if (CloudRecordingItem.Parse(json.RootElement).CreatedAt != expected) throw new Exception("Cloud creation time seconds/milliseconds/string compatibility failed.");
        }
        foreach (var raw in new[] { "null", "\"invalid\"", "1e300", "{}" })
        {
            using var json = JsonDocument.Parse("{\"id\":\"unknown\",\"createdAt\":" + raw + "}");
            if (CloudRecordingItem.Parse(json.RootElement).CreatedAt is not null) throw new Exception("Invalid creation time fabricated a date.");
        }
        var today = DateTime.Today;
        if (RecordingDateGroups.Label(new DateTimeOffset(today.AddHours(12)), today) != "今天" || RecordingDateGroups.Label(new DateTimeOffset(today.AddMinutes(-1)), today) != "昨天" || RecordingDateGroups.Label(null, today) != "日期未知")
            throw new Exception("Local calendar grouping boundaries failed.");
        var dated = new CloudRecordingItem("dated", "Dated", "ready", 0) { CreatedAt = expected };
        var unknown = new CloudRecordingItem("unknown", "Unknown", "ready", 0);
        var view = RecordingDateGroups.Create(new[] { unknown, dated }, nameof(CloudRecordingItem.CreatedAt));
        if (view.Cast<CloudRecordingItem>().First().Id != "dated" || view.Groups?.Count != 2) throw new Exception("Date grouping did not sort known dates ahead of unknown dates.");
        var roundTrip = JsonSerializer.Deserialize<CloudRecordingItem>(JsonSerializer.Serialize(dated));
        if (roundTrip?.CreatedAt != expected) throw new Exception("Cached recording serialization lost creation time.");
    }
    private static HttpResponseMessage Json(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => send(request);
    }
}
