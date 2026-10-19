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
    // Real pointer moves over the hide button: XAML hover must start and end exactly at its edges.
    public static async Task Hover(string root)
    {
        await using var host = new TestHost(Path.Combine(root, "hover-probe"));
        var recorder = new RecorderWindow(host, () => ([new AudioSource("system", "System")], [new MicrophoneDevice("sample", "Mic", true)]));
        GetCursorPos(out var cursor);
        var log = new List<string>();
        try
        {
            await recorder.RefreshDevices(); recorder.Show();
            await TestApp.Until(() => recorder.IsUserVisible, "Recorder did not appear.");
            recorder.AppWindow.Move(new Windows.Graphics.PointInt32(300, 300)); await Task.Delay(1200);
            var row = (Grid)Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(TestApp.Field<Button>(recorder, "optionsChip"));
            var hide = row.Children.OfType<Button>().ElementAt(3);
            var inside = false; hide.PointerEntered += (_, _) => inside = true; hide.PointerExited += (_, _) => inside = false;
            var clicks = 0; hide.Click += (_, _) => clicks++;
            var scale = recorder.Content.XamlRoot.RasterizationScale;
            var origin = hide.TransformToVisual(null).TransformPoint(new Windows.Foundation.Point()); var client = ClientOrigin(recorder);
            int left = client.X + (int)Math.Round(origin.X * scale), top = client.Y + (int)Math.Round(origin.Y * scale);
            int width = (int)Math.Round(hide.ActualWidth * scale), height = (int)Math.Round(hide.ActualHeight * scale);
            var under = WindowFromPoint(new Point { X = left + width / 2, Y = top + height / 2 });
            if (GetAncestor(under, 2) != WinRT.Interop.WindowNative.GetWindowHandle(recorder)) throw new Exception("Probe recorder is not under the cursor target; aborting real input.");
            async Task At(string label, int x, int y)
            {
                Move(x, y); await Task.Delay(160);
                log.Add($"{label} ({x - left},{y - top}) hover={inside}");
            }
            var sweepX = new List<string>(); var sweepY = new List<string>();
            for (var dx = -4; dx <= width + 4; dx += 2) { Move(left + dx, top + height / 2); await Task.Delay(70); sweepX.Add($"{dx}:{(inside ? 1 : 0)}"); }
            for (var dy = -4; dy <= height + 4; dy += 2) { Move(left + width / 2, top + dy); await Task.Delay(70); sweepY.Add($"{dy}:{(inside ? 1 : 0)}"); }
            log.Add("x " + string.Join(" ", sweepX)); log.Add("y " + string.Join(" ", sweepY));
            var nc = new List<string>();
            EnumChildWindows(WinRT.Interop.WindowNative.GetWindowHandle(recorder), (child, _) => { GetWindowRect(child, out var r); nc.Add(ClassOf(child) + $" [{r.Left - client.X},{r.Top - client.Y},{r.Right - client.X},{r.Bottom - client.Y}]"); return true; }, 0);
            log.Add("children " + string.Join(" | ", nc)); log.Add($"button client px ({left - client.X},{top - client.Y}) {width}x{height}");
            Console.WriteLine($"button {width}x{height} px");
            foreach (var line in log) Console.WriteLine(line);
        }
        finally { SetCursorPos(cursor.X, cursor.Y); recorder.Close(); }
    }
    // Pressing a control and moving drags the whole pill without clicking it; a still press clicks.
    public static async Task DragFromControl(string root)
    {
        await using var host = new TestHost(Path.Combine(root, "drag-probe"));
        var recorder = new RecorderWindow(host, () => ([new AudioSource("system", "System")], [new MicrophoneDevice("sample", "Mic", true)]));
        GetCursorPos(out var cursor);
        try
        {
            await recorder.RefreshDevices(); recorder.Show();
            await TestApp.Until(() => recorder.IsUserVisible, "Recorder did not appear.");
            recorder.AppWindow.Move(new Windows.Graphics.PointInt32(300, 300)); await Task.Delay(1200);
            var chip = TestApp.Field<Button>(recorder, "optionsChip");
            var options = TestApp.Field<Flyout>(recorder, "options");
            var opened = 0; options.Opened += (_, _) => opened++;
            var at = Center(recorder, chip);
            if (GetAncestor(WindowFromPoint(new Point { X = at.X, Y = at.Y }), 2) != WinRT.Interop.WindowNative.GetWindowHandle(recorder)) throw new Exception("Probe recorder is not under the cursor target; aborting real input.");
            Click(at); await Task.Delay(600);
            var clicked = opened; options.Hide(); await Task.Delay(400);
            var start = recorder.AppWindow.Position;
            // Input from a worker thread so the UI thread keeps pumping during the drag.
            var from = Center(recorder, chip); await Task.Run(() => Drag(from, 70, 30)); await Task.Delay(600);
            var moved = recorder.AppWindow.Position;
            var activated = GetForegroundWindow() == WinRT.Interop.WindowNative.GetWindowHandle(recorder);
            var result = new { activated, at = new { at.X, at.Y }, start = new { start.X, start.Y }, clickOpenedFlyout = clicked > 0, dragMoved = new { dx = moved.X - start.X, dy = moved.Y - start.Y }, dragOpenedFlyout = opened > clicked };
            Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(result));
            options.Hide();
        }
        finally { SetCursorPos(cursor.X, cursor.Y); recorder.Close(); }
    }
    private static void Move(int x, int y)
    {
        int left = GetSystemMetrics(76), top = GetSystemMetrics(77), width = GetSystemMetrics(78), height = GetSystemMetrics(79);
        mouse_event(0x0001 | 0x8000 | 0x4000, (uint)((x - left) * 65535L / (width - 1)), (uint)((y - top) * 65535L / (height - 1)), 0, 0);
    }
    [DllImport("user32.dll")] private static extern nint WindowFromPoint(Point point);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern nint GetAncestor(nint window, uint flags);
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
    // Wheel messages posted to the window's content bridge (the system cursor is not moved,
    // so other apps never receive input); returns how far the scroll viewer moved.
    public static async Task<object> Wheel(Window window, ScrollViewer viewer, FrameworkElement over)
    {
        var before = viewer.VerticalOffset;
        var at = Center(window, over);
        var top = WinRT.Interop.WindowNative.GetWindowHandle(window);
        var targets = new List<nint>();
        EnumChildWindows(top, (child, _) => { targets.Add(child); return true; }, 0);
        var lParam = (nint)(((at.Y & 0xFFFF) << 16) | (at.X & 0xFFFF));
        foreach (var target in targets.Count > 0 ? targets : [top])
            for (var i = 0; i < 3; i++) { PostMessage(target, 0x020A, unchecked((nint)(uint)(-120 << 16)), lParam); await Task.Delay(100); }
        await Task.Delay(600);
        return new { scrollable = viewer.ScrollableHeight, before, after = viewer.VerticalOffset, children = targets.Select(x => { GetWindowRect(x, out var r); return ClassOf(x) + $" [{r.Left},{r.Top},{r.Right},{r.Bottom}] visible={IsWindowVisible(x)}"; }).ToArray(), cursorAt = new { at.X, at.Y } };
    }
    private delegate bool ChildProc(nint window, nint parameter);
    [StructLayout(LayoutKind.Sequential)] private struct Rect { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] private static extern bool GetWindowRect(nint window, out Rect rect);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(nint window);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(nint parent, ChildProc proc, nint parameter);
    [DllImport("user32.dll")] private static extern bool PostMessage(nint window, uint message, nint wParam, nint lParam);
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
    private static string ClassOf(nint window) { var name = new System.Text.StringBuilder(256); _ = GetClassName(window, name, 256); var title = new System.Text.StringBuilder(256); _ = GetWindowText(window, title, 256); return name + " / " + title; }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassName(nint window, System.Text.StringBuilder name, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowText(nint window, System.Text.StringBuilder name, int count);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] private static extern bool ClientToScreen(nint window, ref Point point);
    [DllImport("user32.dll")] private static extern void mouse_event(uint flags, uint x, uint y, uint data, nint extra);
}
