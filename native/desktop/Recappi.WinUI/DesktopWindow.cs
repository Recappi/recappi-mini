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
        var page = new ScrollViewer { Content = Body, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Language = "zh-CN" };
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
    // Page windows open centred on the display the user is working on (like macOS), and stay
    // centred while they size themselves to their content until the user moves them.
    private PointInt32? centeredAt;
    private void CenterOnCursorDisplay()
    {
        var display = GetCursorPos(out var cursor) ? DisplayArea.GetFromPoint(new PointInt32(cursor.X, cursor.Y), DisplayAreaFallback.Primary) : DisplayArea.Primary;
        var area = display.WorkArea; var size = AppWindow.Size;
        var position = new PointInt32(area.X + Math.Max(0, (area.Width - size.Width) / 2), area.Y + Math.Max(0, (area.Height - size.Height) / 2));
        AppWindow.Move(position); centeredAt = position;
    }
    // Dialog-like pages size their height to the content (macOS settings and account panels),
    // capped by the work area, where the scroll viewer takes over.
    protected void FitHeightTo(ScrollViewer scroll, double minimum = 240)
    {
        var fit = DispatcherQueue.CreateTimer(); fit.Interval = TimeSpan.FromMilliseconds(30); fit.IsRepeating = false;
        fit.Tick += (_, _) =>
        {
            if (closed || scroll.XamlRoot is not { } root || scroll.ViewportHeight <= 0) return;
            var scale = root.RasterizationScale;
            var client = AppWindow.ClientSize.Height / scale;
            var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea.Height / scale;
            // The content's desired height: its extent never drops below the viewport.
            var content = scroll.Content is UIElement element ? element.DesiredSize.Height : scroll.ExtentHeight;
            var target = Math.Clamp(client - scroll.ViewportHeight + content, minimum, area * 0.9);
            if (Math.Abs(target - client) < 2) return;
            // Adjust the outer size by the difference: ResizeClient misjudges the extended title bar.
            var delta = (int)Math.Round((target - client) * scale);
            AppWindow.Resize(new SizeInt32(AppWindow.Size.Width, AppWindow.Size.Height + delta));
            if (centeredAt is { } centre && AppWindow.Position.X == centre.X && AppWindow.Position.Y == centre.Y)
            { var moved = new PointInt32(centre.X, centre.Y - delta / 2); AppWindow.Move(moved); centeredAt = moved; }
            EnsureVisible();
        };
        void Schedule(object? sender, object args) { if (!closed && !fit.IsRunning) fit.Start(); }
        scroll.LayoutUpdated += Schedule;
        Closed += (_, _) => { fit.Stop(); scroll.LayoutUpdated -= Schedule; };
    }
    protected double Scale => retainedPosition is not null ? retainedScale : GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96d;
    protected void ResizeLogical(int width, int height) => AppWindow.Resize(new SizeInt32((int)(width * Scale), (int)(height * Scale)));
    protected void PlaceAtTopRight(double margin = 16)
    {
        margin -= ChromeMargin; // The visible pill keeps the requested inset.
        var area = DisplayArea.GetFromWindowId(AppWindow.Id, DisplayAreaFallback.Primary).WorkArea;
        var inset = (int)Math.Round(margin * Scale);
        AppWindow.Move(new PointInt32(Math.Max(area.X, area.X + area.Width - AppWindow.Size.Width - inset), area.Y + inset));
    }
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    public void Show()
    {
        if (firstReveal is not null) return;
        if (pillCarrier) { ShowWithoutActivation(); return; } // Panels never take activation.
        if (!initialized && !floating) CenterOnCursorDisplay();
        requestKeyboardFocus = true;
        RestoreRetainedSurface();
        EnsureVisible();
        PrepareFirstReveal();
        if (AppWindow.Presenter is OverlappedPresenter presenter && presenter.State == OverlappedPresenterState.Minimized) presenter.Restore();
        // Activate initializes the XAML window as well as showing its HWND.
        // Showing AppWindow first exposes the native surface before XAML activation.
        Activate();
        BringToFront();
        InitializeKeyboardFocus();
        firstReveal?.Arm();
    }
    // Opened from the non-activating recorder, this app is not the foreground app, so Activate
    // alone leaves the window behind the current one. The click that opened it was our input,
    // which lets SetForegroundWindow succeed; if the system still refuses, a synthetic Alt press
    // (the documented foreground-lock release) lets it through.
    private void BringToFront()
    {
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        if (GetForegroundWindow() == handle || SetForegroundWindow(handle)) return;
        keybd_event(0x12, 0, 0, 0); keybd_event(0x12, 0, 0x0002, 0);
        _ = SetForegroundWindow(handle);
    }
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, nint extra);
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
                // Clearing the first-reveal window region resets DWM's frame extension.
                if (pillCarrier) ExtendCarrierFrame();
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
        // Toolbar windows use the tall caption (48) so the system buttons share the toolbar's centre line.
        if (toolbar is not null && AppWindowTitleBar.IsCustomizationSupported()) AppWindow.TitleBar.PreferredHeightOption = TitleBarHeightOption.Tall;
        var strip = new Grid { Height = toolbar is null ? 40 : 48, Padding = new Thickness(14, 0, 0, 0), ColumnSpacing = 12, Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent) };
        strip.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); strip.ColumnDefinitions.Add(new ColumnDefinition());
        strip.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); strip.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(toolbar is null ? 0 : 138) });
        var brand = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
        // Toolbar pages lead with the account in the sidebar, so the title stands alone (macOS window title).
        if (toolbar is null) { var tile = RecappiTheme.LogoTile(20); tile.VerticalAlignment = VerticalAlignment.Center; brand.Children.Add(tile); }
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
        var frame = new Grid { Language = "zh-CN" }; // Han text falls back to the Chinese face (see RecappiTheme.Ensure).
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
    // Transparent margin around a self-drawn pill, holding its shadow.
    public double ChromeMargin { get; private set; }
    protected void CompactChrome(string moveLabel, int maximumHeight = 420, string surfaceBrush = "ApplicationPageBackgroundThemeBrush", bool glass = false, int minimumHeight = 50, bool directCaption = false, bool pill = false, string pillFill = "RecappiPillFill", string pillStroke = "RecappiPillStroke")
    {
        retainSurface = true; floating = true;
        // Floating caption panels use an opaque surface for legibility over other apps;
        // the caption strip uses always-active acrylic glass. The recorder pill is drawn by
        // the app as a 14pt squircle on a transparent window (no system blur can follow that shape).
        SystemBackdrop = null;
        if (pill)
        {
            glass = true; directCaption = true; ChromeMargin = 12;
            EnablePillCarrier();
            surfaceBrush = "RecappiTransparent";
        }
        else if (glass && !EnableGlass()) { glass = false; surfaceBrush = "RecappiSurfacePanel"; }
        else if (glass) surfaceBrush = "RecappiGlassFill";
        // Direct caption: no WinUI title bar handling (it reserves a 1px top strip that showed as a
        // light line); drag and passthrough regions are set on the non-client source directly.
        ExtendsContentIntoTitleBar = !directCaption;
        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            // Keep the native resize border. Removing both border and title bar
            // reproduces a Windowing.Core heap error even in a one-button window.
            presenter.SetBorderAndTitleBar(true, false); presenter.IsMaximizable = false; presenter.IsAlwaysOnTop = true;
            presenter.PreferredMinimumHeight = (int)Math.Ceiling(Math.Min(44, minimumHeight) * Scale);
        }
        if (pill) ApplyPopupStyle(); // The presenter just re-added its border bit.
        // Windows 11 rounds and shadows the floating frame; earlier versions ignore it. The self-drawn
        // pill opts out (DWMWCP_DONOTROUND) so no rectangular system shadow or border surrounds it.
        var corner = pill ? 1u : 2u; _ = DwmSetWindowAttribute(WinRT.Interop.WindowNative.GetWindowHandle(this), 33, ref corner, sizeof(uint));
        if (pill) { var none = 0xFFFFFFFEu; _ = DwmSetWindowAttribute(WinRT.Interop.WindowNative.GetWindowHandle(this), 34, ref none, sizeof(uint)); }
        var scroll = (ScrollViewer)Content;
        scroll.VerticalContentAlignment = VerticalAlignment.Top; scroll.Background = null;
        // No scroll bar in floating panels: its hidden 12pt strip on the right edge took the
        // pointer from the controls beneath it (the record button's hover stopped short).
        scroll.VerticalScrollBarVisibility = ScrollBarVisibility.Hidden;
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
        if (pill)
        {
            // Shadow caster (rounded rect) under the squircle body; both inside the transparent margin.
            frame.Padding = new Thickness(ChromeMargin);
            var caster = new Border { CornerRadius = new CornerRadius(16), Margin = new Thickness(1), Translation = new System.Numerics.Vector3(0, 0, 18), Shadow = new Microsoft.UI.Xaml.Media.ThemeShadow() };
            RecappiTheme.Bind(caster, pillFill, brush => caster.Background = brush);
            var body = Squircles.Surface(new Grid(), 14, new Thickness(0));
            var shape = Squircles.ShapeOf(body); shape.StrokeThickness = 1;
            RecappiTheme.Bind(body, pillFill, brush => shape.Fill = brush);
            RecappiTheme.Bind(body, pillStroke, brush => shape.Stroke = brush);
            frame.Children.Add(caster); frame.Children.Add(body);
            pillSurface = body;
            DragAnywhere(frame);
        }
        frame.Language = "zh-CN"; frame.Children.Add(border); Content = frame;
        // Let Windows own drag hit testing instead of starting a nested move loop
        // from a XAML pointer event, which can arrive after the release event.
        if (glass)
        {
            // The pill moves itself (DragAnywhere); other floating panels use caption regions.
            if (!pill)
            {
                if (directCaption) frame.SizeChanged += (_, _) => UpdatePassthrough(frame);
                else SetTitleBar(frame);
                Body.LayoutUpdated += (_, _) => UpdatePassthrough(frame);
            }
            // The zero-width move target keeps arrow-key moving without drawing an outline;
            // a programmatic first focus was being reported as keyboard focus and rimmed the pill in green.
            if (!pill)
            {
                border.ActualThemeChanged += (_, _) => UpdateGlass(border);
                border.Loaded += (_, _) => UpdateGlass(border);
            }
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
            var desiredHeight = (int)Math.Ceiling((Math.Clamp(Body.DesiredSize.Height, minimumHeight, maximumHeight) + ChromeMargin * 2) * Scale);
            if (Math.Abs(AppWindow.ClientSize.Height - desiredHeight) <= 1) return;
            resizeQueued = true;
            DispatcherQueue.TryEnqueue(() =>
            {
                resizeQueued = false;
                if (dialogOpen || closed) return;
                var height = (int)Math.Ceiling((Math.Clamp(Body.DesiredSize.Height, minimumHeight, maximumHeight) + ChromeMargin * 2) * Scale);
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
    private Grid? pillSurface;
    // The whole pill drags like a macOS panel, moved by the app itself rather than a system move loop
    // (which activates the window and only starts after the system drag threshold): the window
    // follows the real cursor every rendered frame while the button is held. A press on the background
    // drags at once; a press on a control drags past 3pt, which cancels its press so it does not click.
    private void DragAnywhere(FrameworkElement root)
    {
        PointInt32 pressCursor = default, pressWindow = default; UIElement? pressed = null;
        var threshold = 0d; var dragging = false; var tracking = false;
        void Frame(object? sender, object args)
        {
            if (closed || (GetAsyncKeyState(0x01) & 0x8000) == 0 || !GetCursorPos(out var cursor)) { Stop(); return; }
            int dx = cursor.X - pressCursor.X, dy = cursor.Y - pressCursor.Y;
            if (!dragging)
            {
                if (Math.Abs(dx) < threshold && Math.Abs(dy) < threshold) return;
                dragging = true;
                // Outside the render callback: changing pointer capture during Rendering fails fast.
                var target = pressed;
                DispatcherQueue.TryEnqueue(() =>
                {
                    for (DependencyObject? up = target; up is not null; up = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(up))
                        if (up is UIElement element) element.ReleasePointerCaptures();
                });
            }
            var next = new PointInt32(pressWindow.X + dx, pressWindow.Y + dy);
            if (next.X != AppWindow.Position.X || next.Y != AppWindow.Position.Y) AppWindow.Move(next);
        }
        void Stop()
        {
            if (!tracking) return;
            tracking = false; Microsoft.UI.Xaml.Media.CompositionTarget.Rendering -= Frame;
            if (dragging) EnsureVisible();
            dragging = false;
        }
        root.AddHandler(UIElement.PointerPressedEvent, new Microsoft.UI.Xaml.Input.PointerEventHandler((_, e) =>
        {
            if (!e.GetCurrentPoint(root).Properties.IsLeftButtonPressed || !GetCursorPos(out var cursor)) return;
            pressCursor = new PointInt32(cursor.X, cursor.Y); pressWindow = AppWindow.Position; pressed = e.OriginalSource as UIElement;
            var onControl = false;
            for (DependencyObject? up = pressed; up is not null && !ReferenceEquals(up, root); up = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(up))
                if (up is Control { IsEnabled: true } and (Microsoft.UI.Xaml.Controls.Primitives.ButtonBase or ComboBox or ToggleSwitch or TextBox)) { onControl = true; break; }
            threshold = onControl ? 3 * Scale : 0; dragging = false;
            if (!tracking) { tracking = true; Microsoft.UI.Xaml.Media.CompositionTarget.Rendering += Frame; }
        }), true);
        Closed += (_, _) => Stop();
    }
    private bool pillCarrier;
    private Windows.UI.Composition.Compositor? carrierCompositor;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? passThroughTimer;
    // Transparent carrier for the self-drawn pill, following ScreenCam's toolbar host: a borderless
    // layered popup, the whole client extended into the DWM frame (zero-alpha black redirection
    // pixels are transparent), black background erase and a clear system backdrop brush.
    private void EnablePillCarrier()
    {
        pillCarrier = true;
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        RemoveFrame(eraseToBlack: true);
        ApplyPopupStyle();
        _ = SetLayeredWindowAttributes(handle, 0, 255, 0x2);
        ExtendCarrierFrame();
        AppWindow.Changed += (_, args) => { if (args.DidSizeChange && !closed) ExtendCarrierFrame(); };
        DispatcherQueue.EnsureSystemDispatcherQueue();
        carrierCompositor = new Windows.UI.Composition.Compositor();
        WinRT.CastExtensions.As<Microsoft.UI.Composition.ICompositionSupportsSystemBackdrop>(this).SystemBackdrop =
            carrierCompositor.CreateColorBrush(Windows.UI.Color.FromArgb(0, 0, 0, 0));
        // The shadow margin lets clicks through to the windows behind, as on macOS: while the
        // pointer is over the window but outside the pill, the window is made input-transparent.
        passThroughTimer = DispatcherQueue.CreateTimer(); passThroughTimer.Interval = TimeSpan.FromMilliseconds(30);
        var transparent = false; var buttonDown = false;
        passThroughTimer.Tick += (_, _) =>
        {
            if (closed) return;
            KeepTopmost();
            if (!GetCursorPos(out var point)) return;
            var position = AppWindow.Position; var size = AppWindow.Size; var inset = (int)Math.Round(ChromeMargin * Scale);
            var inWindow = point.X >= position.X && point.X < position.X + size.Width && point.Y >= position.Y && point.Y < position.Y + size.Height;
            var inPill = point.X >= position.X + inset && point.X < position.X + size.Width - inset && point.Y >= position.Y + inset && point.Y < position.Y + size.Height - inset;
            // Never while a popover is open: it overlaps the margin and must keep its pointer input.
            var open = Content?.XamlRoot is { } xamlRoot ? Microsoft.UI.Xaml.Media.VisualTreeHelper.GetOpenPopupsForXamlRoot(xamlRoot) : [];
            var popups = open.Count > 0;
            // The non-activating window never loses activation, so popovers dismiss themselves when a
            // button goes down outside the pill and outside every open popover.
            var down = (GetAsyncKeyState(0x01) & 0x8000) != 0 || (GetAsyncKeyState(0x02) & 0x8000) != 0;
            var pressed = down && !buttonDown; buttonDown = down;
            if (popups && pressed && !OwnWindowAt(point)) foreach (var popup in open) popup.IsOpen = false;
            var next = inWindow && !inPill && !popups;
            if (next == transparent) return;
            transparent = next;
            var ex = GetWindowLongPtr(handle, -20);
            _ = SetWindowLongPtr(handle, -20, next ? ex | 0x00000020 : ex & ~(nint)0x00000020);
        };
        passThroughTimer.Start();
        Closed += (_, _) => passThroughTimer?.Stop();
    }
    // Borderless, non-activating popup like ScreenCam's toolbar host and the macOS panel. Activation
    // let DWM paint the active-frame tint into the extended glass (a blue bar in the shadow margin)
    // and gave the pill a focus state. (The presenter keeps its WS_BORDER bit; with no non-client
    // area it draws nothing.)
    private void ApplyPopupStyle()
    {
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        var style = (long)GetWindowLongPtr(handle, -16);
        var popup = (style & ~(0x00C00000L | 0x00800000L | 0x00400000L | 0x00040000L | 0x00080000L | 0x00020000L | 0x00010000L)) | 0x80000000L;
        var ex = (long)GetWindowLongPtr(handle, -20);
        var noActivate = ex | 0x00080000L | 0x08000000L;
        if (popup == style && noActivate == ex) return;
        _ = SetWindowLongPtr(handle, -16, (nint)popup);
        _ = SetWindowLongPtr(handle, -20, (nint)noActivate);
        _ = SetWindowPos(handle, 0, 0, 0, 0, 0, 0x0020 | 0x0002 | 0x0001 | 0x0004 | 0x0010);
    }
    // A press on any window of this app (the pill, an open popover) is not outside.
    private static bool OwnWindowAt(NativePoint point)
    {
        var root = GetAncestor(WindowFromPoint(point), 2);
        return root != 0 && GetWindowThreadProcessId(root, out var process) != 0 && process == Environment.ProcessId;
    }
    [DllImport("user32.dll")] private static extern nint WindowFromPoint(NativePoint point);
    [DllImport("user32.dll")] private static extern nint GetAncestor(nint window, uint flags);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out uint process);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int key);
    private void ExtendCarrierFrame()
    {
        ApplyPopupStyle();
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        _ = DwmExtendFrameIntoClientArea(handle, [-1, -1, -1, -1]);
        // Erase the whole redirection surface (frame included) to black, i.e. transparent. Without
        // RDW_FRAME, pixels drawn before the carrier (the system caption: title text, a tinted
        // button strip) and stale areas after a resize stayed visible in the shadow margin.
        _ = RedrawWindow(handle, 0, 0, 0x0001 | 0x0004 | 0x0080 | 0x0400);
        KeepTopmost();
    }
    // The carrier's popup restyle drops the presenter's always-on-top band; assert it on the window itself.
    private void KeepTopmost()
    {
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        if ((GetWindowLongPtr(handle, -20) & 0x00000008) != 0) return;
        // The presenter owns the topmost band (it vetoes z-order changes that contradict its state),
        // so re-assert it through the presenter first.
        if (AppWindow.Presenter is OverlappedPresenter presenter) { presenter.IsAlwaysOnTop = false; presenter.IsAlwaysOnTop = true; }
        if ((GetWindowLongPtr(handle, -20) & 0x00000008) == 0) _ = SetWindowPos(handle, -1, 0, 0, 0, 0, 0x0002 | 0x0001 | 0x0010);
    }
    // Remove the non-client frame entirely (WM_NCCALCSIZE returns the whole window as client).
    private void RemoveFrame(bool eraseToBlack = false)
    {
        if (frameProc is not null) return;
        var handle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        // WM_NCCALCSIZE: no frame. WM_ERASEBKGND on the carrier: erase to black, which the extended
        // DWM frame composes as transparent instead of the opaque class background.
        frameProc = (window, message, wParam, lParam, _, _) =>
        {
            if (message == 0x0083 && wParam != 0) return 0;
            if (message == 0x0014 && eraseToBlack)
            {
                if (GetClientRect(window, out var area)) _ = FillRect((nint)wParam, ref area, GetStockObject(4));
                return 1;
            }
            // The pill is a panel that never looks or becomes active (macOS non-activating panel):
            // clicks do not activate it, and any activation that does happen (showing, the move
            // loop) is drawn as inactive, so DWM never paints the active-frame tint into the glass.
            if (eraseToBlack && message == 0x0021) return 3; // WM_MOUSEACTIVATE → MA_NOACTIVATE
            if (eraseToBlack && message == 0x0086) return DefSubclassProc(window, message, 0, -1); // WM_NCACTIVATE as inactive, no repaint
            return DefSubclassProc(window, message, wParam, lParam);
        };
        if (SetWindowSubclass(handle, frameProc, 2, 0))
        {
            Closed += (_, _) => RemoveWindowSubclass(handle, frameProc, 2);
            _ = SetWindowPos(handle, 0, 0, 0, 0, 0, 0x0020 | 0x0002 | 0x0001 | 0x0004 | 0x0010);
        }
    }
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
        RemoveFrame();
        return true;
    }
    private delegate nint FrameProc(nint window, uint message, nuint wParam, nint lParam, nuint id, nuint data);
    private FrameProc? frameProc;
    [DllImport("comctl32.dll")] private static extern bool SetWindowSubclass(nint window, FrameProc callback, nuint id, nuint data);
    [DllImport("comctl32.dll")] private static extern bool RemoveWindowSubclass(nint window, FrameProc callback, nuint id);
    [DllImport("comctl32.dll")] private static extern nint DefSubclassProc(nint window, uint message, nuint wParam, nint lParam);
    [DllImport("dwmapi.dll")] private static extern int DwmExtendFrameIntoClientArea(nint window, int[] margins);
    [DllImport("user32.dll")] private static extern bool SetLayeredWindowAttributes(nint window, uint key, byte alpha, uint flags);
    [DllImport("user32.dll")] private static extern bool RedrawWindow(nint window, nint rect, nint region, uint flags);
    [DllImport("user32.dll")] private static extern bool GetClientRect(nint window, out NativeRect rect);
    [DllImport("user32.dll")] private static extern int FillRect(nint dc, ref NativeRect rect, nint brush);
    [DllImport("gdi32.dll")] private static extern nint GetStockObject(int index);
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out NativePoint point);
    [StructLayout(LayoutKind.Sequential)] private struct NativeRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct NativePoint { public int X, Y; }
    [DllImport("user32.dll")] private static extern bool SetWindowPos(nint window, nint after, int x, int y, int width, int height, uint flags);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern nint GetWindowLongPtr(nint window, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] private static extern nint SetWindowLongPtr(nint window, int index, nint value);
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
                    // One extra pixel around each control so rounding never leaves its edge draggable.
                    rects.Add(new((int)Math.Floor(origin.X * scale) - 1, (int)Math.Floor(origin.Y * scale) - 1, (int)Math.Ceiling(control.ActualWidth * scale) + 2, (int)Math.Ceiling(control.ActualHeight * scale) + 2));
                    continue;
                }
                Visit(child);
            }
        }
        Visit(root);
        // Without SetTitleBar the caption (drag) region is set directly, following ScreenCam's
        // toolbar: the visible surface minus the controls, so the two never overlap.
        var caption = captionRects;
        if (!ExtendsContentIntoTitleBar)
        {
            var inset = ChromeMargin;
            var surface = new Windows.Graphics.RectInt32((int)Math.Floor(inset * scale), (int)Math.Floor(inset * scale), (int)Math.Ceiling((root.ActualWidth - inset * 2) * scale), (int)Math.Ceiling((root.ActualHeight - inset * 2) * scale));
            caption = Subtract(surface, rects);
        }
        // Rewriting the regions on every layout pass (the live waveform) dropped presses.
        if (rects.SequenceEqual(passthrough) && caption.SequenceEqual(captionRects)) return;
        passthrough = rects.ToArray(); captionRects = caption; regionWrites++;
        var source = Microsoft.UI.Input.InputNonClientPointerSource.GetForWindowId(AppWindow.Id);
        if (!ExtendsContentIntoTitleBar) source.SetRegionRects(Microsoft.UI.Input.NonClientRegionKind.Caption, captionRects);
        source.SetRegionRects(Microsoft.UI.Input.NonClientRegionKind.Passthrough, passthrough);
    }
    private Windows.Graphics.RectInt32[] captionRects = [];
    private int regionWrites;
    private static Windows.Graphics.RectInt32[] Subtract(Windows.Graphics.RectInt32 bounds, IEnumerable<Windows.Graphics.RectInt32> exclusions)
    {
        var remaining = new List<Windows.Graphics.RectInt32> { bounds };
        foreach (var cut in exclusions)
        {
            var next = new List<Windows.Graphics.RectInt32>();
            foreach (var rect in remaining)
            {
                int left = Math.Max(rect.X, cut.X), top = Math.Max(rect.Y, cut.Y), right = Math.Min(rect.X + rect.Width, cut.X + cut.Width), bottom = Math.Min(rect.Y + rect.Height, cut.Y + cut.Height);
                if (right <= left || bottom <= top) { next.Add(rect); continue; }
                void Add(int x, int y, int width, int height) { if (width > 0 && height > 0) next.Add(new(x, y, width, height)); }
                Add(rect.X, rect.Y, rect.Width, top - rect.Y);
                Add(rect.X, bottom, rect.Width, rect.Y + rect.Height - bottom);
                Add(rect.X, top, left - rect.X, bottom - top);
                Add(right, top, rect.X + rect.Width - right, bottom - top);
            }
            remaining = next;
        }
        return remaining.ToArray();
    }
    public async Task Run(Func<Task> action)
    {
        try { SetError(""); await action(); }
        catch (OperationCanceledException) { /* Superseded work (e.g. selecting another recording) is not a failure. */ }
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
