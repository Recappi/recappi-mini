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
    private bool floating;
    private bool framed;
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
        RecappiTheme.Ensure();
        var page = new ScrollViewer { Content = Body, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        // Opaque brand surface instead of Mica, matching the macOS window colors.
        RecappiTheme.Bind(page, "RecappiSurfaceWindow", brush => { if (!floating && !framed) page.Background = brush; });
        Content = page;
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
        // Squircle chrome: size template paths after layout, including popups (flyouts, menus).
        var squircleScan = DispatcherQueue.CreateTimer(); squircleScan.Interval = TimeSpan.FromMilliseconds(60); squircleScan.IsRepeating = false;
        Closed += (_, _) => squircleScan.Stop();
        squircleScan.Tick += (_, _) =>
        {
            if (closed) return;
            XamlRoot? root;
            try { root = Content?.XamlRoot; } catch (System.Runtime.InteropServices.COMException) { return; } // Window torn down between ticks.
            if (root is null) return;
            Squircles.Track(Content);
            foreach (var popup in Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(root)) if (popup.Child is { } child) Squircles.Track(child);
        };
        void ScheduleScan(object? sender, object args) { if (!squircleScan.IsRunning) squircleScan.Start(); }
        Activated += (_, _) =>
        {
            if (closed) return;
            try { if (Content is FrameworkElement element) { element.LayoutUpdated -= ScheduleScan; element.LayoutUpdated += ScheduleScan; } }
            catch (System.Runtime.InteropServices.COMException) { return; } // Deactivation while closing.
            ScheduleScan(null, this);
        };
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
        // Pointer focus keeps keyboard navigation ready without drawing a focus rectangle on show;
        // pressing Tab switches to visible keyboard focus.
        entry.Focus(FocusState.Pointer);
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
    // Page windows draw their own title strip so the brand surface reaches the top edge.
    // The strip holds no controls: everything in it is a window drag region.
    protected Grid PageFrame(UIElement content, string page, FrameworkElement? toolbar = null, TextBlock? subtitle = null)
    {
        ExtendsContentIntoTitleBar = true;
        if (AppWindowTitleBar.IsCustomizationSupported())
        {
            AppWindow.TitleBar.ButtonBackgroundColor = Microsoft.UI.Colors.Transparent;
            AppWindow.TitleBar.ButtonInactiveBackgroundColor = Microsoft.UI.Colors.Transparent;
        }
        // With a toolbar the strip becomes a unified title bar like macOS: title on the left,
        // tools on the right ahead of the caption buttons; tools stay clickable as passthrough.
        var strip = new Grid { Height = toolbar is null ? 40 : 52, Padding = new Thickness(14, 0, 0, 0), ColumnSpacing = 12, Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        strip.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); strip.ColumnDefinitions.Add(new ColumnDefinition());
        strip.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); strip.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(toolbar is null ? 0 : 138) });
        var brand = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        var tile = RecappiTheme.LogoTile(toolbar is null ? 20 : 26); tile.VerticalAlignment = VerticalAlignment.Center; brand.Children.Add(tile);
        if (toolbar is null) brand.Children.Add(new TextBlock { Text = "Recappi", Style = RecappiTheme.Style("RecappiEyebrow") });
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        titles.Children.Add(new TextBlock { Text = page, Style = RecappiTheme.Style(toolbar is null ? "RecappiCaption" : "RecappiSectionTitle"), FontSize = toolbar is null ? 12 : 13 });
        if (subtitle is not null) { subtitle.Style = RecappiTheme.Style("RecappiCaption"); subtitle.FontSize = 11; titles.Children.Add(subtitle); }
        brand.Children.Add(titles);
        strip.Children.Add(brand);
        if (toolbar is not null)
        {
            toolbar.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(toolbar, 2); strip.Children.Add(toolbar);
            strip.LayoutUpdated += (_, _) => UpdatePassthrough(strip);
        }
        var frame = new Grid();
        frame.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); frame.RowDefinitions.Add(new RowDefinition());
        frame.Children.Add(strip);
        if (content is FrameworkElement element) { Grid.SetRow(element, 1); frame.Children.Add(element); }
        // Page windows sit on Mica, the Windows counterpart of the macOS window material;
        // content cards stay opaque. Without Mica support the brand surface is used.
        framed = true;
        if (content is ScrollViewer scroll) scroll.Background = null;
        if (Microsoft.UI.Composition.SystemBackdrops.MicaController.IsSupported()) SystemBackdrop = new Microsoft.UI.Xaml.Media.MicaBackdrop();
        else RecappiTheme.Bind(frame, "RecappiSurfaceWindow", brush => frame.Background = brush);
        SetTitleBar(strip);
        return frame;
    }
    [DllImport("dwmapi.dll")] private static extern int DwmFlush();
    protected void CompactChrome(string moveLabel, int maximumHeight = 420, string surfaceBrush = "ApplicationPageBackgroundThemeBrush", bool glass = false, int minimumHeight = 50)
    {
        retainSurface = true; floating = true;
        // Floating caption panels use an opaque surface for legibility over other apps;
        // the recorder pill uses always-active acrylic glass like the macOS panel.
        SystemBackdrop = null;
        if (glass && !EnableGlass()) { glass = false; surfaceBrush = "RecappiSurfacePanel"; }
        if (glass) surfaceBrush = "RecappiGlassFill";
        ExtendsContentIntoTitleBar = true;
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            // Keep the native resize border. Removing both border and title bar
            // reproduces a Windowing.Core heap error even in a one-button window.
            presenter.SetBorderAndTitleBar(true, false); presenter.IsMaximizable = false; presenter.IsAlwaysOnTop = true;
            presenter.PreferredMinimumHeight = (int)Math.Ceiling(Math.Min(44, minimumHeight) * Scale);
        }
        // Windows 11 rounds and shadows the floating frame; earlier versions ignore it.
        var corner = 2u; _ = DwmSetWindowAttribute(WinRT.Interop.WindowNative.GetWindowHandle(this), 33, ref corner, sizeof(uint));
        var scroll = (ScrollViewer)Content;
        scroll.VerticalContentAlignment = VerticalAlignment.Top; scroll.Background = null;
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
        if (glass)
        {
            // The whole pill drags, as on macOS. The grip stays as the keyboard move target only.
            grip.Content = null; grip.Width = 0; grip.UseSystemFocusVisuals = false; ToolTipService.SetToolTip(grip, null);
        }
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
        if (glass)
        {
            SetTitleBar(frame);
            Body.LayoutUpdated += (_, _) => UpdatePassthrough(frame);
            // The zero-width move target keeps arrow-key moving without drawing an outline;
            // a programmatic first focus was being reported as keyboard focus and rimmed the pill in green.
            border.ActualThemeChanged += (_, _) => UpdateGlass(border);
            border.Loaded += (_, _) => UpdateGlass(border);
        }
        else
        {
            SetTitleBar(grip);
            // The native non-client edge remains visible around borderless WinUI windows.
            // Keep that edge in the same theme as the floating content surface.
            border.ActualThemeChanged += (_, _) => UpdateFloatingFrame(border);
            border.Loaded += (_, _) => UpdateFloatingFrame(border);
        }
        Body.VerticalAlignment = VerticalAlignment.Top;
        Body.LayoutUpdated += (_, _) =>
        {
            if (dialogOpen || closed || resizeQueued) return;
            var desiredHeight = (int)Math.Ceiling(Math.Clamp(Body.DesiredSize.Height, minimumHeight, maximumHeight) * Scale);
            if (Math.Abs(AppWindow.ClientSize.Height - desiredHeight) <= 1) return;
            resizeQueued = true;
            DispatcherQueue.TryEnqueue(() =>
            {
                resizeQueued = false;
                if (dialogOpen || closed) return;
                var height = (int)Math.Ceiling(Math.Clamp(Body.DesiredSize.Height, minimumHeight, maximumHeight) * Scale);
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
    private Microsoft.UI.Composition.SystemBackdrops.DesktopAcrylicController? acrylic;
    private Microsoft.UI.Composition.SystemBackdrops.SystemBackdropConfiguration? backdrop;
    private Windows.Graphics.RectInt32[] passthrough = [];
    private bool EnableGlass()
    {
        if (!Microsoft.UI.Composition.SystemBackdrops.DesktopAcrylicController.IsSupported()) return false;
        // Keep the glass when inactive: the always-on-top pill rarely holds focus.
        backdrop = new() { IsInputActive = true };
        acrylic = new() { Kind = Microsoft.UI.Composition.SystemBackdrops.DesktopAcrylicKind.Thin };
        acrylic.AddSystemBackdropTarget(WinRT.CastExtensions.As<Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop>(this));
        acrylic.SetSystemBackdropConfiguration(backdrop);
        Closed += (_, _) => { acrylic?.Dispose(); acrylic = null; };
        // Make the whole window client area so no thin system frame rims the glass;
        // DWM keeps the rounded corners and shadow.
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        frameProc = (window, message, wParam, lParam, _, _) => message == 0x0083 && wParam != 0 ? 0 : DefSubclassProc(window, message, wParam, lParam);
        if (SetWindowSubclass(handle, frameProc, 2, 0))
        {
            Closed += (_, _) => RemoveWindowSubclass(handle, frameProc, 2);
            _ = SetWindowPos(handle, 0, 0, 0, 0, 0, 0x0020 | 0x0002 | 0x0001 | 0x0004 | 0x0010);
        }
        return true;
    }
    private delegate nint FrameProc(nint window, uint message, nuint wParam, nint lParam, nuint id, nuint data);
    private FrameProc? frameProc;
    [DllImport("comctl32.dll")] private static extern bool SetWindowSubclass(nint window, FrameProc callback, nuint id, nuint data);
    [DllImport("comctl32.dll")] private static extern bool RemoveWindowSubclass(nint window, FrameProc callback, nuint id);
    [DllImport("comctl32.dll")] private static extern nint DefSubclassProc(nint window, uint message, nuint wParam, nint lParam);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
    private void UpdateGlass(FrameworkElement surface)
    {
        if (closed || acrylic is null || backdrop is null) return;
        var dark = surface.ActualTheme == ElementTheme.Dark;
        backdrop.Theme = dark ? Microsoft.UI.Composition.SystemBackdrops.SystemBackdropTheme.Dark : Microsoft.UI.Composition.SystemBackdrops.SystemBackdropTheme.Light;
        acrylic.TintColor = dark ? Windows.UI.Color.FromArgb(255, 32, 32, 32) : Windows.UI.Color.FromArgb(255, 252, 252, 252);
        acrylic.TintOpacity = dark ? 0.55f : 0.5f;
        acrylic.LuminosityOpacity = dark ? 0.9f : 0.85f;
        acrylic.FallbackColor = dark ? Windows.UI.Color.FromArgb(255, 45, 45, 45) : Windows.UI.Color.FromArgb(255, 255, 255, 255);
        // No drawn outline (DWMWA_COLOR_NONE): the system shadow alone separates the glass, as on macOS.
        var none = 0xFFFFFFFEu;
        _ = DwmSetWindowAttribute(WinRT.Interop.WindowNative.GetWindowHandle(this), 34, ref none, sizeof(uint));
    }
    // The pill is one drag region; its buttons stay clickable as passthrough rectangles.
    private void UpdatePassthrough(FrameworkElement root)
    {
        if (closed || root.XamlRoot is null) return;
        var scale = root.XamlRoot.RasterizationScale;
        var rects = new List<Windows.Graphics.RectInt32>();
        void Visit(DependencyObject node)
        {
            for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(node); i++)
            {
                var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(node, i);
                if (child is UIElement { Visibility: Visibility.Collapsed }) continue;
                if (child is Control { IsTabStop: true } control and not ContentControl { Content: null, Width: 0 } && control.ActualWidth > 0)
                {
                    var origin = control.TransformToVisual(root).TransformPoint(new Windows.Foundation.Point());
                    rects.Add(new((int)Math.Floor(origin.X * scale), (int)Math.Floor(origin.Y * scale), (int)Math.Ceiling(control.ActualWidth * scale), (int)Math.Ceiling(control.ActualHeight * scale)));
                    continue;
                }
                Visit(child);
            }
        }
        Visit(root);
        if (rects.SequenceEqual(passthrough)) return;
        passthrough = rects.ToArray();
        Microsoft.UI.Input.InputNonClientPointerSource.GetForWindowId(AppWindow.Id).SetRegionRects(Microsoft.UI.Input.NonClientRegionKind.Passthrough, passthrough);
    }
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
    // Surfaces that keep one appearance regardless of the app theme (the caption scrim).
    protected bool FixedDarkTheme { get; set; }
    public void ApplyTheme(string theme)
    {
        if (FixedDarkTheme) theme = "dark";
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
    public static Grid Surface(UIElement child, Thickness padding)
    {
        var surface = Squircles.Surface(child, 10, padding);
        var shape = Squircles.ShapeOf(surface); shape.StrokeThickness = 1;
        RecappiTheme.Bind(surface, "RecappiSurfaceCard", brush => shape.Fill = brush);
        RecappiTheme.Bind(surface, "RecappiBorderHairline", brush => shape.Stroke = brush);
        return surface;
    }
    public static Button Button(string label, Func<Task> action, DesktopWindow owner)
    {
        var button = new Button { Content = label, Style = RecappiTheme.Style(label is "开始录音" or "发送" or "连接账号" or "下一步" or "开始使用" ? "RecappiPrimaryButton" : "RecappiButton") };
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
            content.Children.Add(new FontIcon { Glyph = glyph, FontSize = 14, Width = 16, Height = 16, IsHitTestVisible = false, VerticalAlignment = VerticalAlignment.Center });
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
        button.Style = RecappiTheme.Style("RecappiIconButton");
        button.Width = 32; button.Height = 32; ToolTipService.SetToolTip(button, label);
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
