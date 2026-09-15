using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using Recappi.Core;
using Recappi.Desktop;

internal static class ProcessingRecoveryTests
{
    public static async Task RunAsync(string root)
    {
        var directory = Path.Combine(root, "processing-recovery-ui");
        var accounts = new AccountStore(Path.Combine(directory, "Account"));
        var account = new CloudAccount("https://recappi.test", "recovery-user", null, "fixture-token");
        accounts.Save(account);
        var session = new AccountSession(accounts, (origin, token) => new CloudClient(origin, token, new SessionHandler()));
        await session.RestoreAsync();
        if (session.Snapshot.State != AccountState.SignedIn) throw new Exception("Fixture account did not restore.");
        var store = new LocalRecordingStore(Path.Combine(directory, "Recordings"));
        var recording = store.Create("Preserved local recording");
        using (var writer = new PcmWaveWriter(recording.AudioPath)) writer.Append(new float[48000]);
        recording = recording with { State = RecordingState.Done, DurationMs = 1000 };
        store.Save(recording);
        var audio = File.ReadAllBytes(recording.AudioPath);
        var processingRoot = Path.Combine(directory, "Processing");
        var journal = Path.Combine(processingRoot, account.Partition, recording.Id + ".json");
        Directory.CreateDirectory(Path.GetDirectoryName(journal)!);
        File.WriteAllText(journal, "{broken");
        var clientsCreated = 0;
        await using var processing = new CloudProcessing(processingRoot, _ => { clientsCreated++; throw new Exception("Unexpected cloud client."); });
        var window = new LibraryWindow(store, session, processing) { ShowActivated = false };
        try
        {
            window.Show(); window.RefreshRecordings(recording.Id);
            var status = (TextBlock)window.FindName("CloudStatus");
            ((Button)window.FindName("UploadButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            for (var attempt = 0; attempt < 100 && !status.Text.Contains("已损坏"); attempt++) await Task.Delay(20);
            if (!status.Text.Contains("云端录音库核对") || !status.Text.Contains("不会重新上传") || clientsCreated != 0)
                throw new Exception("Journal recovery did not show safe actionable guidance.");
            var position = (Slider)window.FindName("Position");
            for (var attempt = 0; attempt < 100 && !position.IsEnabled; attempt++) await Task.Delay(20);
            if (!position.IsEnabled || !((Button)window.FindName("PlayButton")).IsEnabled || !audio.SequenceEqual(File.ReadAllBytes(recording.AudioPath)) || File.ReadAllText(journal) != "{broken")
                throw new Exception("Journal failure changed local files or disabled local playback.");
            Console.WriteLine("PASS damaged processing journal shows recovery guidance, opens local audio and sends no cloud request.");
        }
        finally { window.Close(); }
    }

    private sealed class SessionHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{\"session\":{},\"user\":{\"id\":\"recovery-user\"}}", Encoding.UTF8, "application/json") });
    }
}
