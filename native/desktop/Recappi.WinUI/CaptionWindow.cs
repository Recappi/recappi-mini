using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using Recappi.Core;

namespace Recappi.WinUI;

// Live caption panel, following the macOS subtitle overlay: a fixed dark scrim in
// both themes, captions only, and controls that appear while the pointer is over it.
internal sealed class CaptionWindow : DesktopWindow
{
    private const double CompactHeight = 62;
    private const double ExpandedHeight = 184;
    private readonly Dictionary<(string Id, string Stream), CaptionDelta> segments = [];
    private readonly TextBlock status = Ui.Text("开始录音后显示字幕。");
    // Until the first caption arrives the panel says why it is empty instead of an empty dark box.
    private readonly TextBlock placeholder = new() { Text = "开始录音后显示字幕。", FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis,
        Foreground = new SolidColorBrush(Windows.UI.Color.FromArgb(150, 255, 255, 255)), IsHitTestVisible = false };
    private readonly TextBlock archiveError = Ui.Text("");
    private readonly TextBlock original = Ui.Text("", 20);
    private readonly TextBlock translation = Ui.Text("", 20);
    private readonly TextBlock originalTitle = Pane("原文");
    private readonly TextBlock translationTitle = Pane("译文");
    private readonly CheckBox showOriginal = new() { Content = "原文", IsChecked = true };
    private readonly CheckBox showTranslation = new() { Content = "翻译", IsChecked = true };
    private readonly CheckBox compact = new() { Content = "紧凑模式", IsChecked = true };
    private readonly CheckBox follow = new() { Content = "跟随最新", IsChecked = true };
    private readonly ScrollViewer originalScroll;
    private readonly ScrollViewer translationScroll;
    private readonly StackPanel originalPane = new() { Spacing = 4 };
    private readonly StackPanel translationPane = new() { Spacing = 4 };
    private readonly Grid columns = new() { ColumnSpacing = 14, RowSpacing = 1 };
    private readonly Button expand;
    private readonly ToggleButton originalToggle;
    private readonly ToggleButton translationToggle;
    private readonly Border chrome;
    private readonly FrameworkElement idleDot;
    private readonly DispatcherTimer hoverTimer = new() { Interval = TimeSpan.FromMilliseconds(120) };
    private readonly Grid stage;
    private bool hovering;
    private bool hasTranslation;
    private bool followAfterLayout;
    private bool closed;
    public CaptionWindow(Func<Task> retry) : base("Recappi Mini · 实时字幕", 566, 86)
    {
        Body.Padding = new Thickness(13, 8, 14, 8); Body.Spacing = 6; Body.MinHeight = CompactHeight;
        // A self-drawn dark squircle on a transparent window, dark in both app themes as on macOS.
        CompactChrome("移动字幕面板", 600, minimumHeight: 40, pill: true, pillFill: "RecappiCaptionPill", pillStroke: "RecappiCaptionPillStroke");

        Error.Style = RecappiTheme.Style("RecappiError"); Error.FontSize = 11.5;
        status.Style = RecappiTheme.Style("RecappiCaptionBadge"); status.IsTextSelectionEnabled = false;
        archiveError.Style = RecappiTheme.Style("RecappiError");
        original.Style = RecappiTheme.Style("RecappiCaptionOriginal"); translation.Style = RecappiTheme.Style("RecappiCaptionTranslation");
        foreach (var text in new[] { original, translation }) { text.IsTextSelectionEnabled = true; text.VerticalAlignment = VerticalAlignment.Top; }

        // Hover chrome: status badge · stream toggles · mode · options · close.
        var badge = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, Padding = new Thickness(7, 3, 7, 3), VerticalAlignment = VerticalAlignment.Center };
        var liveDot = new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 5, Height = 5, Fill = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 255, 59, 48)), VerticalAlignment = VerticalAlignment.Center };
        RecappiTheme.Pulse(liveDot).Begin();
        badge.Children.Add(liveDot); badge.Children.Add(status);
        var badgeSurface = new Border { Child = badge, CornerRadius = new CornerRadius(10), Background = new SolidColorBrush(Windows.UI.Color.FromArgb(31, 255, 59, 48)) };
        originalToggle = Segment("显示原文", ""); translationToggle = Segment("显示译文", "");
        originalToggle.Click += (_, _) => showOriginal.IsChecked = originalToggle.IsChecked;
        translationToggle.Click += (_, _) => showTranslation.IsChecked = translationToggle.IsChecked;
        var streams = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Padding = new Thickness(3, 2, 3, 2) };
        streams.Children.Add(originalToggle); streams.Children.Add(translationToggle);
        var streamSurface = new Border { Child = streams, CornerRadius = new CornerRadius(11), Background = new SolidColorBrush(Windows.UI.Color.FromArgb(20, 255, 255, 255)) };
        expand = Ui.IconButton("展开字幕历史", "", () => { compact.IsChecked = compact.IsChecked != true; return Task.CompletedTask; }, this);
        var option = Ui.IconButton("字幕选项", "", () => Task.CompletedTask, this);
        var settings = new StackPanel { Spacing = 8 }; foreach (var control in new UIElement[] { follow, Ui.Button("重新连接", retry, this) }) settings.Children.Add(control);
        option.Flyout = new Flyout { Content = settings, ShouldConstrainToRootBounds = false };
        var close = Ui.IconButton("隐藏字幕", "", () => { Hide(); return Task.CompletedTask; }, this);
        foreach (var button in new[] { expand, option, close }) { button.Width = button.Height = 22; ((FontIcon)button.Content).FontSize = 9.5; }
        var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, Padding = new Thickness(5, 2, 5, 2) };
        foreach (var item in new UIElement[] { badgeSurface, streamSurface, expand, option, close }) tools.Children.Add(item);
        chrome = new Border { Child = tools, CornerRadius = new CornerRadius(14), HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            Background = new SolidColorBrush(Windows.UI.Color.FromArgb(150, 28, 28, 30)), BorderBrush = new SolidColorBrush(Windows.UI.Color.FromArgb(36, 255, 255, 255)),
            BorderThickness = new Thickness(1), Opacity = 0, IsHitTestVisible = false };
        var dot = new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 6, Height = 6, Fill = new SolidColorBrush(Windows.UI.Color.FromArgb(255, 255, 59, 48)),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 4, 0, 0), IsHitTestVisible = false };
        RecappiTheme.Pulse(dot).Begin(); idleDot = dot;

        archiveError.Visibility = Visibility.Collapsed; Body.Children.Add(archiveError);
        originalScroll = new ScrollViewer { Content = original, MaxHeight = 280, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden };
        translationScroll = new ScrollViewer { Content = translation, MaxHeight = 280, VerticalScrollBarVisibility = ScrollBarVisibility.Hidden };
        originalPane.Children.Add(originalTitle); originalPane.Children.Add(Faded(originalScroll));
        translationPane.Children.Add(translationTitle); translationPane.Children.Add(Faded(translationScroll));
        columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(57, GridUnitType.Star) }); columns.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(43, GridUnitType.Star) });
        columns.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); columns.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetColumn(translationPane, 1);
        columns.Children.Add(originalPane); columns.Children.Add(translationPane);
        stage = new Grid(); stage.Children.Add(placeholder); stage.Children.Add(columns); stage.Children.Add(dot); stage.Children.Add(chrome);
        Body.Children.Add(stage);

        // Pointer hover over the drag surface does not reach XAML; poll the cursor instead.
        hoverTimer.Tick += (_, _) => SetHover(PointerInside());
        hoverTimer.Start();
        Closed += (_, _) => { closed = true; hoverTimer.Stop(); columns.LayoutUpdated -= FollowAfterLayout; };
        foreach (var control in new[] { showOriginal, showTranslation, compact, follow })
        { control.Checked += (_, _) => Render(); control.Unchecked += (_, _) => Render(); }
        Render();
    }
    // Older lines fade out under the top edge instead of being cut mid-line (macOS mask).
    private static Grid Faded(ScrollViewer scroll)
    {
        var fade = new LinearGradientBrush { StartPoint = new(0, 0), EndPoint = new(0, 1) };
        fade.GradientStops.Add(new GradientStop { Color = Windows.UI.Color.FromArgb(0xF7, 0x1C, 0x1C, 0x1E), Offset = 0 });
        fade.GradientStops.Add(new GradientStop { Color = Windows.UI.Color.FromArgb(0xF7, 0x1C, 0x1C, 0x1E), Offset = 0.35 });
        fade.GradientStops.Add(new GradientStop { Color = Windows.UI.Color.FromArgb(0, 0x1C, 0x1C, 0x1E), Offset = 1 });
        var mask = new Border { Height = 28, VerticalAlignment = VerticalAlignment.Top, Background = fade, IsHitTestVisible = false };
        scroll.ViewChanged += (_, _) => mask.Opacity = scroll.VerticalOffset > 0 ? 1 : 0;
        mask.Opacity = 0;
        var host = new Grid(); host.Children.Add(scroll); host.Children.Add(mask);
        return host;
    }
    private static TextBlock Pane(string text) => new()
    {
        Text = text, Style = RecappiTheme.Style("RecappiCaptionPane"), CharacterSpacing = 60, IsTextSelectionEnabled = false
    };
    private ToggleButton Segment(string name, string glyph)
    {
        var button = new ToggleButton { Content = RecappiTheme.Glyph(glyph, 10.5), Style = RecappiTheme.Style("RecappiCaptionSegment"), IsChecked = true };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, name); ToolTipService.SetToolTip(button, name);
        return button;
    }
    private bool PointerInside()
    {
        if (closed || !AppWindow.IsVisible || !GetCursorPos(out var point)) return false;
        // Only the visible pill, not the transparent shadow margin around it.
        var position = AppWindow.Position; var size = AppWindow.Size; var inset = (int)Math.Round(ChromeMargin * Scale);
        return point.X >= position.X + inset && point.X < position.X + size.Width - inset && point.Y >= position.Y + inset && point.Y < position.Y + size.Height - inset;
    }
    private void SetHover(bool value)
    {
        if (hovering == value) return;
        hovering = value;
        chrome.IsHitTestVisible = value;
        Fade(chrome, value ? 1 : 0); Fade(idleDot, value ? 0 : 1);
    }
    private static void Fade(UIElement element, double to)
    {
        var animation = new Microsoft.UI.Xaml.Media.Animation.DoubleAnimation { To = to, Duration = TimeSpan.FromMilliseconds(180),
            EasingFunction = new Microsoft.UI.Xaml.Media.Animation.ExponentialEase { EasingMode = Microsoft.UI.Xaml.Media.Animation.EasingMode.EaseOut, Exponent = 5 } };
        Microsoft.UI.Xaml.Media.Animation.Storyboard.SetTarget(animation, element);
        Microsoft.UI.Xaml.Media.Animation.Storyboard.SetTargetProperty(animation, nameof(UIElement.Opacity));
        var storyboard = new Microsoft.UI.Xaml.Media.Animation.Storyboard(); storyboard.Children.Add(animation); storyboard.Begin();
    }
    public void Reset(bool translate) { segments.Clear(); hasTranslation = translate; SetArchiveError(""); SetStatus("正在连接…"); Render(); }
    public void SetStatus(string value) { status.Text = value; placeholder.Text = value; }
    public void SetArchiveError(string value) { archiveError.Text = value; archiveError.Visibility = string.IsNullOrEmpty(value) ? Visibility.Collapsed : Visibility.Visible; }
    public void Update(CaptionDelta value)
    {
        segments[(value.SegmentId, value.Stream)] = value;
        // Keep the live window bounded; the archive holds the complete meeting.
        if (segments.Count > 256)
        {
            var first = Ordered().First(); segments.Remove((first.SegmentId, first.Stream));
        }
        Render();
    }
    public void UpdateBatch(IReadOnlyList<CaptionDelta> values)
    {
        foreach (var value in values) segments[(value.SegmentId, value.Stream)] = value;
        foreach (var value in Ordered().Take(Math.Max(0, segments.Count - 256)).ToArray()) segments.Remove((value.SegmentId, value.Stream));
        Render();
    }
    private IEnumerable<CaptionDelta> Ordered() => segments.Values.OrderBy(x => x.Position?.Sequence ?? long.MaxValue).ThenBy(x => x.Position?.ContentIndex ?? 0);
    private void Render()
    {
        if (originalScroll is null) return;
        placeholder.Visibility = segments.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        translationToggle.Visibility = hasTranslation ? Visibility.Visible : Visibility.Collapsed;
        showTranslation.Visibility = hasTranslation ? Visibility.Visible : Visibility.Collapsed;
        var sourceVisible = showOriginal.IsChecked == true;
        var translationVisible = hasTranslation && showTranslation.IsChecked == true;
        if (!sourceVisible && !translationVisible) { showOriginal.IsChecked = true; sourceVisible = true; }
        originalToggle.IsChecked = sourceVisible; translationToggle.IsChecked = translationVisible;
        originalPane.Visibility = sourceVisible ? Visibility.Visible : Visibility.Collapsed;
        translationPane.Visibility = translationVisible ? Visibility.Visible : Visibility.Collapsed;
        var isCompact = compact.IsChecked == true;
        var both = sourceVisible && translationVisible;
        // Compact stacks the streams; expanded places them side by side at 57/43.
        Grid.SetColumn(translationPane, isCompact ? 0 : 1); Grid.SetRow(translationPane, isCompact ? 1 : 0);
        columns.ColumnDefinitions[0].Width = isCompact || sourceVisible ? new GridLength(57, GridUnitType.Star) : new GridLength(0);
        columns.ColumnDefinitions[1].Width = !isCompact && translationVisible ? new GridLength(43, GridUnitType.Star) : new GridLength(0);
        columns.ColumnSpacing = isCompact || !both ? 0 : 14;
        originalTitle.Visibility = translationTitle.Visibility = isCompact ? Visibility.Collapsed : Visibility.Visible;
        translationTitle.Text = "译文";
        if (isCompact)
        {
            original.FontSize = translation.FontSize = 12.5; original.LineHeight = translation.LineHeight = 15;
            original.FontWeight = translation.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
            // Two lines for one stream, one line each when bilingual.
            originalScroll.MaxHeight = translationScroll.MaxHeight = both ? 15 : 31;
            Body.Padding = new Thickness(13, 8, 14, 8); Body.MinHeight = CompactHeight;
            // Center the caption block in the fixed-height compact strip.
            stage.MinHeight = CompactHeight - 16; columns.VerticalAlignment = VerticalAlignment.Center;
        }
        else
        {
            original.FontSize = 16; original.LineHeight = 22; original.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
            translation.FontSize = 15; translation.LineHeight = 21; translation.FontWeight = Microsoft.UI.Text.FontWeights.Medium;
            originalScroll.MaxHeight = translationScroll.MaxHeight = 140;
            Body.Padding = new Thickness(13, 14, 14, 12); Body.MinHeight = ExpandedHeight;
            stage.MinHeight = 0; columns.VerticalAlignment = VerticalAlignment.Top;
        }
        original.TextWrapping = translation.TextWrapping = TextWrapping.Wrap;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(expand, isCompact ? "展开字幕历史" : "收起字幕历史");
        ToolTipService.SetToolTip(expand, isCompact ? "展开字幕历史" : "收起字幕历史");
        ((FontIcon)expand.Content).Glyph = isCompact ? "" : "";
        foreach (var (name, label) in new[] { ("source", original), ("translation", translation) })
        {
            var lines = Ordered().Where(x => x.Stream == name).Select(x => CaptionText.Format(x.Text, x.IsFailed));
            // Compact rolls recent segments into one running line (each segment is only ~2s of speech,
            // so showing the last one alone left a single word); expanded keeps them as paragraphs.
            label.Text = compact.IsChecked == true ? Running(lines.TakeLast(8)) : string.Join("\n\n", lines);
        }
        if (isCompact && both)
        {
            // A stream with nothing yet takes no line, so the strip stays centred on what is shown.
            var showSource = original.Text.Length > 0 || translation.Text.Length == 0;
            var showTranslation = translation.Text.Length > 0;
            originalPane.Visibility = showSource ? Visibility.Visible : Visibility.Collapsed;
            translationPane.Visibility = showTranslation ? Visibility.Visible : Visibility.Collapsed;
            originalScroll.MaxHeight = translationScroll.MaxHeight = showSource && showTranslation ? 15 : 31;
        }
        if (follow.IsChecked == true)
        {
            if (!followAfterLayout)
            {
                followAfterLayout = true;
                columns.LayoutUpdated += FollowAfterLayout;
            }
            QueueFollowLatest();
        }
    }
    private static string Running(IEnumerable<string> parts)
    {
        var text = new System.Text.StringBuilder();
        foreach (var part in parts.Select(x => x.Trim()).Where(x => x.Length > 0))
        {
            // Latin words need a space between segments; CJK text runs on directly.
            if (text.Length > 0 && text[^1] < 0x2E80 && part[0] < 0x2E80) text.Append(' ');
            text.Append(part);
        }
        return text.ToString();
    }
    private void FollowAfterLayout(object? sender, object args)
    {
        columns.LayoutUpdated -= FollowAfterLayout;
        followAfterLayout = false;
        QueueFollowLatest();
    }
    private void QueueFollowLatest() => DispatcherQueue.TryEnqueue(() =>
    {
        // Recheck after the layout that changes wrapping and scroll extent.
        // Turning follow off must also cancel either deferred callback.
        if (closed || follow.IsChecked != true) return;
        originalScroll.ChangeView(null, originalScroll.ScrollableHeight, null, true);
        translationScroll.ChangeView(null, translationScroll.ScrollableHeight, null, true);
    });
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)] private struct CursorPoint { public int X, Y; }
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern bool GetCursorPos(out CursorPoint point);
}
