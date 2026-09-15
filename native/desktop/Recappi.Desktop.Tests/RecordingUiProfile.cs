using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Recappi.Core;
using Recappi.Desktop;

internal static class RecordingUiProfile
{
    // UI isolation diagnostic: synthetic PCM and caption updates, no WASAPI or network.
    public static async Task RunAsync(bool softwareRendering = false)
    {
        if (softwareRendering) RenderOptions.ProcessRenderMode = System.Windows.Interop.RenderMode.SoftwareOnly;
        var root = Path.GetFullPath(Path.Combine("build/native-desktop-validation", "recording-ui-profile-" + Guid.NewGuid().ToString("N")));
        Directory.CreateDirectory(root);
        var store = new LocalRecordingStore(Path.Combine(root, "recordings"));
        await using var engine = new RecordingEngine(store, _ => [new ToneInput()]);
        var model = new RecorderViewModel(engine, store, Application.Current.Dispatcher,
            () => ([new AudioSource("system", "Synthetic diagnostic input")], []));
        await model.RefreshDevicesAsync();
        var recorder = new RecorderWindow(model, () => { }) { ShowActivated = false };
        var captions = new CaptionWindow { ShowActivated = false };
        var tick = 0;
        var updater = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
        updater.Tick += (_, _) =>
        {
            tick++;
            captions.Update(new("fixed", "source", string.Concat(Enumerable.Repeat("The team will review the design tomorrow. ", 35)) + tick, false));
            captions.Update(new("fixed", "translation", string.Concat(Enumerable.Repeat("团队明天将审查设计。", 80)) + tick, false));
        };
        var results = new List<object>();
        async Task Sample(string scenario)
        {
            await Task.Delay(1500);
            using var process = Process.GetCurrentProcess();
            var before = process.TotalProcessorTime.TotalMilliseconds;
            var startedAt = DateTimeOffset.UtcNow;
            var clock = Stopwatch.StartNew();
            await Task.Delay(8000);
            process.Refresh();
            var value = new { scenario, startedAt, processId = Environment.ProcessId, elapsedMs = clock.Elapsed.TotalMilliseconds,
                cpuPercentOneCore = (process.TotalProcessorTime.TotalMilliseconds - before) / clock.Elapsed.TotalMilliseconds * 100,
                workingSetBytes = process.WorkingSet64, privateBytes = process.PrivateMemorySize64,
                renderTier = RenderCapability.Tier >> 16, softwareRendering };
            results.Add(value); Console.WriteLine(JsonSerializer.Serialize(value));
        }
        try
        {
            DesktopTheme.Apply("light");
            recorder.Show(); captions.Show(); captions.Reset(); captions.UpdateStatus(new("live"));
            await engine.StartAsync(new("UI isolation", true, false)); updater.Start();
            await Sample("both-visible");
            await Sample("both-visible-steady");
            captions.Hide(); await Sample("recorder-only");
            var meters = Descendants(recorder).OfType<ProgressBar>().ToArray();
            if (meters.Length != 2) throw new Exception("Expected two audio meters.");
            foreach (var meter in meters) meter.Visibility = Visibility.Collapsed;
            await Sample("recorder-meters-collapsed");
            recorder.Hide(); captions.Show(); await Sample("captions-only");
            updater.Stop(); await Sample("captions-static"); updater.Start();
            captions.Hide(); await Sample("both-hidden");
            foreach (var meter in meters) meter.Visibility = Visibility.Visible;
            recorder.Show(); captions.Show(); await Sample("both-visible-repeat");
        }
        finally
        {
            updater.Stop(); await engine.StopAsync(); recorder.Close(); captions.Close();
            File.WriteAllText(Path.Combine(root, "results.json"), JsonSerializer.Serialize(results, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine("Recording UI profile: " + root);
        }
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject node)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
        {
            var child = VisualTreeHelper.GetChild(node, i); yield return child;
            foreach (var value in Descendants(child)) yield return value;
        }
    }
    private sealed class ToneInput : IAudioInput
    {
        private long sample;
        public string Input => "system";
        public Exception? Error => null;
        public void Start() { }
        public void Stop() { }
        public void Dispose() { }
        public void Read(float[] destination)
        {
            for (var i = 0; i < destination.Length; i++, sample++)
                destination[i] = (float)(0.3 * Math.Sin(2 * Math.PI * 443 * sample / 48000));
        }
    }
}
