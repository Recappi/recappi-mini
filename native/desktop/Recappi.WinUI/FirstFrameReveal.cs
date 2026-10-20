using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Windowing;
using Windows.Graphics;
using Recappi.Core;

namespace Recappi.WinUI;

// Bootstrap a new composition surface at the desktop edge, then prepare its
// full region offscreen before moving the live window into its intended place.
internal sealed class FirstFrameReveal : IDisposable
{
    private readonly Window window;
    private readonly Action complete;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(16) };
    private readonly Stopwatch elapsed = Stopwatch.StartNew();
    private int renders;
    private bool unclipped;
    private bool disposed;
    private bool ownsRegion;
    public FirstFrameReveal(Window window, Action complete)
    {
        this.window = window; this.complete = complete;
        var region = CreateRectRgn(0, 0, 1, 1);
        if (region == 0) throw new InvalidOperationException(L.T("无法准备窗口显示区域。", "Couldn't prepare the window region."));
        if (SetWindowRgn(Handle, region, true) == 0)
        {
            DeleteObject(region);
            throw new InvalidOperationException(L.T("无法设置窗口显示区域。", "Couldn't set the window region."));
        }
        ownsRegion = true;
        try
        {
            // The virtual desktop's bottom-right corner can be a gap between
            // monitors; use a real display so the bootstrap pixel intersects it.
            var display = DisplayArea.GetFromWindowId(window.AppWindow.Id, DisplayAreaFallback.Primary).OuterBounds;
            window.AppWindow.Move(new PointInt32(display.X + display.Width - 1, display.Y + display.Height - 1));
        }
        catch { RemoveRegion(); throw; }
        CompositionTarget.Rendering += Rendered;
        timer.Tick += Tick;
    }
    public void Arm()
    {
        if (disposed) return;
        renders = 0; elapsed.Restart();
        timer.Start();
    }
    private nint Handle => WinRT.Interop.WindowNative.GetWindowHandle(window);
    private void Rendered(object? sender, object args) => renders++;
    private void Tick(object? sender, object args)
    {
        if (disposed || elapsed.ElapsedMilliseconds < 150) return;
        // A bounded fallback must not strand a usable window offscreen when the
        // compositor stops reporting frames (for example during session changes).
        if (renders < 2 && elapsed.ElapsedMilliseconds < 1000) return;
        if (!unclipped)
        {
            window.AppWindow.Move(new PointInt32(GetSystemMetrics(76) + GetSystemMetrics(78) + 64, GetSystemMetrics(77)));
            DwmFlush();
            RemoveRegion();
            unclipped = true; renders = 0; elapsed.Restart();
            return;
        }
        DwmFlush();
        Dispose();
        complete();
    }
    private void RemoveRegion()
    {
        if (!ownsRegion) return;
        SetWindowRgn(Handle, 0, true); ownsRegion = false;
    }
    public void Dispose()
    {
        if (disposed) return;
        disposed = true; timer.Stop(); timer.Tick -= Tick;
        CompositionTarget.Rendering -= Rendered;
        RemoveRegion();
    }
    [DllImport("gdi32.dll")] private static extern nint CreateRectRgn(int left, int top, int right, int bottom);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(nint value);
    [DllImport("user32.dll")] private static extern int SetWindowRgn(nint window, nint region, bool redraw);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("dwmapi.dll")] private static extern int DwmFlush();
}
