using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Data;
using System.Globalization;
using Recappi.Core;

namespace Recappi.Desktop;

public partial class TranscriptPanel : UserControl
{
    private IReadOnlyList<CloudTranscriptSegment> all = [];
    private bool updating;
    private CloudTranscriptSegment[] timeline = [];
    private SpeakerProfileStore? speakerStore;
    private string? partition;
    private string? recordingId;
    private CloudTranscript? source;
    public static readonly DependencyProperty ActiveSegmentProperty = DependencyProperty.Register(nameof(ActiveSegment), typeof(CloudTranscriptSegment), typeof(TranscriptPanel));
    public CloudTranscriptSegment? ActiveSegment { get => (CloudTranscriptSegment?)GetValue(ActiveSegmentProperty); private set => SetValue(ActiveSegmentProperty, value); }
    public string Text { get; private set; } = "";
    public event Action<long>? SeekRequested;
    public TranscriptPanel() { InitializeComponent(); Clear(); }
    public void Clear() { speakerStore = null; partition = recordingId = null; ShowTranscript(new CloudTranscript("", "", "")); }
    public void SetSpeakerContext(SpeakerProfileStore store, string accountPartition, string id) { speakerStore = store; partition = accountPartition; recordingId = id; }
    public void ShowTranscript(CloudTranscript transcript)
    {
        updating = true;
        source = transcript;
        Text = transcript.Text;
        all = transcript.Segments.Count > 0 ? transcript.Segments : Text.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries).Select(line => new CloudTranscriptSegment(line, null, null, null)).ToArray();
        string? profileError = null;
        if (speakerStore is not null && partition is not null && recordingId is not null)
        {
            try
            {
                var profiles = speakerStore.Load(partition, recordingId);
                all = all.Select(segment => segment.Speaker is { } raw && profiles.TryGetValue(raw, out var profile) ? segment with { Profile = profile } : segment).ToArray();
            }
            catch (Exception) { profileError = "本地说话人信息读取失败，暂时显示原始标签。"; }
        }
        timeline = all.Where(x => x.StartMs is not null).OrderBy(x => x.StartMs).ToArray();
        ActiveSegment = null;
        Speakers.ItemsSource = new[] { new SpeakerChoice(null, "全部说话人") }.Concat(all.DistinctBy(x => x.Speaker).Select(x => new SpeakerChoice(x.Speaker ?? "未标注说话人", x.Profile is { } profile ? profile.Emoji + " " + profile.Name : x.Speaker ?? "未标注说话人"))).ToArray();
        Speakers.SelectedIndex = 0; Query.Clear(); updating = false; Filter();
        if (profileError is not null) Status.Text = profileError;
    }
    public void SaveSpeaker(string rawName, SpeakerProfile profile)
    {
        if (speakerStore is null || partition is null || recordingId is null || source is null || !all.Any(x => x.Speaker == rawName)) throw new ArgumentException("请先选择有说话人标签的片段。");
        speakerStore.Save(partition, recordingId, rawName, profile);
        var selected = Segments.SelectedItem as CloudTranscriptSegment;
        ShowTranscript(source);
        if (selected is not null) Locate(selected.Text, selected.StartMs);
    }
    private void EditSpeaker(object sender, RoutedEventArgs e)
    {
        var selected = Segments.SelectedItem as CloudTranscriptSegment;
        var raw = selected?.Speaker ?? (Speakers.SelectedIndex > 0 ? Speakers.SelectedValue as string : null);
        if (raw is null || !all.Any(x => x.Speaker == raw)) { Status.Text = "先选择一位说话人或带标签的片段。"; return; }
        var profile = all.First(x => x.Speaker == raw).Profile ?? new SpeakerProfile(raw, "🎤", null);
        var expectedPartition = partition; var expectedRecording = recordingId;
        new SpeakerEditor(profile, updated =>
        {
            if (expectedPartition != partition || expectedRecording != recordingId) throw new ArgumentException("录音或账号已切换，请关闭后重新编辑。");
            SaveSpeaker(raw, updated);
        }) { Owner = Window.GetWindow(this) }.ShowDialog();
    }
    public bool Locate(string? snippet, long? startMs)
    {
        var found = all.FirstOrDefault(x => !string.IsNullOrWhiteSpace(snippet) && x.Text.Contains(snippet, StringComparison.Ordinal))
            ?? (startMs is { } ms ? all.LastOrDefault(x => x.StartMs <= ms && (x.EndMs is null || x.EndMs > ms)) : null);
        if (found is null) return false;
        updating = true; Speakers.SelectedIndex = 0; Query.Clear(); updating = false; Filter();
        Segments.SelectedItem = found; Segments.ScrollIntoView(found); return true;
    }
    public void UpdatePlayback(double? seconds)
    {
        if (seconds is null || !double.IsFinite(seconds.Value) || seconds < 0) { ActiveSegment = null; return; }
        var milliseconds = seconds.Value * 1000;
        var low = 0; var high = timeline.Length;
        while (low < high)
        {
            var middle = low + (high - low) / 2;
            if (timeline[middle].StartMs <= milliseconds) low = middle + 1; else high = middle;
        }
        var candidate = low > 0 ? timeline[low - 1] : null;
        ActiveSegment = candidate is not null && (candidate.EndMs is null || milliseconds < candidate.EndMs) ? candidate : null;
    }
    private void Filter()
    {
        if (updating || Segments is null) return;
        var query = Query.Text.Trim();
        var speaker = Speakers.SelectedIndex <= 0 ? null : Speakers.SelectedValue as string;
        var visible = all.Where(x => (speaker is null || (x.Speaker ?? "未标注说话人") == speaker) && (query.Length == 0 || x.Text.Contains(query, StringComparison.OrdinalIgnoreCase))).ToArray();
        Segments.ItemsSource = visible;
        Status.Text = all.Count == 0 ? "暂无逐字稿。" : visible.Length == 0 ? "没有匹配的片段。" : $"{visible.Length} 个片段 · 双击或按 Enter 跳转音频";
    }
    private void FilterChanged(object sender, SelectionChangedEventArgs e) => Filter();
    private void QueryChanged(object sender, TextChangedEventArgs e) => Filter();
    private void ActivateSegment(object sender, MouseButtonEventArgs e) => SeekSelected();
    private void SegmentKey(object sender, KeyEventArgs e) { if (e.Key == Key.Enter) { SeekSelected(); e.Handled = true; } }
    private void SeekSelected() { if (Segments.SelectedItem is CloudTranscriptSegment { StartMs: { } ms }) SeekRequested?.Invoke(ms); }
    private void CopyAll(object sender, RoutedEventArgs e)
        => Copy(Text);
    private void CopySelected(object sender, RoutedEventArgs e)
        => Copy((Segments.SelectedItem as CloudTranscriptSegment)?.Text ?? "");
    private void Copy(string text)
    {
        try { if (text.Length > 0) Clipboard.SetText(text); }
        catch (System.Runtime.InteropServices.COMException) { Status.Text = "剪贴板暂不可用，请重试。"; }
    }
}

public sealed record SpeakerChoice(string? Raw, string Display);

public sealed class ActiveSegmentConverter : IMultiValueConverter
{
    public object Convert(object[] values, Type targetType, object parameter, CultureInfo culture) => values.Length == 2 && values[0] is CloudTranscriptSegment && ReferenceEquals(values[0], values[1]) ? "active" : "inactive";
    public object[] ConvertBack(object value, Type[] targetTypes, object parameter, CultureInfo culture) => throw new NotSupportedException();
}
