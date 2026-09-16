using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Recappi.Core;

namespace Recappi.Desktop;

public partial class CaptionWindow : Window
{
    private readonly Dictionary<string, CaptionDelta> segments = [];
    private readonly object sync = new();
    private readonly Dictionary<string, CaptionDelta> pending = [];
    private readonly DispatcherTimer refresh;
    private CaptionStatus state = new("stopped");
    private long statusVersion;
    private bool dirty;
    private string? archiveError;
    private readonly Func<Task<bool>>? retryCaptions;
    private bool compactMode;
    private double expandedHeight = 420;
    private bool translationAvailable = true;
    private readonly Dictionary<TextBox, bool> followTail = [];
    private readonly HashSet<TextBox> updatingText = [];
    public CaptionWindow(Func<Task<bool>>? retryCaptions = null)
    {
        this.retryCaptions = retryCaptions;
        DesktopTheme.EnsureResources();
        InitializeComponent();
        foreach (var text in new[] { SourceTranscript, TranslationTranscript })
            text.AddHandler(ScrollViewer.ScrollChangedEvent, new ScrollChangedEventHandler(CaptionScrolled));
        UpdatePresentation();
        refresh = new DispatcherTimer(TimeSpan.FromMilliseconds(100), DispatcherPriority.Background, (_, _) => Flush(), Dispatcher);
        IsVisibleChanged += (_, _) => { if (IsVisible) { refresh.Start(); Flush(); } else refresh.Stop(); };
        Closed += (_, _) => { lock (sync) statusVersion++; refresh.Stop(); };
    }
    public void Reset()
    {
        lock (sync) { pending.Clear(); state = new("connecting"); statusVersion++; archiveError = null; dirty = true; }
        segments.Clear(); followTail.Clear(); SourceTranscript.Clear(); TranslationTranscript.Clear(); Flush();
    }
    public void Update(CaptionDelta value)
    {
        lock (sync)
        {
            pending[value.SegmentId + ":" + value.Stream] = value;
            while (pending.Count > 256)
                pending.Remove(pending.OrderBy(x => x.Value.Position?.Sequence ?? 0).ThenBy(x => x.Value.Position?.ContentIndex ?? 0).First().Key);
            dirty = true;
        }
    }
    public void UpdateStatus(CaptionStatus value) { lock (sync) { state = value; statusVersion++; dirty = true; } }
    public void ConfigureTranslation(bool available)
    {
        if (translationAvailable == available) return;
        translationAvailable = available;
        TranslationVisible.IsEnabled = available;
        if (!available) SourceVisible.IsChecked = true;
        TranslationVisible.IsChecked = available;
        UpdatePresentation(); Render();
    }
    public void UpdateArchiveError(string? value) { lock (sync) { archiveError = value; dirty = true; } }
    private void Flush()
    {
        lock (sync)
        {
            if (!dirty) return;
            foreach (var pair in pending) segments[pair.Key] = pair.Value;
            pending.Clear();
            while (segments.Count > 200)
                segments.Remove(segments.OrderBy(x => x.Value.Position?.Sequence ?? 0).ThenBy(x => x.Value.Position?.ContentIndex ?? 0).First().Key);
            Status.Text = state.Message ?? state.State switch { "connecting" => "正在连接字幕…", "live" => "实时字幕已连接", "reconnecting" => "正在重连字幕…", "failed" => "字幕不可用，本地录音继续", _ => "字幕已停止" };
            RetryButton.Visibility = state.State == "failed" && retryCaptions is not null ? Visibility.Visible : Visibility.Collapsed;
            ArchiveStatus.Text = archiveError ?? "";
            ArchiveStatus.Visibility = archiveError is null ? Visibility.Collapsed : Visibility.Visible;
            dirty = false;
        }
        Render();
    }
    private void Render()
    {
        if (SourceTranscript is null || TranslationTranscript is null) return;
        UpdateText(SourceTranscript, "source");
        UpdateText(TranslationTranscript, "translation");
    }
    private void UpdateText(TextBox target, string stream)
    {
        var ordered = segments.Values.Where(x => x.Stream == stream).OrderBy(x => x.Position?.Sequence ?? 0).ThenBy(x => x.Position?.ContentIndex ?? 0);
        IEnumerable<CaptionDelta> visible = ordered;
        if (compactMode) visible = ordered.Where(x => x.IsFinal).TakeLast(1).Concat(ordered.Where(x => !x.IsFinal).TakeLast(1));
        var text = string.Join(compactMode ? " " : "\n\n", visible.Select(x => x.Text));
        if (target.Text == text) return;
        var offset = target.VerticalOffset;
        var follow = compactMode || followTail.GetValueOrDefault(target, true);
        updatingText.Add(target);
        target.Text = text;
        target.Dispatcher.BeginInvoke(() =>
        {
            if (target.Text != text) return;
            target.UpdateLayout();
            if (follow) target.ScrollToEnd(); else target.ScrollToVerticalOffset(offset);
            target.UpdateLayout();
            updatingText.Remove(target);
        }, DispatcherPriority.Loaded);
    }
    private void CaptionScrolled(object sender, ScrollChangedEventArgs e)
    {
        var text = (TextBox)sender;
        if (updatingText.Contains(text)) return;
        if (e.ExtentHeightChange != 0 || e.ViewportHeightChange != 0 || e.ViewportWidthChange != 0)
        {
            if (compactMode || followTail.GetValueOrDefault(text, true)) text.ScrollToEnd();
        }
        else if (e.VerticalChange != 0)
            followTail[text] = compactMode || text.VerticalOffset + text.ViewportHeight >= text.ExtentHeight - 8;
    }
    private void OptionsChanged(object sender, RoutedEventArgs e)
    {
        if (SourcePane is null || TranslationPane is null || Compact is null) return;
        if (SourceVisible.IsChecked != true && TranslationVisible.IsChecked != true)
        {
            ((CheckBox)sender).IsChecked = true;
            return;
        }
        var nextCompact = Compact.IsChecked == true;
        if (nextCompact != compactMode)
        {
            if (nextCompact) expandedHeight = Height;
            compactMode = nextCompact;
            Height = compactMode ? 240 : expandedHeight;
        }
        UpdatePresentation();
        Render();
    }
    private void UpdatePresentation()
    {
        var source = SourceVisible.IsChecked == true;
        var translation = TranslationVisible.IsChecked == true;
        var both = source && translation;
        SourcePane.Visibility = source ? Visibility.Visible : Visibility.Collapsed;
        TranslationPane.Visibility = translation ? Visibility.Visible : Visibility.Collapsed;
        SourceColumn.Width = new GridLength(compactMode || source ? (both && !compactMode ? 57 : 1) : 0, GridUnitType.Star);
        TranslationColumn.Width = new GridLength(!compactMode && translation ? (both ? 43 : 1) : 0, GridUnitType.Star);
        SourceRow.Height = new GridLength(!compactMode || source ? 1 : 0, GridUnitType.Star);
        TranslationRow.Height = new GridLength(compactMode && translation ? 1 : 0, GridUnitType.Star);
        Grid.SetRow(TranslationPane, compactMode ? 1 : 0);
        Grid.SetColumn(TranslationPane, compactMode ? 0 : 1);
        SourcePane.Margin = both ? (compactMode ? new Thickness(0, 0, 0, 3) : new Thickness(0, 0, 6, 0)) : new Thickness(0);
        TranslationPane.Margin = both ? (compactMode ? new Thickness(0, 3, 0, 0) : new Thickness(6, 0, 0, 0)) : new Thickness(0);
        foreach (var pane in new[] { SourcePane, TranslationPane }) pane.Padding = compactMode ? new Thickness(8, 2, 8, 2) : new Thickness(12);
        foreach (var heading in new[] { SourceHeading, TranslationHeading }) heading.Visibility = compactMode ? Visibility.Collapsed : Visibility.Visible;
        foreach (var text in new[] { SourceTranscript, TranslationTranscript })
        {
            text.VerticalAlignment = compactMode ? VerticalAlignment.Center : VerticalAlignment.Stretch;
            text.Height = compactMode ? (both ? 28 : 56) : double.NaN;
            text.VerticalScrollBarVisibility = compactMode ? ScrollBarVisibility.Hidden : ScrollBarVisibility.Auto;
            if (compactMode) text.ScrollToEnd();
        }
        UpdateMinimumHeight();
    }
    private void CaptionChromeChanged(object sender, SizeChangedEventArgs e) => UpdateMinimumHeight();
    private void UpdateMinimumHeight()
    {
        if (CaptionOptions is null || StatusPanel is null || CaptionLayout is null || CaptionLayout.ActualHeight <= 0) return;
        // Keep both caption rows readable when warnings and reconnect controls wrap.
        var chrome = Math.Max(0, ActualHeight - CaptionLayout.ActualHeight);
        var both = SourceVisible.IsChecked == true && TranslationVisible.IsChecked == true;
        var content = compactMode ? (both ? 74 : 62) : 110;
        MinHeight = Math.Max(240, chrome + CaptionOptions.DesiredSize.Height + StatusPanel.DesiredSize.Height + content);
    }
    private async void RetryCaptions(object sender, RoutedEventArgs e)
    {
        long attempt;
        lock (sync)
        {
            if (state.State != "failed") return;
            state = new("reconnecting"); dirty = true;
            attempt = ++statusVersion;
        }
        Flush();
        string? failure = null;
        try
        {
            if (retryCaptions is null || !await retryCaptions()) failure = "当前无法重连，请确认仍在录音且原账号已连接。";
        }
        catch (Exception) { failure = "字幕重连未完成，请重试。本机录音继续。"; }
        lock (sync)
        {
            // A new stream, external status or closed window supersedes this attempt.
            if (statusVersion != attempt) return;
            if (failure is not null) { state = new("failed", failure); statusVersion++; dirty = true; }
        }
        Flush();
    }
}
