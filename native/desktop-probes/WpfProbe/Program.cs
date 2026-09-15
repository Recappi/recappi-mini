using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;

internal static class Program
{
    [STAThread]
    static void Main(string[] args)
    {
        var clock = Stopwatch.StartNew();
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Startup += async (_, _) =>
        {
            var windows = new[] { Create("录音面板", 360, 170), Create("实时字幕", 600, 260), Create("录音库", 860, 560) };
            windows[0].Show();
            var startupMs = clock.Elapsed.TotalMilliseconds;
            var results = new List<object>();
            results.Add(await Measure("one-window"));
            windows[1].Show(); windows[2].Show();
            results.Add(await Measure("three-windows"));
            foreach (var window in windows) window.Hide();
            results.Add(await Measure("hidden"));
            File.WriteAllText(args.Single(), JsonSerializer.Serialize(new { framework = "WPF", startupMs, results }, new JsonSerializerOptions { WriteIndented = true }));
            app.Shutdown();
        };
        app.Run();
    }

    private static Window Create(string title, int width, int height) => new()
    {
        Title = "Recappi WPF 验证 · " + title, Width = width, Height = height,
        ShowActivated = false,
        Content = new StackPanel { Margin = new Thickness(20), Children =
        { new TextBlock { Text = title }, new Button { Content = "开始录音", Margin = new Thickness(0, 12, 0, 0) }, new TextBox { Text = "原生输入框", Margin = new Thickness(0, 12, 0, 0) } } }
    };

    private static async Task<object> Measure(string state)
    {
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
