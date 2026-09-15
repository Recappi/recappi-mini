using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Recappi.Core;
using Recappi.Desktop;
using Forms = System.Windows.Forms;

internal static class RecordingNotificationTests
{
    public static async Task RunAsync(string root, Dispatcher dispatcher)
    {
        var store = new LocalRecordingStore(Path.Combine(root, "notification-selection"));
        var captures = 0;
        await using var engine = new RecordingEngine(store, _ => { captures++; return []; });
        AudioSource candidate = new("process:123", "Suggested app", 123);
        IReadOnlyList<AudioSource> sources = [new("system", "All apps"), candidate];
        ManualResetEventSlim? release = null;
        TaskCompletionSource? entered = null;
        var failRefresh = false;
        var model = new RecorderViewModel(engine, store, dispatcher, () =>
        {
            entered?.TrySetResult();
            if (release is not null && !release.Wait(TimeSpan.FromSeconds(5))) throw new TimeoutException("Test discovery release timed out.");
            if (failRefresh) throw new IOException("Test discovery unavailable");
            return (sources, Array.Empty<MicrophoneDevice>());
        });
        model.ApplyPreferences(new() { SourceId = "system", IncludeMicrophone = false });
        await model.RefreshDevicesAsync();
        var window = new RecorderWindow(model, () => { }) { ShowActivated = false };
        var messages = new List<string>();
        var restored = 0;
        var failShow = false;
        var notifications = new RecordingNotifications(model, () => { restored++; window.Show(); }, (_, title, _, _) =>
        {
            if (failShow) throw new InvalidOperationException("Test balloon unavailable");
            messages.Add(title);
        });
        void Suggest() => notifications.Show(6000, "Suggestion", "Choose app", Forms.ToolTipIcon.Info, candidate);
        void Ordinary() => notifications.Show(3000, "Processing complete", "Open recorder", Forms.ToolTipIcon.Info);
        void ExpectSource(string expected)
        {
            var picker = ((Grid)window.FindName("SetupPanel")).Children.OfType<ComboBox>().Single();
            if (model.SelectedSource?.Id != expected || (picker.SelectedItem as AudioSource)?.Id != expected || captures != 0)
                throw new Exception("Notification selected the wrong source or started capture.");
        }
        try
        {
            window.Show();
            Suggest(); Ordinary(); await notifications.HandleClickAsync();
            ExpectSource("system");
            Suggest(); await notifications.HandleClickAsync();
            ExpectSource(candidate.Id);
            model.SelectedSource = model.Sources.First(source => source.Id == "system");
            await notifications.HandleClickAsync();
            ExpectSource("system");
            Suggest(); notifications.ClearSuggestion(); await notifications.HandleClickAsync();
            ExpectSource("system");

            using (release = new ManualResetEventSlim())
            {
                entered = new(TaskCreationOptions.RunContinuationsAsynchronously);
                Suggest(); var pendingClick = notifications.HandleClickAsync();
                try { await entered.Task.WaitAsync(TimeSpan.FromSeconds(5)); Ordinary(); }
                finally { release.Set(); }
                await pendingClick;
                ExpectSource("system");
            }
            release = null; entered = null;
            failRefresh = true;
            Suggest(); await notifications.HandleClickAsync();
            ExpectSource("system");
            if (model.Error is null) throw new Exception("Failed refresh lost its recorder error.");
            failRefresh = false;
            await model.RefreshDevicesAsync();
            sources = [new("system", "All apps")];
            Suggest(); await notifications.HandleClickAsync();
            ExpectSource("system");
            sources = [new("system", "All apps"), candidate];
            await model.RefreshDevicesAsync();
            failShow = true;
            try { Suggest(); throw new Exception("Expected balloon failure."); }
            catch (InvalidOperationException) { }
            await notifications.HandleClickAsync();
            ExpectSource("system");
            if (restored < 8 || messages.Count < 8) throw new Exception("Notification cases did not restore the recorder or present messages.");
            Console.WriteLine("PASS notification replacement and delayed refresh cannot reuse a stale suggestion; valid click only selects, never records; failed/missing sources and cleared suggestions preserve selection.");
        }
        finally { window.Close(); }
    }
}
