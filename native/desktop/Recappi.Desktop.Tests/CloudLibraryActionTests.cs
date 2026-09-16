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
        var export = (Button)window.FindName("ExportButton");
        var exportedText = Path.Combine(root, "export-dialog.txt");
        File.WriteAllText(exportedText, "keep prior export");
        window.ShowExportDialog = dialog => { dialog.FileName = exportedText; return false; };
        export.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (File.ReadAllText(exportedText) != "keep prior export") throw new Exception("Cancelled export replaced the destination.");
        window.ShowExportDialog = dialog => { dialog.FileName = exportedText; list.SelectedIndex = 1; return true; };
        export.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (File.ReadAllText(exportedText) != "keep prior export") throw new Exception("Changing recordings during the export dialog wrote a stale transcript.");
        list.SelectedIndex = 0; await Idle();
        window.ShowExportDialog = dialog => { dialog.FileName = exportedText; return true; };
        export.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (!File.ReadAllText(exportedText).Contains("First audio\n\n摘要") || !File.ReadAllText(exportedText).Contains("Current transcript")) throw new Exception("Text export lost the captured title or transcript.");
        ((Button)window.FindName("LoadAudioButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        var player = (AudioPlayer)window.FindName("Player"); var play = (Button)player.FindName("PlayButton");
        using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (!play.IsEnabled) await Task.Delay(25, deadline.Token);
        var saveAudio = (Button)window.FindName("SaveAudioButton");
        var exportedAudio = Path.Combine(root, "export-dialog.wav");
        File.WriteAllText(exportedAudio, "keep prior audio");
        window.ShowExportDialog = dialog => { dialog.FileName = exportedAudio; return null; };
        saveAudio.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (File.ReadAllText(exportedAudio) != "keep prior audio") throw new Exception("Dismissed audio dialog replaced the destination.");
        window.ShowExportDialog = dialog => { dialog.FileName = exportedAudio; return true; };
        saveAudio.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (!File.ReadAllBytes(exportedAudio).SequenceEqual(File.ReadAllBytes(wave))) throw new Exception("Audio export changed the downloaded bytes.");
        play.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        list.SelectedIndex = 1; await Idle();
        if ((string)play.Content != "暂停" || !((TextBlock)window.FindName("PlaybackLabel")).Text.Contains("First audio")) throw new Exception("Changing details interrupted or mislabelled the original playback.");
        var delete = (Button)window.FindName("DeleteButton"); delete.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (deletes != 0) throw new Exception("Cancelled deletion contacted server.");
        window.ConfirmDelete = _ => { list.SelectedIndex = 0; return true; };
        delete.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Idle();
        if (deletes != 0) throw new Exception("Changing recordings during delete confirmation contacted server.");
        list.SelectedIndex = 1; await Idle();
        window.ConfirmDelete = _ => true; delete.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Idle();
        if (list.Items.Count != 2 || detached.Length != 0) throw new Exception("Failed deletion removed local UI state.");
        failDelete = false; delete.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Idle();
        if (list.Items.Count != 1 || detached != "r2" || !((TextBlock)window.FindName("PlaybackLabel")).Text.Contains("First audio")) throw new Exception("Successful deletion removed wrong state/playback.");
        list.SelectedIndex = 0; await Idle();
        File.WriteAllText(exportedText, "keep prior export");
        window.ShowExportDialog = dialog => { dialog.FileName = exportedText; SignOutDuringDialog(); return true; };
        export.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (File.ReadAllText(exportedText) != "keep prior export") throw new Exception("Signing out during the text dialog exported the old account's content.");
        await RestoreAccount(); list.SelectedIndex = 0; await Idle();
        ((Button)window.FindName("LoadAudioButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        using var audioDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (!saveAudio.IsEnabled) await Task.Delay(25, audioDeadline.Token);
        File.WriteAllText(exportedAudio, "keep prior audio");
        window.ShowExportDialog = dialog => { dialog.FileName = exportedAudio; SignOutDuringDialog(); return true; };
        saveAudio.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (File.ReadAllText(exportedAudio) != "keep prior audio") throw new Exception("Signing out during the audio dialog exported the old account's content.");
        await RestoreAccount(); list.SelectedIndex = 0; await Idle();
        var deletesBeforeSignOut = deletes;
        window.ConfirmDelete = _ => { SignOutDuringDialog(); return true; };
        delete.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Idle();
        if (deletes != deletesBeforeSignOut) throw new Exception("Signing out during delete confirmation contacted server.");
        window.Close();
        await RestoreAccount();
        var localStore = new LocalRecordingStore(Path.Combine(root, "linked-delete-library"));
        var local = localStore.Create("Local copy");
        var link = new ProcessingEntry(local.Id, session.Snapshot.Account!.Partition, local.Title, ProcessingStage.Completed, new("r1", 1, 1), UploadCompleted: true);
        var localView = new LocalLibraryView(localStore, session);
        var linkedWindow = new CloudLibraryWindow(session, localLibrary: localView, processingEntries: _ => [link]) { ShowActivated = false, ConfirmDelete = _ => true };
        linkedWindow.Show(); await Idle();
        var linkedList = (ListBox)linkedWindow.FindName("Recordings");
        // Dispatcher idle alone doesn't prove the async Loaded refresh has finished.
        using var linkedDeadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
        while (!linkedList.Items.Cast<LibraryRecording>().Any(x => x.Cloud?.Id == "r1"))
            await Task.Delay(25, linkedDeadline.Token);
        linkedList.SelectedItem = linkedList.Items.Cast<LibraryRecording>().Single(x => x.Cloud?.Id == "r1"); await Idle();
        ((Button)linkedWindow.FindName("DeleteButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Idle();
        if (linkedList.Items.Count != 2 || linkedList.Items.Cast<LibraryRecording>().Any(x => x.Cloud?.Id == "r1") || linkedList.SelectedItem is not LibraryRecording { Local: not null, Cloud: null } || localStore.List().Count != 1 || !((FrameworkElement)linkedWindow.FindName("LocalDetail")).IsVisible)
            throw new Exception("Deleting the cloud copy did not retain and select the local recording.");
        linkedWindow.Close();
        Console.WriteLine("PASS native playback, deletion, export cancellation/content and account/detail changes during save dialogs.");
        async Task Idle() => await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        void SignOutDuringDialog()
        {
            // The fake HTTP handler completes synchronously; do not block a real async operation.
            if (!session.SignOutAsync().IsCompletedSuccessfully) throw new Exception("Expected synchronous fixture sign-out.");
        }
        async Task RestoreAccount()
        {
            accountStore.Save(new("https://example.test", "actions", null, "test-token"));
            await session.RestoreAsync(); await Idle();
        }
    }
    private static HttpResponseMessage Json(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) => Task.FromResult(send(request));
    }
}
