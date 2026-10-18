using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Recappi.Core;

namespace Recappi.WinUI;

internal sealed class CaptionWindow : DesktopWindow
{
    private readonly Dictionary<(string Id, string Stream), CaptionDelta> segments = [];
    private readonly TextBlock status = Ui.Text("开始录音后显示字幕。");
    private readonly TextBlock archiveError = Ui.Text("");
    private readonly TextBlock original = Ui.Text("", 20);
    private readonly TextBlock translation = Ui.Text("", 20);
    private readonly CheckBox showOriginal = new() { Content = "原文", IsChecked = true };
    private readonly CheckBox showTranslation = new() { Content = "翻译", IsChecked = true };
    private readonly CheckBox compact = new() { Content = "紧凑模式", IsChecked = true };
    private readonly CheckBox follow = new() { Content = "跟随最新", IsChecked = true };
    private readonly ScrollViewer originalScroll;
    private readonly ScrollViewer translationScroll;
    private readonly Grid columns = new() { ColumnSpacing = 12, RowSpacing = 6 };
    private readonly Button expand;
    private bool hasTranslation;
    private bool followAfterLayout;
    private bool closed;
    public CaptionWindow(Func<Task> retry) : base("Recappi Mini · 实时字幕", 540, 140)
    {
        Body.Padding = new Thickness(6, 8, 12, 14); Body.Spacing = 8; CompactChrome("移动字幕面板", 600, "RecappiSurfaceLiveCaption");
        Error.Style = RecappiTheme.Style("RecappiError"); Error.FontSize = 11.5;
        status.Style = RecappiTheme.Style("RecappiLabelSecondary"); status.IsTextSelectionEnabled = false;
        original.Style = RecappiTheme.Style("RecappiBody"); translation.Style = RecappiTheme.Style("RecappiBodySecondary");
        archiveError.Style = RecappiTheme.Style("RecappiError");
        expand = Ui.IconButton("展开字幕历史", "\uE740", () => { compact.IsChecked = compact.IsChecked != true; return Task.CompletedTask; }, this);
        var option = Ui.IconButton("字幕选项", "\uE713", () => Task.CompletedTask, this);
        var settings = new StackPanel { Spacing = 8 }; foreach (var control in new UIElement[] { showOriginal, showTranslation, follow, Ui.Button("重新连接", retry, this) }) settings.Children.Add(control);
        option.Flyout = new Flyout { Content = settings, ShouldConstrainToRootBounds = false };
        var toolbar = new Grid { ColumnSpacing = 8 };
        toolbar.ColumnDefinitions.Add(new ColumnDefinition());
        toolbar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var live = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7, VerticalAlignment = VerticalAlignment.Center };
        live.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 6, Height = 6, Style = RecappiTheme.Style("RecappiDotAccent"), VerticalAlignment = VerticalAlignment.Center });
        live.Children.Add(status);
        toolbar.Children.Add(live);
        var actions = Ui.Row(expand, option, Ui.IconButton("隐藏字幕", "\uE921", () => { Hide(); return Task.CompletedTask; }, this));
        foreach (var button in actions.Children.OfType<Button>()) { button.Width = button.Height = 28; ((FontIcon)button.Content).FontSize = 12; }
        Grid.SetColumn(actions, 1); toolbar.Children.Add(actions);
        Body.Children.Add(toolbar);
        archiveError.Visibility = Visibility.Collapsed; Body.Children.Add(archiveError);
        originalScroll = new ScrollViewer { Content = original, MaxHeight = 280 };
        translationScroll = new ScrollViewer { Content = translation, MaxHeight = 280 };
        columns.ColumnDefinitions.Add(new ColumnDefinition()); columns.ColumnDefinitions.Add(new ColumnDefinition());
        columns.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); columns.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetColumn(translationScroll, 1);
        columns.Children.Add(originalScroll); columns.Children.Add(translationScroll); Body.Children.Add(columns);
        Closed += (_, _) => { closed = true; columns.LayoutUpdated -= FollowAfterLayout; };
        foreach (var control in new[] { showOriginal, showTranslation, compact, follow })
        { control.Checked += (_, _) => Render(); control.Unchecked += (_, _) => Render(); }
        Render();
    }
    public void Reset(bool translate) { segments.Clear(); hasTranslation = translate; SetArchiveError(""); status.Text = "正在连接…"; Render(); }
    public void SetStatus(string value) => status.Text = value;
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
        showTranslation.Visibility = hasTranslation ? Visibility.Visible : Visibility.Collapsed;
        var sourceVisible = showOriginal.IsChecked == true;
        var translationVisible = hasTranslation && showTranslation.IsChecked == true;
        if (!sourceVisible && !translationVisible) { showOriginal.IsChecked = true; sourceVisible = true; }
        originalScroll.Visibility = sourceVisible ? Visibility.Visible : Visibility.Collapsed;
        translationScroll.Visibility = translationVisible ? Visibility.Visible : Visibility.Collapsed;
        var isCompact = compact.IsChecked == true;
        Grid.SetColumn(translationScroll, isCompact ? 0 : 1); Grid.SetRow(translationScroll, isCompact ? 1 : 0);
        columns.ColumnDefinitions[0].Width = isCompact || sourceVisible ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
        columns.ColumnDefinitions[1].Width = !isCompact && translationVisible ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
        original.FontSize = 17; translation.FontSize = 15; original.TextWrapping = translation.TextWrapping = TextWrapping.Wrap; original.VerticalAlignment = translation.VerticalAlignment = VerticalAlignment.Top;
        original.FontWeight = translation.FontWeight = Microsoft.UI.Text.FontWeights.Normal;
        original.LineHeight = 26; translation.LineHeight = 23;
        originalScroll.MaxHeight = translationScroll.MaxHeight = isCompact ? 120 : 350;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(expand, isCompact ? "展开字幕历史" : "收起字幕历史");
        ToolTipService.SetToolTip(expand, isCompact ? "展开字幕历史" : "收起字幕历史");
        foreach (var (name, label) in new[] { ("source", original), ("translation", translation) })
        {
            var lines = Ordered().Where(x => x.Stream == name).Select(x => CaptionText.Format(x.Text, x.IsFailed));
            label.Text = string.Join("\n\n", compact.IsChecked == true ? lines.TakeLast(1) : lines);
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
}
