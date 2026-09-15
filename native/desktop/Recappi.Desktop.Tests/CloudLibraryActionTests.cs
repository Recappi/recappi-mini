using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Recappi.Core;
using Recappi.Desktop;

internal static class CloudLibraryActionTests
{
    public static async Task RunAsync(string root, Dispatcher dispatcher)
    {
        var wave = Path.Combine(root, "cloud-audio.wav");
        using (var writer = new PcmWaveWriter(wave)) writer.Append(new float[48000 * 3]);
        var accountStore = new AccountStore(Path.Combine(root, "cloud-action-account"));
        accountStore.Save(new("https://example.test", "actions", null, "test-token"));
        var deletes = 0; var failDelete = true; var detached = "";
        var session = new AccountSession(accountStore, (origin, token) => new CloudClient(origin, token, new Handler(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path.EndsWith("get-session")) return Json("""{"session":{},"user":{"id":"actions"}}""");
            if (request.Method == HttpMethod.Delete) { deletes++; return failDelete ? new(HttpStatusCode.ServiceUnavailable) : Json("{}"); }
            if (path.EndsWith("/audio")) { var content = new ByteArrayContent(File.ReadAllBytes(wave)); content.Headers.ContentType = new("audio/wav"); return new(HttpStatusCode.OK) { Content = content }; }
            if (path.EndsWith("/jobs")) return Json("""{"items":[]}""");
            if (path.EndsWith("/ask-thread")) return Json("""{"messages":[]}""");
            if (path.EndsWith("/ask-suggestions")) return Json("""{"suggestions":[]}""");
            if (path.EndsWith("/transcript")) return Json("""{"id":"t","text":"Current transcript","summaryStatus":"succeeded"}""");
            return Json("""{"items":[{"id":"r1","title":"First audio","status":"ready"},{"id":"r2","title":"Second audio","status":"ready"}]}""");
        })));
        await session.RestoreAsync();
        var window = new CloudLibraryWindow(session, remoteDeleted: (_, id) => { detached = id; return Task.CompletedTask; }) { ShowActivated = false, ConfirmDelete = _ => false };
        window.Show(); await Idle();
        var list = (ListBox)window.FindName("Recordings"); list.SelectedIndex = 0; await Idle();
        ((Button)window.FindName("LoadAudioButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        var player = (AudioPlayer)window.FindName("Player"); var play = (Button)player.FindName("PlayButton");
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (!play.IsEnabled) await Task.Delay(25, deadline.Token);
        play.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        list.SelectedIndex = 1; await Idle();
        if ((string)play.Content != "暂停" || !((TextBlock)window.FindName("PlaybackLabel")).Text.Contains("First audio")) throw new Exception("Changing details interrupted or mislabelled the original playback.");
        var delete = (Button)window.FindName("DeleteButton"); delete.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (deletes != 0) throw new Exception("Cancelled deletion contacted server.");
        window.ConfirmDelete = _ => true; delete.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Idle();
        if (list.Items.Count != 2 || detached.Length != 0) throw new Exception("Failed deletion removed local UI state.");
        failDelete = false; delete.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Idle();
        if (list.Items.Count != 1 || detached != "r2" || !((TextBlock)window.FindName("PlaybackLabel")).Text.Contains("First audio")) throw new Exception("Successful deletion removed wrong state/playback.");
        window.Close();
        var localStore = new LocalRecordingStore(Path.Combine(root, "linked-delete-library"));
        var local = localStore.Create("Local copy");
        var link = new ProcessingEntry(local.Id, session.Snapshot.Account!.Partition, local.Title, ProcessingStage.Completed, new("r1", 1, 1), UploadCompleted: true);
        var localView = new LocalLibraryView(localStore, session);
        var linkedWindow = new CloudLibraryWindow(session, localLibrary: localView, processingEntries: _ => [link]) { ShowActivated = false, ConfirmDelete = _ => true };
        linkedWindow.Show(); await Idle();
        var linkedList = (ListBox)linkedWindow.FindName("Recordings");
        linkedList.SelectedItem = linkedList.Items.Cast<LibraryRecording>().Single(x => x.Cloud?.Id == "r1"); await Idle();
        ((Button)linkedWindow.FindName("DeleteButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Idle();
        if (linkedList.Items.Count != 2 || linkedList.Items.Cast<LibraryRecording>().Any(x => x.Cloud?.Id == "r1") || linkedList.SelectedItem is not LibraryRecording { Local: not null, Cloud: null } || localStore.List().Count != 1 || !((FrameworkElement)linkedWindow.FindName("LocalDetail")).IsVisible)
            throw new Exception("Deleting the cloud copy did not retain and select the local recording.");
        linkedWindow.Close();
        Console.WriteLine("PASS native cross-recording playback and confirmed deletion cancel/failure/success semantics.");
        async Task Idle() => await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
    }
    private static HttpResponseMessage Json(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) => Task.FromResult(send(request));
    }
}
