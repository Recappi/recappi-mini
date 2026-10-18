using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Recappi.Core;

namespace Recappi.WinUI.Tests;

// Real pointer input against the glass recorder: a button inside the drag region must
// still click, and empty pill surface must move the window. Moves the system cursor.
internal static class RecorderInputProbe
{
    public static async Task Run(string root)
    {
        await using var host = new TestHost(Path.Combine(root, "input-probe"));
        var recorder = new RecorderWindow(host, () => ([new AudioSource("system", "系统声音 · 所有应用")], [new MicrophoneDevice("sample", "验证麦克风", true)]));
        GetCursorPos(out var cursor);
        try
        {
            await recorder.RefreshDevices(); recorder.Show();
            await TestApp.Until(() => recorder.IsUserVisible, "Recorder did not appear.");
            await Task.Delay(1200);
            var chip = TestApp.Field<Button>(recorder, "optionsChip");
            var options = TestApp.Field<Flyout>(recorder, "options");
            var opened = false; options.Opened += (_, _) => opened = true;
            Click(Center(recorder, chip));
            await Task.Delay(600);
            var clicked = opened; options.Hide(); await Task.Delay(300);
            var start = recorder.AppWindow.Position;
            var scale = recorder.Content.XamlRoot.RasterizationScale;
            // Top padding above the control row is plain pill surface.
            // The 6-point gap after the source chip is plain pill surface (edges are resize borders).
            var source = TestApp.Field<Button>(recorder, "source");
            var origin = source.TransformToVisual(null).TransformPoint(new Windows.Foundation.Point(source.ActualWidth + 3, source.ActualHeight / 2));
            var client = ClientOrigin(recorder);
            var press = (X: client.X + (int)(origin.X * scale), Y: client.Y + (int)(origin.Y * scale));
            Drag(press, -80, 40);
            await Task.Delay(600);
            var moved = recorder.AppWindow.Position.X != start.X || recorder.AppWindow.Position.Y != start.Y;
            var result = new { buttonClicked = clicked, surfaceDragged = moved, start = new { start.X, start.Y }, end = new { recorder.AppWindow.Position.X, recorder.AppWindow.Position.Y } };
            await File.WriteAllTextAsync(Path.Combine(root, "input-probe.json"), System.Text.Json.JsonSerializer.Serialize(result));
            Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(result));
        }
        finally { SetCursorPos(cursor.X, cursor.Y); recorder.Close(); }
    }
    private static (int X, int Y) ClientOrigin(Window window)
    {
        var point = new Point();
        ClientToScreen(WinRT.Interop.WindowNative.GetWindowHandle(window), ref point);
        return (point.X, point.Y);
    }
    private static (int X, int Y) Center(Window window, FrameworkElement element)
    {
        var scale = window.Content.XamlRoot.RasterizationScale;
        var origin = element.TransformToVisual(null).TransformPoint(new Windows.Foundation.Point(element.ActualWidth / 2, element.ActualHeight / 2));
        var client = ClientOrigin(window);
        return (client.X + (int)(origin.X * scale), client.Y + (int)(origin.Y * scale));
    }
    private static void Click((int X, int Y) at)
    {
        SetCursorPos(at.X, at.Y); Thread.Sleep(80);
        mouse_event(0x0002, 0, 0, 0, 0); Thread.Sleep(60); mouse_event(0x0004, 0, 0, 0, 0);
    }
    private static void Drag((int X, int Y) at, int dx, int dy)
    {
        SetCursorPos(at.X, at.Y); Thread.Sleep(80);
        mouse_event(0x0002, 0, 0, 0, 0); Thread.Sleep(120);
        // Real input events (not SetCursorPos) so the system move loop sees the motion.
        int left = GetSystemMetrics(76), top = GetSystemMetrics(77), width = GetSystemMetrics(78), height = GetSystemMetrics(79);
        for (var i = 1; i <= 10; i++)
        {
            var x = at.X + dx * i / 10; var y = at.Y + dy * i / 10;
            mouse_event(0x0001 | 0x8000 | 0x4000, (uint)((x - left) * 65535L / (width - 1)), (uint)((y - top) * 65535L / (height - 1)), 0, 0); Thread.Sleep(30);
        }
        Thread.Sleep(80); mouse_event(0x0004, 0, 0, 0, 0);
    }
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
    [DllImport("user32.dll")] private static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] private static extern bool ClientToScreen(nint window, ref Point point);
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint x, uint y, uint data, nint extra);
}
