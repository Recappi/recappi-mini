using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics;

namespace Recappi.Probes;

internal static class ProbeState
{
    internal static readonly Stopwatch Clock = Stopwatch.StartNew();
    internal static string ResultPath = Environment.GetCommandLineArgs().Skip(1).Single();
    internal static void Trace(string step) => File.AppendAllText(ResultPath + ".trace.txt", step + Environment.NewLine);
}

public sealed partial class ProbeApp : Application
{
    public ProbeApp()
    {
        _ = ProbeState.Clock;
        ProbeState.Trace("constructor");
        UnhandledException += (_, e) => File.WriteAllText(ProbeState.ResultPath + ".error.txt", e.Exception.ToString());
        InitializeComponent();
        ProbeState.Trace("initialized");
    }

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        ProbeState.Trace("launched");
        var windows = new[] { Create("录音面板", 360, 170), Create("实时字幕", 600, 260), Create("录音库", 860, 560) };
        windows[0].Activate();
        ProbeState.Trace("activated");
        var startupMs = ProbeState.Clock.Elapsed.TotalMilliseconds;
        var results = new List<object> { await Measure("one-window") };
        windows[1].Activate(); windows[2].Activate();
        results.Add(await Measure("three-windows"));
        foreach (var window in windows) window.AppWindow.Hide();
        results.Add(await Measure("hidden"));
        File.WriteAllText(ProbeState.ResultPath, JsonSerializer.Serialize(new { framework = "WinUI3", startupMs, results }, new JsonSerializerOptions { WriteIndented = true }));
        foreach (var window in windows) window.Close();
        Exit();
    }

    private static Window Create(string title, int width, int height)
    {
        var window = new Window { Title = "Recappi WinUI 验证 · " + title };
        window.AppWindow.Resize(new SizeInt32(width, height));
        var panel = new StackPanel { Margin = new Thickness(20), Spacing = 12 };
        panel.Children.Add(new TextBlock { Text = title });
        panel.Children.Add(new Button { Content = "开始录音" });
        panel.Children.Add(new TextBox { Text = "原生输入框" });
        window.Content = panel;
        return window;
    }

    private static async Task<object> Measure(string state)
    {
        ProbeState.Trace(state);
        await Task.Delay(2000);
        using var process = Process.GetCurrentProcess();
        var start = process.TotalProcessorTime;
        var clock = Stopwatch.StartNew();
        await Task.Delay(3000);
        process.Refresh();
        return new { state, workingSetBytes = process.WorkingSet64, privateBytes = process.PrivateMemorySize64,
            cpuOneCorePercent = (process.TotalProcessorTime - start).TotalMilliseconds / clock.Elapsed.TotalMilliseconds * 100 };
    }
}
