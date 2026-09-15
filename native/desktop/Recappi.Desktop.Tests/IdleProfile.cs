using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Recappi.Core;
using Recappi.Desktop;

internal static class IdleProfile
{
    public static async Task RunAsync()
    {
        var root = Path.GetFullPath(Path.Combine("build/native-desktop-validation", "idle-profile-" + Guid.NewGuid().ToString("N")));
        Directory.CreateDirectory(root);
        await using var engine = new RecordingEngine(new LocalRecordingStore(Path.Combine(root, "recordings")));
        var model = new RecorderViewModel(engine, new LocalRecordingStore(Path.Combine(root, "recordings")), Application.Current.Dispatcher);
        var window = new RecorderWindow(model, () => { }) { ShowActivated = false };
        DesktopTheme.Apply("system"); window.Show();
        var results = new List<object>();
        async Task Sample(string scenario)
        {
            await Task.Delay(1500);
            using var process = Process.GetCurrentProcess();
            var before = process.TotalProcessorTime.TotalMilliseconds;
            var clock = Stopwatch.StartNew();
            await Task.Delay(6000);
            process.Refresh();
            var value = new { scenario, elapsedMs = clock.Elapsed.TotalMilliseconds,
                cpuPercentOneCore = (process.TotalProcessorTime.TotalMilliseconds - before) / clock.Elapsed.TotalMilliseconds * 100,
                workingSetBytes = process.WorkingSet64, privateBytes = process.PrivateMemorySize64, renderTier = RenderCapability.Tier >> 16 };
            results.Add(value); Console.WriteLine(JsonSerializer.Serialize(value));
        }
        try
        {
            await Sample("fluent-visible");
            await model.RefreshDevicesAsync();
            await Sample("fluent-devices-loaded");
            var pollBusy = false;
            var poller = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
            poller.Tick += async (_, _) =>
            {
                if (pollBusy) return;
                pollBusy = true;
                try
                {
                    await Task.Run(() =>
                    {
                        var active = AudioActivity.ActiveProcessIds(requireSignal: true, sameApplicationOnly: true, excludedProcessId: Environment.ProcessId);
                        return AudioDevices.ListSources().Where(x => x.ProcessId is { } pid && active.Contains(pid)).ToArray();
                    });
                }
                finally { pollBusy = false; }
            };
            poller.Start(); await Sample("fluent-devices-with-activity-poll"); poller.Stop();
            DesktopTheme.Apply("dark"); await Task.Delay(1000); DesktopTheme.Apply("system");
            await Sample("fluent-after-theme-roundtrip");
            var meters = Descendants(window).OfType<ProgressBar>().ToArray();
            if (meters.Length != 2) throw new Exception("Expected both production audio meters.");
            foreach (var meter in meters) meter.Visibility = Visibility.Collapsed;
            await Sample("fluent-meters-collapsed");
            foreach (var meter in meters) meter.Visibility = Visibility.Visible;
            window.Hide(); await Sample("fluent-hidden");
#pragma warning disable WPF0001
            Application.Current.ThemeMode = ThemeMode.None;
#pragma warning restore WPF0001
            window.Show(); await Sample("classic-visible");
        }
        finally { window.Close(); }
        File.WriteAllText(Path.Combine(root, "results.json"), JsonSerializer.Serialize(results, new JsonSerializerOptions { WriteIndented = true }));
        Console.WriteLine("Idle profile: " + root);
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject node)
    {
        for (var index = 0; index < VisualTreeHelper.GetChildrenCount(node); index++)
        {
            var child = VisualTreeHelper.GetChild(node, index); yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
}
