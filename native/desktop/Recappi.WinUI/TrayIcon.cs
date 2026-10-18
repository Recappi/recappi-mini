using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;

namespace Recappi.WinUI;

// Shell notification area integration; every application window remains WinUI 3.
internal sealed class TrayIcon : IDisposable
{
    private const uint Callback = 0x8001;
    private readonly nint window;
    private readonly SubclassProc callback;
    private readonly Action restore;
    private readonly Action quit;
    private readonly nint idleIcon;
    private readonly nint activeIcon;
    private readonly uint taskbarCreated;
    private bool recording;
    private bool disposed;
    private Action? notificationClicked;
    private readonly (string Label, Action Action)[] menuActions;
    public TrayIcon(Window owner, Action restore, Action quit, params (string Label, Action Action)[] menuActions)
    {
        this.restore = restore; this.quit = quit;
        this.menuActions = menuActions;
        window = WinRT.Interop.WindowNative.GetWindowHandle(owner);
        idleIcon = LoadImage(0, Path.Combine(AppContext.BaseDirectory, "Assets", "Recappi.ico"), 1, 0, 0, 0x10 | 0x40);
        activeIcon = LoadImage(0, Path.Combine(AppContext.BaseDirectory, "Assets", "Recappi.Recording.ico"), 1, 0, 0, 0x10 | 0x40);
        taskbarCreated = RegisterWindowMessage("TaskbarCreated");
        callback = HandleMessage;
        if (!SetWindowSubclass(window, callback, 1, 0)) throw new InvalidOperationException("无法连接系统托盘。");
        Update(false, true);
    }
    private NotifyData Data() => new() { Size = (uint)Marshal.SizeOf<NotifyData>(), Window = window, Id = 1,
        Flags = 1 | 2 | 4, CallbackMessage = Callback, Icon = recording ? activeIcon : idleIcon,
        Tip = recording ? "Recappi Mini · 录音中" : "Recappi Mini", Info = "", InfoTitle = "" };
    public void Update(bool active, bool add = false)
    {
        recording = active;
        var data = Data();
        if (!Shell_NotifyIcon(add ? 0u : 1u, ref data) && add) throw new InvalidOperationException("无法显示系统托盘图标。");
    }
    public void Notify(string title, string message, Action? clicked = null)
    {
        notificationClicked = clicked;
        var data = Data(); data.Flags |= 0x10; data.InfoTitle = title; data.Info = message; data.InfoFlags = 1;
        Shell_NotifyIcon(1, ref data);
    }
    private nint HandleMessage(nint hwnd, uint message, nuint wParam, nint lParam, nuint id, nuint data)
    {
        if (message == taskbarCreated) { Update(recording, true); return 0; }
        if (message == Callback)
        {
            var notification = (uint)((long)lParam & 0xffff);
            if (notification is 0x202 or 0x203) restore();
            else if (notification == 0x405) { var action = notificationClicked; notificationClicked = null; if (action is not null) action(); else restore(); }
            else if (notification is 0x205 or 0x7b)
            {
                var menu = CreatePopupMenu();
                try
                {
                    AppendMenu(menu, 0, 1, "显示录音面板"); AppendMenu(menu, 0, 2, "退出");
                    for (var index = 0; index < menuActions.Length; index++) AppendMenu(menu, 0, (nuint)(index + 3), menuActions[index].Label);
                    GetCursorPos(out var position); SetForegroundWindow(window);
                    var selected = TrackPopupMenu(menu, 0x100 | 0x2, position.X, position.Y, 0, window, 0);
                    if (selected == 1) restore(); else if (selected == 2) quit();
                    else if (selected >= 3 && selected < menuActions.Length + 3) menuActions[selected - 3].Action();
                }
                finally { DestroyMenu(menu); }
            }
            return 0;
        }
        return DefSubclassProc(hwnd, message, wParam, lParam);
    }
    public void ClearNotificationAction() => notificationClicked = null;
    public void Dispose()
    {
        if (disposed) return; disposed = true;
        var data = Data(); Shell_NotifyIcon(2, ref data);
        RemoveWindowSubclass(window, callback, 1);
        if (idleIcon != 0) DestroyIcon(idleIcon);
        if (activeIcon != 0) DestroyIcon(activeIcon);
    }
    private delegate nint SubclassProc(nint hwnd, uint message, nuint wParam, nint lParam, nuint id, nuint data);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] private struct NotifyData
    {
        public uint Size; public nint Window; public uint Id; public uint Flags; public uint CallbackMessage; public nint Icon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Tip;
        public uint State; public uint StateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Info;
        public uint Timeout;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string InfoTitle;
        public uint InfoFlags; public Guid Guid; public nint BalloonIcon;
    }
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X; public int Y; }
    [DllImport("comctl32.dll")] private static extern bool SetWindowSubclass(nint hwnd, SubclassProc callback, nuint id, nuint data);
    [DllImport("comctl32.dll")] private static extern bool RemoveWindowSubclass(nint hwnd, SubclassProc callback, nuint id);
    [DllImport("comctl32.dll")] private static extern nint DefSubclassProc(nint hwnd, uint message, nuint wParam, nint lParam);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] private static extern bool Shell_NotifyIcon(uint action, ref NotifyData data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern nint LoadImage(nint instance, string name, uint type, int width, int height, uint flags);
    [DllImport("user32.dll")] private static extern bool DestroyIcon(nint icon);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern uint RegisterWindowMessage(string name);
    [DllImport("user32.dll")] private static extern nint CreatePopupMenu();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern bool AppendMenu(nint menu, uint flags, nuint id, string text);
    [DllImport("user32.dll")] private static extern uint TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint hwnd, nint rect);
    [DllImport("user32.dll")] private static extern bool DestroyMenu(nint menu);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out Point point);
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint hwnd);
}
