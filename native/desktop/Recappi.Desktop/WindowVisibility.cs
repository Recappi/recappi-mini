using System;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace Recappi.Desktop;

/// <summary>Keep native windows reachable using physical monitor work-area coordinates.</summary>
public static class WindowVisibility
{
    public static readonly DependencyProperty EnabledProperty = DependencyProperty.RegisterAttached("Enabled", typeof(bool), typeof(WindowVisibility), new PropertyMetadata(false, EnabledChanged));
    private static readonly DependencyProperty ObserverProperty = DependencyProperty.RegisterAttached("Observer", typeof(Observer), typeof(WindowVisibility));
    public static bool GetEnabled(DependencyObject value) => (bool)value.GetValue(EnabledProperty);
    public static void SetEnabled(DependencyObject value, bool enabled) => value.SetValue(EnabledProperty, enabled);
    private static void EnabledChanged(DependencyObject value, DependencyPropertyChangedEventArgs args)
    {
        if (value is not Window window) return;
        (window.GetValue(ObserverProperty) as Observer)?.Dispose();
        window.SetValue(ObserverProperty, (bool)args.NewValue ? new Observer(window) : null);
    }

    public static Rect Constrain(Rect bounds, Rect work)
    {
        if (bounds.IsEmpty || work.IsEmpty || work.Width <= 0 || work.Height <= 0) return bounds;
        return new Rect(Math.Clamp(bounds.Left, work.Left, Math.Max(work.Left, work.Right - bounds.Width)),
            Math.Clamp(bounds.Top, work.Top, Math.Max(work.Top, work.Bottom - bounds.Height)), bounds.Width, bounds.Height);
    }

    public static bool EnsureVisible(Window window)
    {
        if (!window.IsVisible || window.WindowState != WindowState.Normal || !TryGetGeometry(window, out var handle, out var bounds, out var work)) return false;
        var target = Constrain(bounds, work);
        if (target.Location == bounds.Location) return true;
        return SetWindowPos(handle, IntPtr.Zero, (int)target.Left, (int)target.Top, 0, 0, 0x0001 | 0x0004 | 0x0010 | 0x0200);
    }

    public static void PlaceTopRight(Window window, double margin)
    {
        if (!TryGetGeometry(window, out var handle, out var bounds, out var work)) return;
        var dpi = VisualTreeHelper.GetDpi(window);
        var target = Constrain(new Rect(work.Right - bounds.Width - margin * dpi.DpiScaleX,
            work.Top + margin * dpi.DpiScaleY, bounds.Width, bounds.Height), work);
        SetWindowPos(handle, IntPtr.Zero, (int)target.Left, (int)target.Top, 0, 0, 0x0001 | 0x0004 | 0x0010 | 0x0200);
    }

    private static bool TryGetGeometry(Window window, out IntPtr handle, out Rect bounds, out Rect work)
    {
        handle = new WindowInteropHelper(window).Handle; bounds = work = Rect.Empty;
        if (handle == IntPtr.Zero || !GetWindowRect(handle, out var rectangle)) return false;
        var monitor = MonitorFromRect(ref rectangle, 2); // MONITOR_DEFAULTTONEAREST, including negative-coordinate displays.
        var info = new MonitorInfo { Size = Marshal.SizeOf<MonitorInfo>() };
        if (monitor == IntPtr.Zero || !GetMonitorInfo(monitor, ref info)) return false;
        bounds = rectangle.ToRect(); work = info.Work.ToRect();
        return !bounds.IsEmpty && !work.IsEmpty;
    }

    private sealed class Observer : IDisposable
    {
        private readonly Window window;
        private HwndSource? source;
        private DispatcherOperation? pending;
        private bool moving;
        private bool disposed;
        public Observer(Window window)
        {
            this.window = window;
            window.SourceInitialized += Initialize;
            window.IsVisibleChanged += VisibleChanged;
            window.SizeChanged += SizeChanged;
            window.StateChanged += StateChanged;
            window.Closed += Closed;
            if (new WindowInteropHelper(window).Handle != IntPtr.Zero) Initialize(window, EventArgs.Empty);
        }
        private void Initialize(object? sender, EventArgs args)
        {
            source = HwndSource.FromHwnd(new WindowInteropHelper(window).Handle);
            source?.AddHook(Message); Queue();
        }
        private void Queue()
        {
            if (disposed || moving || !window.IsVisible || pending?.Status == DispatcherOperationStatus.Pending) return;
            pending = window.Dispatcher.BeginInvoke(DispatcherPriority.Loaded, () =>
            {
                pending = null;
                if (!disposed && !moving) EnsureVisible(window);
            });
        }
        private IntPtr Message(IntPtr handle, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
        {
            // Let WPF apply WM_DPICHANGED's suggested rectangle before our queued check.
            switch (message)
            {
                case 0x0231: moving = true; break; // WM_ENTERSIZEMOVE
                case 0x0232: moving = false; Queue(); break; // WM_EXITSIZEMOVE
                case 0x007e: // WM_DISPLAYCHANGE
                case 0x02e0: // WM_DPICHANGED
                case 0x001a: Queue(); break; // WM_SETTINGCHANGE (including work area)
            }
            return IntPtr.Zero;
        }
        private void VisibleChanged(object sender, DependencyPropertyChangedEventArgs args) => Queue();
        private void SizeChanged(object sender, SizeChangedEventArgs args) => Queue();
        private void StateChanged(object? sender, EventArgs args) => Queue();
        private void Closed(object? sender, EventArgs args) => Dispose();
        public void Dispose()
        {
            if (disposed) return;
            disposed = true; pending?.Abort(); pending = null; source?.RemoveHook(Message); source = null;
            window.SourceInitialized -= Initialize; window.IsVisibleChanged -= VisibleChanged;
            window.SizeChanged -= SizeChanged; window.StateChanged -= StateChanged; window.Closed -= Closed;
        }
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left, Top, Right, Bottom;
        public readonly Rect ToRect() => Right > Left && Bottom > Top ? new Rect(Left, Top, (double)Right - Left, (double)Bottom - Top) : Rect.Empty;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct MonitorInfo { public int Size; public NativeRect Monitor, Work; public uint Flags; }
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetWindowRect(IntPtr handle, out NativeRect rectangle);
    [DllImport("user32.dll")] private static extern IntPtr MonitorFromRect(ref NativeRect rectangle, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetWindowPos(IntPtr handle, IntPtr after, int x, int y, int width, int height, uint flags);
}
