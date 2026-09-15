using System.IO;
using System.Text.Json;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Recappi.Core;
using Recappi.Desktop;

internal static class LibraryLifetimeProfile
{
    public static async Task RunAsync(bool holdForDump = false)
    {
        var startedUtc = DateTimeOffset.UtcNow;
        var root = Path.GetFullPath(Path.Combine("build", "native-desktop-validation", "library-lifetime-" + Guid.NewGuid().ToString("N")));
        Directory.CreateDirectory(root);
        var store = new LocalRecordingStore(Path.Combine(root, "Recordings"));
        var recording = store.Create("Window lifecycle fixture");
        using (var writer = new PcmWaveWriter(recording.AudioPath))
            for (var i = 0; i < 100; i++) writer.Append(new float[4800]);
        recording = recording with { State = RecordingState.Done, DurationMs = 10000 };
        store.Save(recording);
        var accounts = new AccountSession(new AccountStore(Path.Combine(root, "account")));
        await accounts.RestoreAsync();
        var cache = new CloudContentCache(Path.Combine(root, "cache"));
        var speakers = new SpeakerProfileStore(Path.Combine(root, "speakers"));
        // Application.MainWindow intentionally remains alive, like the real recorder.
        // Otherwise WPF retains the first library as the application main window.
        var host = new Window { Title = "Library lifetime test host", ShowActivated = false, Width = 300, Height = 100 };
        Application.Current.MainWindow = host;
        host.Show();
        var references = new List<(string Name, WeakReference Reference)>();
        var rounds = new List<object>();
        try
        {
            for (var round = 0; round < 8; round++)
            {
                references.AddRange(await OpenPlaySearchCloseAsync(round, store, recording, accounts, cache, speakers));
                // Account notifications continue after closure; subscribers must not retain windows.
                await accounts.RestoreAsync();
                for (var attempt = 0; attempt < 6; attempt++)
                {
                    await Application.Current.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                    await Task.Run(() =>
                    {
                        GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, true, true);
                        GC.WaitForPendingFinalizers();
                        GC.Collect(GC.MaxGeneration, GCCollectionMode.Forced, true, true);
                    });
                    await Task.Delay(100);
                }
                // Windows sharing checks detect a media handle that survived Close.
                using (File.Open(recording.AudioPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { }
                rounds.Add(new { round, exclusiveAudioAccess = true });
            }
            var neutral = await OpenCloseNeutralAsync();
            for (var attempt = 0; attempt < 30; attempt++)
            {
                await Task.Delay(1000);
                await Task.Run(() => { GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect(); });
            }
            Console.WriteLine("Neutral WPF window retained: " + neutral.IsAlive);
            var survivors = references.Where(item => item.Reference.IsAlive).Select(item => item.Name).ToArray();
            File.WriteAllText(Path.Combine(root, "results.json"), JsonSerializer.Serialize(new
            {
                startedUtc,
                completedUtc = DateTimeOffset.UtcNow,
                runtime = RuntimeInformation.FrameworkDescription,
                architecture = RuntimeInformation.ProcessArchitecture.ToString(),
                scope = "Real WPF library, signed out, synthetic local WAV, active local and cloud player controls, pending search at close; forced GC diagnostic, not long-term process-memory performance or real cloud validation",
                rounds,
                finalCleanupAttempts = 30,
                finalCleanupDelayMs = 1000,
                neutralWindowRetained = neutral.IsAlive,
                trackedObjects = references.Count,
                retainedObjects = survivors,
                allTrackedObjectsReleased = survivors.Length == 0,
            }, new JsonSerializerOptions { WriteIndented = true }));
            GC.KeepAlive(accounts); GC.KeepAlive(host);
            if (survivors.Length > 0 && holdForDump)
            {
                Console.WriteLine($"Retained objects: PID {Environment.ProcessId}; allowing 60 seconds for a diagnostic dump. Report: {root}");
                System.Threading.Thread.Sleep(TimeSpan.FromSeconds(60));
            }
            if (survivors.Length > 0) throw new Exception("Closed library objects retained: " + string.Join(", ", survivors) + "; report " + root);
            Console.WriteLine("PASS eight real WPF library open/play/search/close cycles release all " + references.Count + " tracked objects and exclusive audio access. Report: " + root);
        }
        finally { host.Close(); }
    }

    private static async Task<WeakReference> OpenCloseNeutralAsync()
    {
        Window? window = new() { ShowActivated = false, Width = 300, Height = 100 };
        var reference = new WeakReference(window);
        window.Show();
        await Task.Delay(100);
        window.Close(); window = null;
        return reference;
    }

    private static async Task<List<(string, WeakReference)>> OpenPlaySearchCloseAsync(int round, LocalRecordingStore store,
        LocalRecording recording, AccountSession accounts, CloudContentCache cache, SpeakerProfileStore speakers)
    {
        LocalLibraryView? local = new(store, accounts);
        CloudLibraryWindow? window = new(accounts, localLibrary: local, contentCache: cache, speakerProfiles: speakers) { ShowActivated = false };
        AudioPlayer? cloudPlayer = (AudioPlayer)window.FindName("Player");
        var references = new List<(string, WeakReference)>
        {
            ($"{round}:window", new(window)), ($"{round}:local-view", new(local)), ($"{round}:cloud-player", new(cloudPlayer)),
        };
        try
        {
            window.Show(); window.RefreshLocalRecordings(recording.Id);
            window.UpdateLayout();
            for (var attempt = 0; attempt < 100 && !((Slider)local.FindName("Position")).IsEnabled; attempt++) await Task.Delay(50);
            if (!((Slider)local.FindName("Position")).IsEnabled) throw new Exception("Local media did not open for lifecycle diagnostic.");
            ((Button)local.FindName("PlayButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            cloudPlayer.Open(recording.AudioPath);
            for (var attempt = 0; attempt < 100 && !((Button)cloudPlayer.FindName("PlayButton")).IsEnabled; attempt++) await Task.Delay(50);
            if (!((Button)cloudPlayer.FindName("PlayButton")).IsEnabled) throw new Exception("Cloud player control did not open synthetic local media.");
            ((Button)cloudPlayer.FindName("PlayButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            await Task.Delay(350);
            ((TextBox)window.FindName("LibraryQuery")).Text = "Window lifecycle";
            var search = window.SearchLibraryAsync();
            window.Close();
            await search;
            return references;
        }
        finally
        {
            if (window.IsVisible) window.Close();
            window = null; local = null; cloudPlayer = null;
        }
    }
}
