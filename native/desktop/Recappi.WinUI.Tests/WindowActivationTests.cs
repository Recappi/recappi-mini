using System.Runtime.InteropServices;
using System.Diagnostics;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Recappi.WinUI.Tests;

public partial class TestApp
{
    private static async Task ShowHideRestore()
    {
        var window = new DesktopWindow("Window visibility lifecycle", 440, 220);
        var input = new TextBox { Text = "Preserve this draft" };
        window.Body.Children.Add(input);
        try
        {
            window.Show();
            await Until(() => input.IsLoaded && input.ActualWidth > 0 && window.Content.XamlRoot.IsHostVisible && IsPresented(window),
                "First show did not initialize visible XAML content.");
            window.AppWindow.Hide();
            await Until(() => !window.AppWindow.IsVisible, "Window did not hide.");
            window.Show();
            await Until(() => window.AppWindow.IsVisible && window.Content.XamlRoot.IsHostVisible && IsPresented(window),
                "Hidden window did not restore.");
            var presenter = (Microsoft.UI.Windowing.OverlappedPresenter)window.AppWindow.Presenter;
            presenter.Minimize();
            await Until(() => presenter.State == Microsoft.UI.Windowing.OverlappedPresenterState.Minimized,
                "Window did not minimize.");
            window.Show();
            await Until(() => presenter.State == Microsoft.UI.Windowing.OverlappedPresenterState.Restored && window.Content.XamlRoot.IsHostVisible && IsPresented(window),
                "Minimized window did not restore.");
            Check(input.Text == "Preserve this draft", "Restoring the window reset its content.");
        }
        finally { window.Close(); }
    }
    private static bool IsPresented(Window window) =>
        DwmGetWindowAttribute(WinRT.Interop.WindowNative.GetWindowHandle(window), 14, out var cloaked, sizeof(uint)) >= 0 && cloaked == 0;
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(nint window, int attribute, out uint value, int size);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    private static async Task ExternalFocusOwner(string exchange)
    {
        var owner = new DesktopWindow("External process · caption focus validation", 500, 240);
        var input = new TextBox { Text = "External input must keep focus" };
        owner.Body.Children.Add(input);
        try
        {
            await Until(() => File.Exists(Path.Combine(exchange, "allow-show")), "Parent did not authorize focus probe startup.");
            owner.Show(); await Until(() => input.IsLoaded, "External input did not load.");
            input.Focus(FocusState.Programmatic);
            var state = new { processId = Environment.ProcessId, window = WinRT.Interop.WindowNative.GetWindowHandle(owner).ToInt64(), focus = ActivationNative.GetFocus().ToInt64() };
            var temporary = Path.Combine(exchange, "owner.tmp");
            await File.WriteAllTextAsync(temporary, JsonSerializer.Serialize(state));
            File.Move(temporary, Path.Combine(exchange, "owner.json"));
            var deadline = DateTime.UtcNow.AddSeconds(30);
            while (!File.Exists(Path.Combine(exchange, "stop")) && DateTime.UtcNow < deadline) await Task.Delay(20);
        }
        finally { owner.Close(); }
    }
    private static async Task ExternalCaptionFocus(string root)
    {
        var exchange = Path.Combine(root, "external-focus"); Directory.CreateDirectory(exchange);
        var launchOwner = new DesktopWindow("Launching external focus validation", 400, 180);
        var foregroundReady = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (Environment.GetCommandLineArgs().Contains("--interactive-focus"))
        {
            var begin = new Button { Content = "开始焦点验证" };
            begin.Click += (_, _) => foregroundReady.TrySetResult();
            launchOwner.Body.Children.Add(begin);
        }
        else foregroundReady.TrySetResult();
        launchOwner.Show();
        // A real click supplies foreground permission when this test is launched
        // by an automation host that Windows does not allow to steal focus.
        try { await foregroundReady.Task.WaitAsync(TimeSpan.FromSeconds(60)); }
        catch { launchOwner.Close(); throw; }
        var start = new ProcessStartInfo(Environment.ProcessPath!) { UseShellExecute = false, CreateNoWindow = true };
        start.ArgumentList.Add("--focus-owner"); start.ArgumentList.Add(exchange);
        using var child = Process.Start(start) ?? throw new Exception("External focus process did not start.");
        var caption = new CaptionWindow(() => Task.CompletedTask);
        try
        {
            Check(ActivationNative.AllowSetForegroundWindow((uint)child.Id), "Cannot grant the test child foreground permission.");
            await File.WriteAllTextAsync(Path.Combine(exchange, "allow-show"), "ready");
            await Until(() => File.Exists(Path.Combine(exchange, "owner.json")) || child.HasExited, "External focus process did not become ready.");
            Check(!child.HasExited, "External focus process exited early.");
            using var state = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(exchange, "owner.json")));
            var handle = (nint)state.RootElement.GetProperty("window").GetInt64();
            var focus = (nint)state.RootElement.GetProperty("focus").GetInt64();
            Check(state.RootElement.GetProperty("processId").GetInt32() == child.Id && focus != 0, "Invalid external focus owner.");
            await Until(() => ActivationNative.GetForegroundWindow() == handle, "External process never became foreground; cannot test passive display.");
            caption.Reset(false); caption.Update(new("first", "source", "Passive external-process caption", true, new("test", 0)));
            caption.ShowWithoutActivation();
            CheckExternalFocus(handle, focus);
            await Until(() => caption.IsUserVisible && caption.Content.XamlRoot.IsHostVisible, "External passive caption did not initialize.");
            for (var i = 0; i < 20; i++) { CheckExternalFocus(handle, focus); await Task.Delay(10); }
            caption.Hide();
            Check(!caption.IsUserVisible && caption.AppWindow.IsVisible && !caption.AppWindow.IsShownInSwitchers, "Caption did not retain its hidden surface.");
            caption.Update(new("second", "source", "Updated while hidden", true, new("test", 1)));
            caption.ShowWithoutActivation(); CheckExternalFocus(handle, focus);
            for (var i = 0; i < 20; i++) { CheckExternalFocus(handle, focus); await Task.Delay(10); }
            await File.WriteAllTextAsync(Path.Combine(exchange, "verified.json"), JsonSerializer.Serialize(new { externalProcessId = child.Id, firstShowAndRestore = true, foregroundAndFocus = true, physicalTyping = "not-tested" }));
        }
        finally
        {
            caption.Close(); launchOwner.Close();
            await File.WriteAllTextAsync(Path.Combine(exchange, "stop"), "stop");
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            try { await child.WaitForExitAsync(timeout.Token); }
            catch (OperationCanceledException) { child.Kill(); await child.WaitForExitAsync(); }
        }
        Check(child.ExitCode == 0, $"External focus process did not exit cleanly (0x{child.ExitCode:X8}).");
    }
    private static void CheckExternalFocus(nint window, nint focus)
    {
        Check(ActivationNative.GetForegroundWindow() == window, "Caption stole foreground from another process.");
        var info = new ActivationNative.GuiThreadInfo { Size = (uint)Marshal.SizeOf<ActivationNative.GuiThreadInfo>() };
        Check(ActivationNative.GetGUIThreadInfo(ActivationNative.GetWindowThreadProcessId(window, out _), ref info) && info.Focus == focus,
            "Caption changed the other process keyboard focus.");
    }
    private static async Task PassiveCaption()
    {
        var owner = new DesktopWindow("Caption focus test", 440, 220);
        var input = new TextBox { Text = "Keep typing here" }; owner.Body.Children.Add(input);
        var caption = new CaptionWindow(() => Task.CompletedTask);
        try
        {
            owner.Show();
            await Until(() => input.IsLoaded, "Focus owner did not load.");
            input.Focus(FocusState.Programmatic);
            var active = ActivationNative.GetActiveWindow();
            var focus = ActivationNative.GetFocus();
            caption.Reset(false); caption.Update(new("first", "source", "First visible caption", true, new("test", 0)));
            caption.ShowWithoutActivation();
            await Until(() => caption.IsUserVisible && caption.Content.XamlRoot.IsHostVisible, "Passive first show did not initialize XAML visibility.");
            Check(ActivationNative.GetActiveWindow() == active, "Caption changed the active application window.");
            Check(ActivationNative.GetFocus() == focus, "Caption did not restore keyboard focus to the owner.");
            var position = caption.AppWindow.Position;
            caption.Hide();
            Check(!caption.IsUserVisible && caption.AppWindow.IsVisible && !caption.AppWindow.IsShownInSwitchers, "Caption was not parked outside the switcher.");
            caption.Update(new("next", "source", "Updated while hidden", true, new("test", 1)));
            await Task.Delay(200);
            Check(caption.AppWindow.Position.X >= GetSystemMetrics(76) + GetSystemMetrics(78), "Hidden layout brought the caption back onscreen.");
            caption.ShowWithoutActivation();
            await Until(() => caption.IsUserVisible, "Caption did not become visible after hiding.");
            Check(caption.AppWindow.Position.X == position.X && caption.AppWindow.Position.Y == position.Y, "Caption did not restore its saved position.");
            Check(ActivationNative.GetActiveWindow() == active && ActivationNative.GetFocus() == focus, "Restoring caption stole focus.");
            Check(Field<TextBlock>(caption, "original").Text == "First visible caption Updated while hidden",
                "Restoring compact captions lost or reordered the running text updated while hidden.");
        }
        finally { caption.Close(); owner.Close(); }
    }
    private static async Task FirstRevealCancellation()
    {
        var caption = new CaptionWindow(() => Task.CompletedTask);
        try
        {
            caption.ShowWithoutActivation();
            caption.Hide();
            await Task.Delay(600);
            Check(!caption.IsUserVisible && !caption.AppWindow.IsShownInSwitchers,
                "A delayed first-frame callback restored a hidden caption.");
            caption.ShowWithoutActivation();
            await Until(() => caption.IsUserVisible && caption.Content.XamlRoot.IsHostVisible,
                "Caption could not restore after canceling first reveal.");
            caption.Hide(); caption.Hide();
            Check(!caption.IsUserVisible, "Repeated hide restored the caption.");
        }
        finally { caption.Close(); }
        var closing = new CaptionWindow(() => Task.CompletedTask);
        closing.ShowWithoutActivation(); closing.Close();
        await Task.Delay(600);
        Check(!closing.IsUserVisible, "First reveal continued after window close.");
    }
    private static class ActivationNative
    {
        [StructLayout(LayoutKind.Sequential)] internal struct GuiThreadInfo
        {
            internal uint Size, Flags;
            internal nint Active, Focus, Capture, MenuOwner, MoveSize, Caret;
            internal int Left, Top, Right, Bottom;
        }
        [DllImport("user32.dll")] internal static extern bool AllowSetForegroundWindow(uint process);
        [DllImport("user32.dll")] internal static extern nint GetForegroundWindow();
        [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint window, out uint process);
        [DllImport("user32.dll")] internal static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
        [DllImport("user32.dll")] internal static extern nint GetActiveWindow();
        [DllImport("user32.dll")] internal static extern nint GetFocus();
    }
}
