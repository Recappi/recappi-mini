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
        var recorder = new RecorderWindow(host, () => ([new AudioSource("system", "系统声音 · 所有应用")], [new MicrophoneDevice("sample", "验证麦克风", true)]));
        try
        {
            recorder.ApplyTheme("light"); await recorder.RefreshDevices(); recorder.Show();
            await Stage(root, "recorder-idle-light", recorder);
            recorder.ApplyTheme("dark"); await Stage(root, "recorder-idle-dark", recorder);
            recorder.ApplyTheme("light");
            await TestApp.Call(recorder, "Start");
            await TestApp.Until(() => host.Engine.Snapshot.State == RecordingState.Recording, "Controlled recording did not start.");
            await Task.Delay(1000); await Stage(root, "recorder-recording-light", recorder);
            recorder.ApplyTheme("dark"); await Stage(root, "recorder-recording-dark", recorder);
            recorder.ApplyTheme("light");
            await host.StopRecording(); await Stage(root, "recorder-done-light", recorder);
            recorder.ApplyTheme("dark"); await Stage(root, "recorder-done-dark", recorder);
        }
        finally { recorder.Close(); }
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
