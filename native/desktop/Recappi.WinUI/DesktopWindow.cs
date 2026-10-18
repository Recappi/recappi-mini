using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Windowing;
using Windows.Graphics;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml.Automation;

namespace Recappi.WinUI;

internal class DesktopWindow : Window
{
    public Microsoft.UI.Dispatching.DispatcherQueue UiDispatcher { get; } = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
    public StackPanel Body { get; } = new() { Spacing = 10, Padding = new Thickness(16) };
    protected TextBlock Error { get; } = Ui.Text("");
    private bool dialogOpen;
    private bool closed;
    private bool resizeQueued;
    private bool initialized;
    private bool retainSurface;
    private PointInt32? retainedPosition;
    private double retainedScale;
    private bool retainedSwitcherVisibility;
    private Control? keyboardEntry;
    private bool requestKeyboardFocus;
    private FirstFrameReveal? firstReveal;
    public bool IsUserVisible => !closed && retainedPosition is null && AppWindow.IsVisible;
    internal Func<string, string, string, Task<bool>>? ConfirmAction { get; set; }
    public DesktopWindow(string title, int width, int height)
    {
        Title = title;
        SystemBackdrop = new Microsoft.UI.Xaml.Media.MicaBackdrop();
        Content = new ScrollViewer { Content = Body, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        ResizeLogical(width, height);
        AppWindow.SetIcon(Path.Combine(AppContext.BaseDirectory, "Assets", "Recappi.ico"));
        Error.Visibility = Visibility.Collapsed;
        Body.Children.Add(Error);
        if (AppWindow.Presenter is OverlappedPresenter presenter) presenter.PreferredMinimumWidth = (int)(360 * Scale);
        Activated += (_, args) =>
        {
            if (args.WindowActivationState == WindowActivationState.Deactivated || closed) return;
            initialized = true; EnsureVisible(); InitializeKeyboardFocus();
        };
        Closed += (_, _) => { firstReveal?.Dispose(); firstReveal = null; closed = true; };
    }
    protected double Scale => retainedPosition is not null ? retainedScale : GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96d;
    protected void ResizeLogical(int width, int height) => AppWindow.Resize(new SizeInt32((int)(width * Scale), (int)(height * Scale)));
    protected void PlaceAtTopRight(double margin = 16)
    {
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var inset = (int)Math.Round(margin * Scale);
        AppWindow.Move(new PointInt32(Math.Max(area.X, area.X + area.Width - AppWindow.Size.Width - inset), area.Y + inset));
    }
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    public void Show()
    {
        if (firstReveal is not null) return;
        requestKeyboardFocus = true;
        RestoreRetainedSurface();
        EnsureVisible();
        PrepareFirstReveal();
        if (AppWindow.Presenter is OverlappedPresenter presenter && presenter.State == OverlappedPresenterState.Minimized) presenter.Restore();
        // Activate initializes the XAML window as well as showing its HWND.
        // Showing AppWindow first exposes the native surface before XAML activation.
        Activate();
        InitializeKeyboardFocus();
        firstReveal?.Arm();
    }
    private void InitializeKeyboardFocus()
    {
        if (!requestKeyboardFocus || keyboardEntry is not { IsLoaded: true } entry ||
            Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(entry.XamlRoot) is not null) return;
        entry.Focus(FocusState.Programmatic);
    }
    protected void EnsureVisible()
    {
        if (closed || retainedPosition is not null) return;
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Nearest)?.WorkArea;
        if (area is not { } work) return;
        var size = AppWindow.Size; var position = AppWindow.Position;
        if (size.Width <= 0 || size.Height <= 0 || work.Width <= 0 || work.Height <= 0) return;
        var width = Math.Min(size.Width, work.Width); var height = Math.Min(size.Height, work.Height);
        var next = new RectInt32(Math.Clamp(position.X, work.X, work.X + work.Width - width),
            Math.Clamp(position.Y, work.Y, work.Y + work.Height - height), width, height);
        if (position.X != next.X || position.Y != next.Y || size.Width != next.Width || size.Height != next.Height)
            AppWindow.MoveAndResize(next);
    }
    public void ShowWithoutActivation()
    {
        if (firstReveal is not null) return;
        requestKeyboardFocus = false;
        RestoreRetainedSurface();
        EnsureVisible(); PrepareFirstReveal(); AppWindow.Show(false);
        // WinUI initializes XAML visibility on the first WM_ACTIVATE, not Show(false).
        // SetActiveWindow only changes this UI thread's active window; unlike bringing
        // a window to the foreground, it does not activate a background application.
        if (!initialized)
        {
            var previous = GetActiveWindow();
            SetActiveWindow(WinRT.Interop.WindowNative.GetWindowHandle(this));
            SetActiveWindow(previous);
        }
        firstReveal?.Arm();
    }
    [DllImport("user32.dll")] private static extern nint GetActiveWindow();
    [DllImport("user32.dll")] private static extern nint SetActiveWindow(nint window);
    public void Hide()
    {
        if (firstReveal is not null)
        {
            firstReveal.Dispose(); firstReveal = null;
            AppWindow.Move(new PointInt32(GetSystemMetrics(76) + GetSystemMetrics(78) + 64, GetSystemMetrics(77)));
            if (GetActiveWindow() == WinRT.Interop.WindowNative.GetWindowHandle(this)) SetActiveWindow(0);
        }
        if (closed || retainedPosition is not null) return;
        if (!retainSurface || !initialized || !AppWindow.IsVisible) { AppWindow.Hide(); return; }
        foreach (var popup in Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(Content.XamlRoot)) popup.IsOpen = false;
        retainedScale = Scale;
        retainedPosition = AppWindow.Position;
        retainedSwitcherVisibility = AppWindow.IsShownInSwitchers;
        AppWindow.IsShownInSwitchers = false;
        // Keep the composed surface alive, outside every monitor. Layout updates must
        // not clamp it back onto the desktop while it is logically hidden.
        AppWindow.Move(new PointInt32(GetSystemMetrics(76) + GetSystemMetrics(78) + 64, GetSystemMetrics(77)));
        _ = DwmFlush();
        if (GetActiveWindow() == WinRT.Interop.WindowNative.GetWindowHandle(this)) SetActiveWindow(0);
    }
    private void RestoreRetainedSurface()
    {
        if (closed || retainedPosition is not { } position) return;
        AppWindow.Move(position);
        retainedPosition = null;
        AppWindow.IsShownInSwitchers = retainedSwitcherVisibility;
        EnsureVisible();
        _ = DwmFlush();
    }
    private void PrepareFirstReveal()
    {
        if (!retainSurface || initialized || closed) return;
        retainedScale = Scale; retainedPosition = AppWindow.Position;
        retainedSwitcherVisibility = AppWindow.IsShownInSwitchers;
        AppWindow.IsShownInSwitchers = false;
        try
        {
            firstReveal = new FirstFrameReveal(this, () =>
            {
                firstReveal = null;
                RestoreRetainedSurface();
                InitializeKeyboardFocus();
            });
        }
        catch
        {
            // Use normal showing if the OS cannot create the temporary region.
            RestoreRetainedSurface();
        }
    }
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    [DllImport("dwmapi.dll")] private static extern int DwmFlush();
    protected void CompactChrome(string moveLabel, int maximumHeight = 420, string surfaceBrush = "ApplicationPageBackgroundThemeBrush")
    {
        retainSurface = true;
        // Floating recording/caption panels use an opaque surface for legibility over other apps.
        SystemBackdrop = null;
        ExtendsContentIntoTitleBar = true;
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            // Keep the native resize border. Removing both border and title bar
            // reproduces a Windowing.Core heap error even in a one-button window.
            presenter.SetBorderAndTitleBar(true, false); presenter.IsMaximizable = false; presenter.IsAlwaysOnTop = true;
            presenter.PreferredMinimumHeight = (int)Math.Ceiling(44 * Scale);
        }
        var scroll = (ScrollViewer)Content;
        scroll.VerticalContentAlignment = VerticalAlignment.Top;
        Content = null;
        var grip = new ContentControl { Content = new FontIcon { Glyph = "\uE784", FontSize = 10, Opacity = 0.45 }, Width = 18,
            IsTabStop = true, UseSystemFocusVisuals = true, VerticalContentAlignment = VerticalAlignment.Center, HorizontalContentAlignment = HorizontalAlignment.Center };
        keyboardEntry = grip;
        grip.Loaded += (_, _) => InitializeKeyboardFocus();
        AutomationProperties.SetName(grip, moveLabel); ToolTipService.SetToolTip(grip, "拖动；聚焦后用方向键移动");
        grip.KeyDown += (_, e) =>
        {
            var step = (int)Math.Round(10 * Scale); var position = AppWindow.Position;
            switch (e.Key)
            {
                case Windows.System.VirtualKey.Left: position.X -= step; break;
                case Windows.System.VirtualKey.Right: position.X += step; break;
                case Windows.System.VirtualKey.Up: position.Y -= step; break;
                case Windows.System.VirtualKey.Down: position.Y += step; break;
                default: return;
            }
            AppWindow.Move(position); EnsureVisible(); e.Handled = true;
        };
        var layout = new Grid(); layout.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); layout.ColumnDefinitions.Add(new ColumnDefinition());
        layout.Children.Add(grip); Grid.SetColumn(scroll, 1); layout.Children.Add(scroll);
        // The native frame already supplies the outline and corner clipping.
        // A second rounded outline inside it creates uneven concentric borders.
        var border = (Border)Microsoft.UI.Xaml.Markup.XamlReader.Load("<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Background='{ThemeResource " + surfaceBrush + "}'/>");
        border.Child = layout;
        var frame = (Grid)Microsoft.UI.Xaml.Markup.XamlReader.Load("<Grid xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Background='{ThemeResource " + surfaceBrush + "}'/>");
        frame.Children.Add(border); Content = frame;
        // Let Windows own drag hit testing instead of starting a nested move loop
        // from a XAML pointer event, which can arrive after the release event.
        SetTitleBar(grip);
        // The native non-client edge remains visible around borderless WinUI windows.
        // Keep that edge in the same theme as the floating content surface.
        border.ActualThemeChanged += (_, _) => UpdateFloatingFrame(border);
        border.Loaded += (_, _) => UpdateFloatingFrame(border);
        Body.VerticalAlignment = VerticalAlignment.Top;
        Body.LayoutUpdated += (_, _) =>
        {
            if (dialogOpen || closed || resizeQueued) return;
            var desiredHeight = (int)Math.Ceiling(Math.Clamp(Body.DesiredSize.Height, 50, maximumHeight) * Scale);
            if (Math.Abs(AppWindow.ClientSize.Height - desiredHeight) <= 1) return;
            resizeQueued = true;
            DispatcherQueue.TryEnqueue(() =>
            {
                resizeQueued = false;
                if (dialogOpen || closed) return;
                var height = (int)Math.Ceiling(Math.Clamp(Body.DesiredSize.Height, 50, maximumHeight) * Scale);
                if (Math.Abs(AppWindow.ClientSize.Height - height) > 1)
                {
                    // ResizeClient overestimates the non-client height with
                    // this hidden-caption presenter. Use its measured edge.
                    var nonClientHeight = AppWindow.Size.Height - AppWindow.ClientSize.Height;
                    AppWindow.Resize(new SizeInt32(AppWindow.Size.Width, height + nonClientHeight));
                    EnsureVisible();
                }
            });
        };
    }
    private void UpdateFloatingFrame(Border surface)
    {
        if (closed || surface.Background is not Microsoft.UI.Xaml.Media.SolidColorBrush brush) return;
        var color = brush.Color;
        var nativeColor = (uint)(color.R | (color.G << 8) | (color.B << 16));
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        // DWMWA_BORDER_COLOR and DWMWA_CAPTION_COLOR (Windows 11).
        _ = DwmSetWindowAttribute(handle, 34, ref nativeColor, sizeof(uint));
        _ = DwmSetWindowAttribute(handle, 35, ref nativeColor, sizeof(uint));
    }
    [DllImport("dwmapi.dll")] private static extern int DwmSetWindowAttribute(nint window, int attribute, ref uint value, int size);
    public async Task Run(Func<Task> action)
    {
        try { SetError(""); await action(); }
        catch (OperationCanceledException) { SetError("操作已取消。"); }
        catch (Exception error) { SetError(error.Message); }
    }
    protected void SetError(string value) { Error.Text = value; Error.Visibility = string.IsNullOrEmpty(value) ? Visibility.Collapsed : Visibility.Visible; }
    public async Task<bool> Confirm(string title, string message, string action)
    {
        if (ConfirmAction is { } confirmation) return await confirmation(title, message, action);
        if (dialogOpen) return false;
        dialogOpen = true;
        var size = AppWindow.Size;
        var enlarge = size.Height < 340 * Scale;
        try
        {
            if (enlarge) { AppWindow.Resize(new SizeInt32(Math.Max(size.Width, (int)(440 * Scale)), (int)(340 * Scale))); EnsureVisible(); }
            var dialog = new ContentDialog { XamlRoot = Content.XamlRoot, Title = title, Content = Ui.Text(message),
                RequestedTheme = ((FrameworkElement)Content).ActualTheme,
                PrimaryButtonText = action, CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close };
            return await dialog.ShowAsync() == ContentDialogResult.Primary;
        }
        finally { dialogOpen = false; if (enlarge) { AppWindow.Resize(size); EnsureVisible(); } }
    }
    public void ApplyTheme(string theme)
    {
        ((FrameworkElement)Content).RequestedTheme = theme switch
        { "dark" => ElementTheme.Dark, "light" => ElementTheme.Light, _ => ElementTheme.Default };
        if (AppWindowTitleBar.IsCustomizationSupported())
            AppWindow.TitleBar.PreferredTheme = theme switch
            { "dark" => TitleBarTheme.Dark, "light" => TitleBarTheme.Light, _ => TitleBarTheme.UseDefaultAppMode };
    }
}

