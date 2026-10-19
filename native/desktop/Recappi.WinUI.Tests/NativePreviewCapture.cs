using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Recappi.Core;

namespace Recappi.WinUI.Tests;

internal static class NativePreviewCapture
{
    public static async Task Stage(string root, string name, DesktopWindow window, bool passiveShow = false)
    {
        if (Environment.GetEnvironmentVariable("RECAPPI_PREVIEW_SNAPSHOT") == "1") { await Snapshot(root, name, window); return; }
        await Task.Delay(500);
        var position = window.AppWindow.Position; var size = window.AppWindow.Size;
        var bounds = new FrameBounds { Left = position.X, Top = position.Y, Right = position.X + size.Width, Bottom = position.Y + size.Height };
        if (DwmGetWindowAttribute(WinRT.Interop.WindowNative.GetWindowHandle(window), 9, out var frameBounds, Marshal.SizeOf<FrameBounds>()) == 0)
            bounds = frameBounds;
        var state = new { name, processId = Environment.ProcessId, x = bounds.Left, y = bounds.Top, width = bounds.Right - bounds.Left, height = bounds.Bottom - bounds.Top,
            scale = window.Content.XamlRoot.RasterizationScale, controlledData = true,
            showMode = passiveShow ? "without-activation" : "normal",
            foregroundAtCapture = GetForegroundWindow() == WinRT.Interop.WindowNative.GetWindowHandle(window),
            winuiVersion = FileVersionInfo.GetVersionInfo(Path.Combine(AppContext.BaseDirectory, "Microsoft.UI.Xaml.dll")).FileVersion };
        var temporary = Path.Combine(root, "capture-state.tmp");
        await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(state));
        File.Move(temporary, Path.Combine(root, "capture-state.json"), true);
        var deadline = DateTime.UtcNow.AddSeconds(45);
        while (!File.Exists(Path.Combine(root, name + ".captured")))
        {
            if (DateTime.UtcNow > deadline) throw new TimeoutException("Native capture did not acknowledge " + name);
            await Task.Delay(100);
        }
    }
    public static async Task Library(string root, LibraryWindow window)
    {
        window.Title = "Recappi Mini · 录音库 · 受控样本";
        // Load the selected recording's audio so the scrubber shows decoded peaks.
        await TestApp.Call(window, "LoadAudio");
        await TestApp.Until(() => TestApp.Field<WaveformBars>(window, "bars").Peaks is not null, "Scrubber peaks were not decoded.");
        await Stage(root, "library-summary-light", window);
        window.ApplyTheme("dark"); await Stage(root, "library-summary-dark", window);
        var scale = window.Content.XamlRoot.RasterizationScale;
        var original = window.AppWindow.Size;
        window.AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(820 * scale), (int)(560 * scale)));
        await Stage(root, "library-small-dark", window);
        window.AppWindow.Resize(original); window.ApplyTheme("light");
        var sections = TestApp.Field<SelectorBar>(window, "tabs");
        sections.SelectedItem = sections.Items[1]; await Stage(root, "library-transcript-light", window);
        window.ApplyTheme("dark"); await Stage(root, "library-transcript-dark", window);
        window.AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(820 * scale), (int)(560 * scale)));
        await Stage(root, "library-transcript-small-dark", window);
        window.AppWindow.Resize(original); window.ApplyTheme("light");
        sections.SelectedItem = sections.Items[2]; await Stage(root, "library-ask-light", window);
        window.AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(820 * scale), (int)(560 * scale)));
        await Stage(root, "library-ask-small-light", window);
        var ask = TestApp.Field<AskPanel>(window, "ask");
        TestApp.Field<TextBlock>(ask, "history").Text = string.Join("\n\n", Enumerable.Repeat("你：出发前需要准备什么？\n回答：确认天气，准备饮水和雨衣。", 12));
        TestApp.Field<TextBox>(ask, "question").Text = "什么时候确认路线？";
        await Stage(root, "library-ask-long-history-small-light", window);
        await TestApp.Call(ask, "Send");
        await Stage(root, "library-ask-answer-small-light", window);
        window.ApplyTheme("dark"); await Stage(root, "library-ask-answer-small-dark", window);
        window.AppWindow.Resize(original);
    }
    public static async Task Floating(string root, TestHost host)
    {
        await Recorder(root, host, (name, window) => Stage(root, name, window));
        await Caption(root);
    }
    public static async Task RecorderOnly(string root)
    {
        // Renders the XAML tree in-process, so it works without foreground activation.
        // It omits the native frame; use the full capture for window-chrome evidence.
        await using var host = new TestHost(Path.Combine(root, "recorder-preview"));
        await Recorder(root, host, (name, window) => Snapshot(root, name, window));
        await File.WriteAllTextAsync(Path.Combine(root, "capture-complete.json"), "{}");
        Console.WriteLine("Snapshots: " + root);
    }
    private static async Task Snapshot(string root, string name, DesktopWindow window)
    {
        await Task.Delay(Environment.GetEnvironmentVariable("RECAPPI_PREVIEW_SCREEN") == "1" ? 1500 : 500);
        if (Environment.GetEnvironmentVariable("RECAPPI_PREVIEW_FRAME") == "1") { await FrameSnapshot(root, name, window); return; }
        var bitmap = new Microsoft.UI.Xaml.Media.Imaging.RenderTargetBitmap();
        await bitmap.RenderAsync(window.Content);
        var pixels = System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.ToArray(await bitmap.GetPixelsAsync());
        using var stream = File.Create(Path.Combine(root, name + ".png")).AsRandomAccessStream();
        var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream);
        var dpi = 96 * window.Content.XamlRoot.RasterizationScale;
        encoder.SetPixelData(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied,
            (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, dpi, dpi, pixels);
        await encoder.FlushAsync();
    }
    private static async Task SnapshotElement(string root, string name, FrameworkElement element)
    {
        var bitmap = new Microsoft.UI.Xaml.Media.Imaging.RenderTargetBitmap();
        await bitmap.RenderAsync(element);
        var pixels = System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.ToArray(await bitmap.GetPixelsAsync());
        using var stream = File.Create(Path.Combine(root, name + ".png")).AsRandomAccessStream();
        var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied, (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 144, 144, pixels);
        await encoder.FlushAsync();
    }
    private static async Task Recorder(string root, TestHost host, Func<string, DesktopWindow, Task> stage)
    {
        var recorder = new RecorderWindow(host, () => ([new AudioSource("system", "系统声音 · 所有应用")], [new MicrophoneDevice("sample", "验证麦克风", true)]));
        try
        {
            recorder.ApplyTheme("light"); await recorder.RefreshDevices(); recorder.Show();
            await stage("recorder-idle-light", recorder);
            if (Environment.GetEnvironmentVariable("RECAPPI_PREVIEW_HOVER") == "1")
            {
                var hide = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(TestApp.Field<Button>(recorder, "optionsChip")) is Grid row ? row.Children.OfType<Button>().ElementAt(3) : null;
                if (hide is not null)
                {
                    VisualStateManager.GoToState(hide, "PointerOver", false); await Task.Delay(300);
                    var origin = hide.TransformToVisual(recorder.Content).TransformPoint(new Windows.Foundation.Point());
                    var shape = TestApp.Descendants<Microsoft.UI.Xaml.Shapes.Path>(hide).FirstOrDefault();
                    var bounds = shape?.Data?.Bounds;
                    await File.WriteAllTextAsync(Path.Combine(root, "hover-bounds.txt"), $"button {origin.X},{origin.Y} {hide.ActualWidth}x{hide.ActualHeight} shape {bounds} margin {shape?.Margin} stretch {shape?.Stretch} parent {Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(shape!)?.GetType().Name} {(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(shape!) as FrameworkElement)?.ActualWidth}x{(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(shape!) as FrameworkElement)?.ActualHeight}");
                    await stage("recorder-hover-light", recorder);
                    VisualStateManager.GoToState(hide, "Normal", false);
                    foreach (var (field, label) in new[] { ("source", "source"), ("optionsChip", "options") })
                        foreach (var state in new[] { "PointerOver", "Pressed" })
                        {
                            var target = TestApp.Field<Button>(recorder, field);
                            VisualStateManager.GoToState(target, state, false); await Task.Delay(250);
                            await stage($"recorder-{label}-{state}-light", recorder);
                            VisualStateManager.GoToState(target, "Normal", false);
                        }
                }
            }
            recorder.ApplyTheme("dark"); await stage("recorder-idle-dark", recorder);
            if (Environment.GetEnvironmentVariable("RECAPPI_PREVIEW_SNAPSHOT") == "1" || stage.Method.Name.Contains("RecorderOnly"))
            {
                var options = TestApp.Field<Flyout>(recorder, "options");
                foreach (var theme in new[] { "light", "dark" })
                {
                    recorder.ApplyTheme(theme);
                    options.ShowAt(TestApp.Field<Button>(recorder, "optionsChip"));
                    await Task.Delay(700);
                    await SnapshotElement(root, "recorder-options-" + theme, (FrameworkElement)options.Content);
                    options.Hide(); await Task.Delay(200);
                }
                recorder.ApplyTheme("dark");
            }
            TestApp.Field<CheckBox>(recorder, "includeMicrophone").IsChecked = true;
            await stage("recorder-idle-microphone-dark", recorder);
            recorder.ApplyTheme("light"); await stage("recorder-idle-microphone-light", recorder);
            await TestApp.Call(recorder, "Start");
            await TestApp.Until(() => host.Engine.Snapshot.State == RecordingState.Recording, "Controlled recording did not start.");
            await Task.Delay(1000); await stage("recorder-recording-light", recorder);
            recorder.ApplyTheme("dark"); await stage("recorder-recording-dark", recorder);
            recorder.RequestAttention(AttentionAction.DurationLimit);
            await stage("recorder-attention-dark", recorder);
            recorder.ApplyTheme("light"); await stage("recorder-attention-light", recorder);
            await host.StopRecording(); await stage("recorder-done-light", recorder);
            recorder.ApplyTheme("dark"); await stage("recorder-done-dark", recorder);
        }
        finally { recorder.Close(); }
    }
    private static async Task Caption(string root)
    {
        var caption = new CaptionWindow(() => Task.CompletedTask);
        try
        {
            caption.ApplyTheme("light"); caption.Reset(true); caption.SetStatus("实时字幕");
            caption.Update(new("a", "source", "Let's confirm the route before Friday evening.", true, new("sample", 0)));
            caption.Update(new("a", "translation", "我们在周五晚上前确认好路线。", true, new("sample", 0)));
            caption.ShowWithoutActivation(); await Stage(root, "caption-short-light", caption, passiveShow: true);
            caption.Update(new("a", "source", "Before we leave on Saturday morning, let's check the forecast and choose a route with enough time for breaks. Everyone should bring water, a raincoat and a little food for the day.", true, new("sample", 0)));
            caption.Update(new("a", "translation", "周六早上出发前，我们先看看天气预报，再选择一条有充足休息时间的路线。大家记得准备饮水、雨衣和少量食物。", true, new("sample", 0)));
            await Stage(root, "caption-long-light", caption, passiveShow: true);
            caption.ApplyTheme("dark"); TestApp.Field<CheckBox>(caption, "compact").IsChecked = false;
            caption.Update(new("b", "source", "We can meet at the station at eight.", true, new("sample", 1)));
            caption.Update(new("b", "translation", "我们可以八点在地铁站集合。", true, new("sample", 1)));
            caption.Update(new("c", "source", "I'll check the return journey as well.", true, new("sample", 2)));
            caption.Update(new("c", "translation", "我也会确认返程交通。", true, new("sample", 2)));
            await Stage(root, "caption-history-dark", caption, passiveShow: true);
            TestApp.Field<CheckBox>(caption, "compact").IsChecked = true;
            caption.SetStatus("连接恢复中 · 本机录音继续");
            caption.Update(new("c", "source", "I'll check the return journey", true, new("sample", 2), IsFailed: true));
            await Stage(root, "caption-reconnect-dark", caption, passiveShow: true);
        }
        finally { caption.Close(); }
    }
    [StructLayout(LayoutKind.Sequential)] private struct FrameBounds { public int Left, Top, Right, Bottom; }
    // Whole-HWND capture (including the non-client frame) without foreground activation.
    private static async Task FrameSnapshot(string root, string name, DesktopWindow window)
    {
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
        GetWindowRect(hwnd, out var rect);
        if (Environment.GetEnvironmentVariable("RECAPPI_PREVIEW_SCREEN") == "1" && DwmGetWindowAttribute(hwnd, 9, out var visible, Marshal.SizeOf<FrameBounds>()) == 0) rect = visible;
        int width = rect.Right - rect.Left, height = rect.Bottom - rect.Top;
        var screen = GetDC(0); var dc = CreateCompatibleDC(screen); var bitmap = CreateCompatibleBitmap(screen, width, height);
        var old = SelectObject(dc, bitmap);
        // Screen mode copies the composed desktop so acrylic glass is visible (topmost windows only).
        if (Environment.GetEnvironmentVariable("RECAPPI_PREVIEW_SCREEN") == "1") BitBlt(dc, 0, 0, width, height, screen, rect.Left, rect.Top, 0x00CC0020 | 0x40000000);
        else PrintWindow(hwnd, dc, 2);
        var info = new BitmapInfoHeader { Size = 40, Width = width, Height = -height, Planes = 1, BitCount = 32 };
        var pixels = new byte[width * height * 4];
        GetDIBits(dc, bitmap, 0, (uint)height, pixels, ref info, 0);
        SelectObject(dc, old); DeleteObject(bitmap); DeleteDC(dc); ReleaseDC(0, screen);
        for (var i = 3; i < pixels.Length; i += 4) pixels[i] = 255;
        if (Environment.GetEnvironmentVariable("RECAPPI_PREVIEW_SCREEN") == "1" && Environment.GetEnvironmentVariable("RECAPPI_PREVIEW_BEHIND") == "1")
        {
            // Also capture what is behind the window, to verify transparent margins.
            var position = window.AppWindow.Position;
            window.AppWindow.Move(new Windows.Graphics.PointInt32(position.X, position.Y + 4000)); await Task.Delay(300);
            var screen2 = GetDC(0); var dc2 = CreateCompatibleDC(screen2); var bitmap2 = CreateCompatibleBitmap(screen2, width, height); var old2 = SelectObject(dc2, bitmap2);
            BitBlt(dc2, 0, 0, width, height, screen2, rect.Left, rect.Top, 0x00CC0020 | 0x40000000);
            var behind = new byte[width * height * 4]; GetDIBits(dc2, bitmap2, 0, (uint)height, behind, ref info, 0);
            SelectObject(dc2, old2); DeleteObject(bitmap2); DeleteDC(dc2); ReleaseDC(0, screen2);
            window.AppWindow.Move(position); await Task.Delay(200);
            var same = 0; var total = 0;
            for (var y = 0; y < Math.Min(height, 12); y++) for (var x = 0; x < width; x++)
            { var i = (y * width + x) * 4; total++; if (Math.Abs(pixels[i] - behind[i]) + Math.Abs(pixels[i + 1] - behind[i + 1]) + Math.Abs(pixels[i + 2] - behind[i + 2]) < 12) same++; }
            await File.WriteAllTextAsync(Path.Combine(root, name + ".transparency.txt"), $"top-margin pixels matching background: {same}/{total}");
        }
        using var stream = File.Create(Path.Combine(root, name + ".png")).AsRandomAccessStream();
        var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Ignore, (uint)width, (uint)height, 96, 96, pixels);
        await encoder.FlushAsync();
    }
    [StructLayout(LayoutKind.Sequential)] private struct BitmapInfoHeader { public int Size, Width, Height; public short Planes, BitCount; public int Compression, SizeImage, XPelsPerMeter, YPelsPerMeter, ClrUsed, ClrImportant; }
    [DllImport("user32.dll")] private static extern bool GetWindowRect(nint window, out FrameBounds rect);
    [DllImport("user32.dll")] private static extern bool PrintWindow(nint window, nint dc, uint flags);
    [DllImport("user32.dll")] private static extern nint GetDC(nint window);
    [DllImport("user32.dll")] private static extern int ReleaseDC(nint window, nint dc);
    [DllImport("gdi32.dll")] private static extern nint CreateCompatibleDC(nint dc);
    [DllImport("gdi32.dll")] private static extern nint CreateCompatibleBitmap(nint dc, int width, int height);
    [DllImport("gdi32.dll")] private static extern nint SelectObject(nint dc, nint value);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(nint value);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(nint dc);
    [DllImport("gdi32.dll")] private static extern bool BitBlt(nint dc, int x, int y, int width, int height, nint source, int sourceX, int sourceY, uint operation);
    [DllImport("gdi32.dll")] private static extern int GetDIBits(nint dc, nint bitmap, uint start, uint lines, byte[] bits, ref BitmapInfoHeader info, uint usage);
    public static async Task UpdateChannels(string root)
    {
        await using var host = new TestHost(Path.Combine(root, "update-preview"));
        foreach (var distribution in Enum.GetValues<DesktopDistribution>())
        {
            var settings = new SettingsWindow(host, false, distribution);
            try
            {
                var navigation = TestApp.Field<NavigationView>(settings, "navigation");
                navigation.SelectedItem = navigation.MenuItems[4];
                settings.Show();
                foreach (var theme in new[] { "light", "dark" })
                {
                    settings.ApplyTheme(theme);
                    await Stage(root, "settings-update-" + distribution.ToString().ToLowerInvariant() + "-" + theme, settings);
                }
            }
            finally { settings.Close(); }
        }
        await File.WriteAllTextAsync(Path.Combine(root, "capture-complete.json"), "{}");
    }
    public static async Task Auxiliary(string root)
    {
        await using var host = new TestHost(Path.Combine(root, "auxiliary-preview"));
        var settings = new SettingsWindow(host, false);
        try
        {
            settings.Show();
            var navigation = TestApp.Field<NavigationView>(settings, "navigation");
            var names = new[] { "general", "cloud", "captions", "reminders", "about" };
            foreach (var theme in new[] { "light", "dark" })
            {
                settings.ApplyTheme(theme);
                for (var i = 0; i < names.Length; i++)
                {
                    navigation.SelectedItem = navigation.MenuItems[i];
                    await Stage(root, "settings-" + names[i] + "-" + theme, settings);
                }
            }
        }
        finally { settings.Close(); }
        var account = new AccountWindow(host);
        try
        {
            account.Show();
            account.ApplyTheme("light"); await Stage(root, "account-signedout-light", account);
            account.ApplyTheme("dark"); await Stage(root, "account-signedout-dark", account);
            await host.SignIn();
            account.ApplyTheme("light"); await Stage(root, "account-connected-light", account);
            account.ApplyTheme("dark"); await Stage(root, "account-connected-dark", account);
        }
        finally { account.Close(); }
        var onboarding = new OnboardingWindow(host);
        try
        {
            onboarding.Show();
            onboarding.ApplyTheme("light"); await Stage(root, "onboarding-start-light", onboarding);
            onboarding.ApplyTheme("dark"); await Stage(root, "onboarding-start-dark", onboarding);
            await TestApp.Call(onboarding, "Move", 1); await TestApp.Call(onboarding, "Move", 1);
            onboarding.ApplyTheme("light"); await Stage(root, "onboarding-cloud-light", onboarding);
            onboarding.ApplyTheme("dark"); await Stage(root, "onboarding-cloud-dark", onboarding);
        }
        finally { onboarding.Close(); }
    }
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(nint window, int attribute, out FrameBounds value, int size);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
}
