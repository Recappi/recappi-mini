using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;
using Recappi.Core;

namespace Recappi.Desktop;

public partial class LocalLibraryView : System.Windows.Controls.UserControl, IDisposable
{
    private readonly LocalRecordingStore store;
    private readonly MediaPlayer player = new();
    private readonly DispatcherTimer playbackTimer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private bool playing;
    private LocalRecording? selected;
    private readonly AccountSession? accountSession;
    private readonly CloudProcessing? processing;
    private readonly Action? showAccount;
    private readonly Func<Task>? waitForCaptions;
    private CancellationTokenSource? importCancellation;
    private bool closed;
    public event Action? EntriesChanged;
    public event Action<LocalRecording?>? EntrySelected;
    public System.Collections.Generic.IReadOnlyList<LocalRecording> Entries => Recordings.Items.Cast<LocalRecording>().ToArray();
    public LocalLibraryView(LocalRecordingStore store, AccountSession? accountSession = null, CloudProcessing? processing = null, Action? showAccount = null, Func<Task>? waitForCaptions = null)
    {
        InitializeComponent(); this.store = store; this.accountSession = accountSession; this.processing = processing; this.showAccount = showAccount; this.waitForCaptions = waitForCaptions;
        if (processing is not null) processing.Changed += ProcessingChanged;
        if (accountSession is not null) accountSession.Changed += AccountChanged;
        player.MediaOpened += (_, _) => { Position.Maximum = player.NaturalDuration.HasTimeSpan ? player.NaturalDuration.TimeSpan.TotalSeconds : 1; Position.IsEnabled = true; };
        player.MediaEnded += (_, _) => { playing = false; playbackTimer.Stop(); PlayButton.Content = "播放"; player.Position = TimeSpan.Zero; Position.Value = 0; PlaybackTime.Text = "00:00"; };
        player.MediaFailed += (_, e) => { Status.Text = "播放失败：" + e.ErrorException.Message; playing = false; playbackTimer.Stop(); PlayButton.Content = "播放"; };
        playbackTimer.Tick += (_, _) => { if (!Position.IsMouseCaptureWithin) Position.Value = player.Position.TotalSeconds; PlaybackTime.Text = player.Position.ToString(@"mm\:ss"); };
    }
    public void Dispose()
    {
        if (closed) return;
        closed = true; importCancellation?.Cancel(); playbackTimer.Stop(); player.Close();
        if (processing is not null) processing.Changed -= ProcessingChanged;
        if (accountSession is not null) accountSession.Changed -= AccountChanged;
    }
    public void UseExternalList()
    {
        LibraryGrid.Children[0].Visibility = Visibility.Collapsed;
        LibraryGrid.ColumnDefinitions[0].Width = new GridLength(0);
        LibraryGrid.ColumnDefinitions[1].Width = new GridLength(0);
        LibraryGrid.Margin = new Thickness(0);
        ImportButton.Visibility = Visibility.Collapsed;
    }
    public void SelectEntry(string? id) => Recordings.SelectedItem = Recordings.Items.Cast<LocalRecording>().FirstOrDefault(x => x.Id == id);
    public void RefreshRecordings(string? selectedRecordingId = null)
    {
        try
        {
            var id = selectedRecordingId ?? selected?.Id;
            var entries = store.List();
            Recordings.ItemsSource = entries;
            EntriesChanged?.Invoke();
            if (id is not null) Recordings.SelectedItem = entries.FirstOrDefault(x => x.Id == id);
            if (entries.Count == 0) Status.Text = "还没有本地录音。从录音面板开始录制。";
        }
        catch (Exception error) { Status.Text = error.Message; }
    }
    private void RefreshClick(object sender, RoutedEventArgs e) => RefreshRecordings();
    private void CancelImport(object sender, RoutedEventArgs e) => importCancellation?.Cancel();
    private async void ImportAudio(object sender, RoutedEventArgs e) => await PickImportFileAsync();
    public async Task PickImportFileAsync()
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Title = "导入音频", Filter = "音频文件|*.wav;*.mp3;*.m4a;*.aac;*.wma;*.flac;*.ogg;*.opus;*.webm|所有文件|*.*", CheckFileExists = true };
        if (dialog.ShowDialog(Window.GetWindow(this)) == true) await ImportFileAsync(dialog.FileName);
    }
    public async Task ImportFileAsync(string path)
    {
        if (importCancellation is not null || closed) return;
        using var cancellation = new CancellationTokenSource();
        importCancellation = cancellation;
        ImportButton.IsEnabled = false; CancelImportButton.Visibility = Visibility.Visible;
        ImportStatus.Text = "正在导入音频…";
        try
        {
            var entry = await new AudioImport(store).ImportAsync(path, progress: new Progress<double>(value =>
            { if (!closed && importCancellation == cancellation) ImportStatus.Text = $"正在导入 {value:P0}"; }), cancellation: cancellation.Token);
            if (closed) return;
            RefreshRecordings();
            Recordings.SelectedItem = Recordings.Items.Cast<LocalRecording>().FirstOrDefault(x => x.Id == entry.Id);
            ImportStatus.Text = "已导入本地副本，可播放或上传转写。";
        }
        catch (OperationCanceledException) { if (!closed) ImportStatus.Text = "已取消导入。"; }
        catch (Exception) { if (!closed) ImportStatus.Text = "导入失败。请检查文件是否有效及 Windows 是否支持此音频格式，然后重试。"; }
        finally
        {
            importCancellation = null;
            if (!closed) { ImportButton.IsEnabled = true; CancelImportButton.Visibility = Visibility.Collapsed; }
        }
    }
    private void SelectRecording(object sender, SelectionChangedEventArgs e)
    {
        selected = Recordings.SelectedItem as LocalRecording;
        AudioCard.Visibility = ProcessingActions.Visibility = selected is null ? Visibility.Collapsed : Visibility.Visible;
        EntrySelected?.Invoke(selected);
        player.Close(); playing = false; playbackTimer.Stop(); PlayButton.Content = "播放"; Position.Value = 0; Position.IsEnabled = false;
        PlaybackTime.Text = selected is null ? "" : "00:00";
        if (selected is null)
        {
            Heading.Text = "选择一条录音"; Metadata.Text = ""; Status.Text = "从左侧选择录音，或导入音频开始回顾。"; PlaybackTime.Text = "";
            PlayButton.IsEnabled = false; FolderButton.IsEnabled = false; UploadButton.IsEnabled = false; ExportCaptionsButton.IsEnabled = false; return;
        }
        Heading.Text = selected.Title;
        Metadata.Text = selected.StartedAt.ToString("yyyy-MM-dd HH:mm") + " · " + TimeSpan.FromMilliseconds(selected.DurationMs).ToString(@"hh\:mm\:ss");
        var active = selected.State is RecordingState.Starting or RecordingState.Recording or RecordingState.Stopping;
        Status.Text = selected.Error ?? (active ? "录音会话未完成。" : "已保存在本机");
        PlayButton.IsEnabled = !active && File.Exists(selected.AudioPath);
        FolderButton.IsEnabled = true;
        UploadButton.IsEnabled = selected.State == RecordingState.Done && processing is not null;
        ExportCaptionsButton.IsEnabled = !active && File.Exists(store.CaptionPath(selected));
        RefreshCloudStatus();
        if (PlayButton.IsEnabled) player.Open(new Uri(selected.AudioPath));
    }
    private void AccountChanged(AccountSnapshot _) => Dispatcher.BeginInvoke(RefreshCloudStatus);
    private void RefreshCloudStatus()
    {
        CloudStatus.Text = accountSession?.Snapshot.State == AccountState.SignedIn ? "可上传录音并转写。" : "登录后可将录音上传并转写。";
        if (accountSession?.Snapshot.Account is { } account && processing is not null)
        {
            var entry = processing.List(account.Partition).FirstOrDefault(x => x.LocalId == selected?.Id);
            if (entry is not null) RenderProcessing(entry);
        }
    }
    private void TogglePlayback(object sender, RoutedEventArgs e)
    {
        if (playing) { player.Pause(); playbackTimer.Stop(); } else { player.Play(); playbackTimer.Start(); }
        playing = !playing; PlayButton.Content = playing ? "暂停" : "播放";
    }
    private void OpenFolder(object sender, RoutedEventArgs e)
    {
        if (selected is null) return;
        try { Process.Start(new ProcessStartInfo(selected.Directory) { UseShellExecute = true }); }
        catch (Exception error) { Status.Text = error.Message; }
    }
    private void Seek(object sender, MouseButtonEventArgs e) => SeekToSelectedPosition();
    private void SeekKey(object sender, KeyEventArgs e) => SeekToSelectedPosition();
    private void SeekToSelectedPosition()
    {
        var position = TimeSpan.FromSeconds(Position.Value);
        player.Position = position;
        // Paused playback has no timer ticks to update the displayed position.
        PlaybackTime.Text = position.ToString(@"mm\:ss");
    }
    private void ProcessingChanged(ProcessingEntry entry) => Dispatcher.BeginInvoke(() =>
    {
        if (entry.LocalId == selected?.Id && entry.Partition == accountSession?.Snapshot.Account?.Partition) RenderProcessing(entry);
    });
    private void RenderProcessing(ProcessingEntry entry)
    {
        CloudStatus.Text = entry.Error ?? entry.Stage switch
        {
            ProcessingStage.Creating => "正在创建云端录音…", ProcessingStage.Uploading => $"正在上传 {entry.Progress:P0}",
            ProcessingStage.CompletingUpload => "正在完成上传…", ProcessingStage.SubmittingTranscription => "正在提交转写…",
            ProcessingStage.Queued => "转写已排队", ProcessingStage.Transcribing => $"正在转写 {entry.Progress:P0}",
            ProcessingStage.Completed => "云端处理完成", ProcessingStage.Synced => "已上传，尚未转写；可手动开始转写。", ProcessingStage.Paused => "已暂停，可继续处理", _ => "处理未完成，可重试"
        };
    }
    private async void Upload(object sender, RoutedEventArgs e)
    {
        var recording = selected;
        var account = accountSession?.Snapshot;
        if (account?.State != AccountState.SignedIn || account.Account is null) { showAccount?.Invoke(); return; }
        if (recording is null || processing is null) return;
        try { await processing.StartAsync(recording, account.Account, (recording.Processing ?? new ProcessingOptions()) with { Transcribe = true }); }
        catch (Exception error)
        {
            if (!closed && selected?.Id == recording.Id && accountSession?.Snapshot is { State: AccountState.SignedIn, Account: { } current } &&
                current.Partition == account.Account.Partition && current.Token == account.Account.Token)
                CloudStatus.Text = error is ProcessingJournalException ? error.Message : "处理无法继续；本地音频已保留。";
        }
    }
    private async void ExportCaptions(object sender, RoutedEventArgs e)
    {
        var recording = selected;
        if (recording is null) return;
        try
        {
            if (waitForCaptions is not null) await waitForCaptions();
            var dialog = new Microsoft.Win32.SaveFileDialog { Title = "导出实时字幕", FileName = "captions.txt", Filter = "文本文件 (*.txt)|*.txt|字幕归档 (*.jsonl)|*.jsonl", AddExtension = true };
            if (dialog.ShowDialog(Window.GetWindow(this)) != true) return;
            if (closed || selected?.Id != recording.Id) { Status.Text = "录音选择已变化，请重新导出。"; return; }
            CaptionExport.Save(store, recording, dialog.FileName, dialog.FilterIndex == 2);
            Status.Text = "实时字幕已导出。";
        }
        catch (InvalidOperationException error) { Status.Text = error.Message; }
        catch (Exception) { Status.Text = "字幕导出失败，请检查目标位置后重试。"; }
    }
}
