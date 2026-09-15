using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
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
    private bool dirty;
    private string? archiveError;
    private readonly Func<Task<bool>>? retryCaptions;
    public CaptionWindow(Func<Task<bool>>? retryCaptions = null)
    {
        this.retryCaptions = retryCaptions;
        DesktopTheme.EnsureResources();
        InitializeComponent();
        refresh = new DispatcherTimer(TimeSpan.FromMilliseconds(100), DispatcherPriority.Background, (_, _) => Flush(), Dispatcher);
        IsVisibleChanged += (_, _) => { if (IsVisible) { refresh.Start(); Flush(); } else refresh.Stop(); };
        Closed += (_, _) => refresh.Stop();
    }
    public void Reset()
    {
        lock (sync) { pending.Clear(); state = new("connecting"); archiveError = null; dirty = true; }
        segments.Clear(); Transcript.Clear(); Flush();
    }
    public void Update(CaptionDelta value)
    {
        lock (sync)
        {
            pending[value.SegmentId + ":" + value.Stream] = value;
            while (pending.Count > 256) pending.Remove(pending.Keys.First());
            dirty = true;
        }
    }
    public void UpdateStatus(CaptionStatus value) { lock (sync) { state = value; dirty = true; } }
    public void UpdateArchiveError(string? value) { lock (sync) { archiveError = value; dirty = true; } }
    private void Flush()
    {
        lock (sync)
        {
            if (!dirty) return;
            foreach (var pair in pending) segments[pair.Key] = pair.Value;
            pending.Clear(); while (segments.Count > 200) segments.Remove(segments.Keys.First());
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
        if (Transcript is null || SourceVisible is null || TranslationVisible is null || Compact is null) return;
        var visible = segments.Values.Where(x => x.Stream == "source" ? SourceVisible.IsChecked == true : TranslationVisible.IsChecked == true).ToList();
        if (Compact.IsChecked == true)
            visible = visible.GroupBy(x => x.Stream).SelectMany(group => group.Where(x => x.IsFinal).TakeLast(1).Concat(group.Where(x => !x.IsFinal).TakeLast(1))).ToList();
        Transcript.Text = string.Join("\n\n", visible.Select(x => (x.Stream == "translation" ? "译文 · " : "") + x.Text)); Transcript.ScrollToEnd();
    }
    private void OptionsChanged(object sender, RoutedEventArgs e)
    {
        if (Compact is not null) Height = Compact.IsChecked == true ? 240 : 420;
        Render();
    }
    private async void RetryCaptions(object sender, RoutedEventArgs e)
    {
        lock (sync)
        {
            if (state.State != "failed") return;
            state = new("reconnecting"); dirty = true;
        }
        Flush();
        try
        {
            if (retryCaptions is null || !await retryCaptions()) UpdateStatus(new("failed", "当前无法重连，请确认仍在录音且原账号已连接。"));
        }
        catch (Exception) { UpdateStatus(new("failed", "字幕重连未完成，请重试。本机录音继续。")); }
        Flush();
    }
}