internal static class Ui
{
    public static TextBlock Text(string value, double size = 14) => new()
    {
        Text = value, FontSize = size, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true,
        FontWeight = size >= 20 ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal
    };
    public static Border Surface(UIElement child, Thickness padding)
    {
        var border = (Border)Microsoft.UI.Xaml.Markup.XamlReader.Load("<Border xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' CornerRadius='8' BorderThickness='1' Background='{ThemeResource CardBackgroundFillColorDefaultBrush}' BorderBrush='{ThemeResource CardStrokeColorDefaultBrush}'/>");
        border.Padding = padding; border.Child = child; return border;
    }
    public static Button Button(string label, Func<Task> action, DesktopWindow owner)
    {
        var button = new Button { Content = label, Padding = new Thickness(10, 6, 10, 6), FontSize = 13, MinHeight = 34,
            HorizontalContentAlignment = HorizontalAlignment.Center, VerticalContentAlignment = VerticalAlignment.Center, CornerRadius = new CornerRadius(6) };
        if (label is "开始录音" or "发送" or "连接账号") button.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        var glyph = label switch
        {
            "开始录音" or "录音控制" => "\uE7C8", "停止并保存" => "\uE71A", "录音库" => "\uE8F1", "设置" => "\uE713",
            "账号" or "连接账号" => "\uE77B", "字幕" => "\uE8D2", "隐藏" => "\uE8A7", "退出" => "\uE8AC",
            "刷新" or "刷新任务" or "刷新声音设备" => "\uE72C", "导入音频" => "\uE898", "导出文字" or "音频副本" => "\uE896",
            "打开目录" => "\uE8B7", "丢弃录音" or "删除云端录音" => "\uE74D", "发送" => "\uE724", _ => null
        };
        if (glyph is not null)
        {
            var labelText = new TextBlock { Text = label, FontSize = 13, IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Center };
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
            content.Children.Add(new FontIcon { Glyph = glyph, FontSize = 16, Width = 16, Height = 16, IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Center });
            content.Children.Add(labelText); button.Content = content;
        }
        AutomationProperties.SetName(button, label);
        var running = false;
        button.Click += async (_, _) =>
        {
            if (running) return;
            running = true;
            try { await owner.Run(action); }
            finally { running = false; }
        };
        return button;
    }
    public static Button IconButton(string label, string glyph, Func<Task> action, DesktopWindow owner)
    {
        var button = Button(label, action, owner); button.Content = new FontIcon { Glyph = glyph, FontSize = 14 };
        button.Style = (Style)Application.Current.Resources["SubtleButtonStyle"];
        button.Width = 34; button.Height = 34; button.Padding = new Thickness(6); ToolTipService.SetToolTip(button, label);
        return button;
    }
    public static WrapPanel Row(params UIElement[] items)
    {
        var panel = new WrapPanel();
        foreach (var item in items) panel.Children.Add(item);
        return panel;
    }
}

