using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using Recappi.Desktop;

internal static class WindowVisibilityTests
{
    public static async Task RunAsync()
    {
        var leftDisplay = new Rect(-1920, -200, 1920, 1040);
        if (WindowVisibility.Constrain(new Rect(-1800, -100, 600, 200), leftDisplay) != new Rect(-1800, -100, 600, 200)) throw new Exception("An in-bounds negative-coordinate window moved.");
        if (WindowVisibility.Constrain(new Rect(-2400, -800, 600, 200), leftDisplay) != new Rect(-1920, -200, 600, 200)) throw new Exception("Offscreen window was not clamped to the selected display.");
        if (WindowVisibility.Constrain(new Rect(-100, 800, 600, 200), leftDisplay) != new Rect(-600, 640, 600, 200)) throw new Exception("Right/bottom overflow did not respect the work area.");
        if (WindowVisibility.Constrain(new Rect(800, 900, 2000, 1600), new Rect(0, 0, 1000, 700)) != new Rect(0, 0, 2000, 1600)) throw new Exception("Oversized window lost its top-left controls or was silently resized.");

        var window = new CaptionWindow { Width = 420, Height = 260, ShowActivated = false };
        window.Show();
        await Until(() => IsInside(window));
        if (!WindowVisibility.GetEnabled(window)) throw new Exception("Production window style did not attach visibility recovery.");
        var handle = new WindowInteropHelper(window).Handle;
        var originalSize = Geometry(window).Bounds.Size;
        window.Left = -100000; window.Top = -100000;
        var foreground = GetForegroundWindow();
        if (!WindowVisibility.EnsureVisible(window) || !IsInside(window)) throw new Exception("Native offscreen recovery failed.");
        if (GetForegroundWindow() != foreground || Geometry(window).Bounds.Size != originalSize) throw new Exception("Visibility recovery activated or resized the window.");

        window.Hide(); window.Left = 100000; window.Top = 100000;
        window.Show(); await Until(() => IsInside(window));
        WindowVisibility.PlaceTopRight(window, 0);
        var before = Geometry(window).Bounds;
        window.Width += 100;
        await Until(() => IsInside(window) && Geometry(window).Bounds.Width > before.Width);
        if (Geometry(window).Bounds.Left >= before.Left) throw new Exception("Growing at the right edge did not move the window back into view.");
        window.Hide(); var hidden = Geometry(window).Bounds;
        if (WindowVisibility.EnsureVisible(window) || Geometry(window).Bounds != hidden) throw new Exception("Recovery moved a hidden window.");
        window.Close();
        Console.WriteLine("PASS native window offscreen recovery, negative-coordinate work areas, hide/restore, size growth and no focus/size changes.");
    }
    private static bool IsInside(Window window)
    {
        var (bounds, work) = Geometry(window);
        return work.Contains(bounds);
    }
    private static (Rect Bounds, Rect Work) Geometry(Window window)
    {
        var handle = new WindowInteropHelper(window).Handle;
        if (!GetWindowRect(handle, out var bounds)) throw new Exception("Test window geometry unavailable.");
        var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (!GetMonitorInfo(MonitorFromWindow(handle, 2), ref info)) throw new Exception("Test monitor geometry unavailable.");
        return (bounds.Rect, info.Work.Rect);
    }
    private static async Task Until(Func<bool> condition)
    {
        for (var attempt = 0; attempt < 100 && !condition(); attempt++) await Task.Delay(20);
        if (!condition()) throw new Exception("Window did not return to the monitor work area.");
    }
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect
    {
        public int Left, Top, Right, Bottom;
        public readonly Rect Rect => new(Left, Top, Right - Left, Bottom - Top);
    }
    [StructLayout(LayoutKind.Sequential)] private struct MonitorInfo { public int Size; public NativeRect Monitor, Work; public uint Flags; }
    [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(IntPtr handle, out NativeRect bounds);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromWindow(IntPtr handle, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetMonitorInfo(IntPtr handle, ref MonitorInfo info);
}
