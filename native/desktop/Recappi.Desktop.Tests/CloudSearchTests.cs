using System.IO;
using System.Net;
using System.Net.Http;
using System.Windows.Controls;
using System.Windows.Threading;
using Recappi.Core;
using Recappi.Desktop;

internal static class CloudSearchTests
{
    public static async Task RunAsync(string root, Dispatcher dispatcher)
    {
        var account = new CloudAccount("https://cache.test", "cache-user", null, "fixture");
        var store = new AccountStore(Path.Combine(root, "cache-account")); store.Save(account);
        var session = new AccountSession(store, (origin, token) => new CloudClient(origin, token, new Handler()));
        await session.RestoreAsync();
        var cache = new CloudContentCache(Path.Combine(root, "cache-ui"));
        cache.Save(account.Partition, new("cached", "Meeting", "ready", 5000), new("Plan release", "Review", "succeeded") { Segments = [new("Plan release", "Alice", 1000, 2000)] });
        var library = new CloudLibraryWindow(session, contentCache: cache) { ShowActivated = false };
        library.Show();
        await dispatcher.InvokeAsync(library.UpdateLayout, DispatcherPriority.ApplicationIdle);
        ((ListBox)library.FindName("Recordings")).SelectedIndex = 0;
        var transcript = (TranscriptPanel)library.FindName("Transcript");
        for (var attempt = 0; attempt < 100 && transcript.Text.Length == 0; attempt++) await Task.Delay(20);
        if (transcript.Text != "Plan release" || !((TextBlock)library.FindName("Status")).Text.Contains("缓存")) throw new Exception("Network failure did not show identified cached content.");
        var search = new CloudSearchWindow(cache, session, account.Partition, _ => { }) { Owner = library, ShowActivated = false };
        search.Show();
        await dispatcher.InvokeAsync(search.UpdateLayout, DispatcherPriority.ApplicationIdle);
        ((TextBox)search.FindName("Query")).Text = "release";
        await search.SearchAsync();
        if (((ListBox)search.FindName("Results")).Items.Count != 1) throw new Exception("Native cache search did not render hit.");
        await session.SignOutAsync();
        await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        if (search.IsVisible || transcript.Text.Length != 0) throw new Exception("Sign-out retained search or cached transcript.");
        library.Close();
        store.Save(account);
        var networkCalls = 0;
        var offline = new AccountSession(store, (origin, token) => new CloudClient(origin, token, new OfflineHandler(() => networkCalls++)));
        await offline.RestoreAsync();
        if (offline.Snapshot.State != AccountState.Offline) throw new Exception("Offline restore did not preserve the saved account.");
        var offlineLibrary = new CloudLibraryWindow(offline, contentCache: cache) { ShowActivated = false };
        offlineLibrary.Show();
        if (((TextBlock)offlineLibrary.FindName("AccountIdentity")).Text != "cache-user" || !((TextBlock)offlineLibrary.FindName("AccountConnection")).Text.Contains("离线")) throw new Exception("Offline library header hid account identity or connection state.");
        var offlineList = (ListBox)offlineLibrary.FindName("Recordings");
        for (var attempt = 0; attempt < 100 && offlineList.Items.Count == 0; attempt++) await Task.Delay(20);
        if (offlineList.Items.Count != 1) throw new Exception("Offline startup did not list cached recordings.");
        offlineList.SelectedIndex = 0;
        var offlineTranscript = (TranscriptPanel)offlineLibrary.FindName("Transcript");
        for (var attempt = 0; attempt < 100 && offlineTranscript.Text.Length == 0; attempt++) await Task.Delay(20);
        if (offlineTranscript.Text != "Plan release" || networkCalls != 1 || ((Button)offlineLibrary.FindName("DeleteButton")).IsEnabled || ((Button)offlineLibrary.FindName("LoadAudioButton")).IsEnabled)
            throw new Exception("Offline detail issued cloud work or enabled unavailable actions.");
        offlineLibrary.Close();
        Console.WriteLine("PASS native cache search, labeled offline fallback and sign-out clears search/detail.");
    }
    private sealed class OfflineHandler(Action called) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        { called(); throw new HttpRequestException("Offline fixture"); }
    }
    private sealed class Handler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path.EndsWith("/transcript")) throw new HttpRequestException("Fixture offline");
            var body = path.EndsWith("get-session") ? """{"session":{},"user":{"id":"cache-user"}}""" : path.EndsWith("sign-out") ? "{}" : """{"items":[{"id":"cached","title":"Meeting","status":"ready"}]}""";
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body, System.Text.Encoding.UTF8, "application/json") });
        }
    }
}