internal sealed class WrapPanel : Panel
{
    private const double Gap = 8;
    protected override Windows.Foundation.Size MeasureOverride(Windows.Foundation.Size available)
    {
        double x = 0, y = 0, rowHeight = 0, width = 0;
        foreach (var child in Children)
        {
            if (child.Visibility == Visibility.Collapsed) continue;
            child.Measure(new Windows.Foundation.Size(available.Width, available.Height));
            var size = child.DesiredSize;
            if (x > 0 && x + size.Width > available.Width) { width = Math.Max(width, x - Gap); x = 0; y += rowHeight + Gap; rowHeight = 0; }
            x += size.Width + Gap; rowHeight = Math.Max(rowHeight, size.Height);
        }
        return new Windows.Foundation.Size(Math.Max(width, Math.Max(0, x - Gap)), y + rowHeight);
    }
    protected override Windows.Foundation.Size ArrangeOverride(Windows.Foundation.Size final)
    {
        double x = 0, y = 0, rowHeight = 0;
        var row = new List<(UIElement Child, double X, Windows.Foundation.Size Size)>();
        void ArrangeRow()
        {
            foreach (var item in row) item.Child.Arrange(new Windows.Foundation.Rect(item.X, y + (rowHeight - item.Size.Height) / 2, item.Size.Width, item.Size.Height));
            row.Clear();
        }
        foreach (var child in Children)
        {
            if (child.Visibility == Visibility.Collapsed) continue;
            var size = child.DesiredSize;
            if (x > 0 && x + size.Width > final.Width) { ArrangeRow(); x = 0; y += rowHeight + Gap; rowHeight = 0; }
            row.Add((child, x, size));
            x += size.Width + Gap; rowHeight = Math.Max(rowHeight, size.Height);
        }
        ArrangeRow();
        return final;
    }
}
