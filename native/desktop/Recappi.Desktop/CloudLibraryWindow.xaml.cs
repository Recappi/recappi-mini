using System;
using System.Collections.ObjectModel;
using System.Linq;
using System.IO;
using System.Diagnostics;
using System.Text;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Recappi.Core;

namespace Recappi.Desktop;

public sealed record LibrarySearchEntry(string Title, string Source, string Snippet, string? LocalId, CloudSearchHit? Cloud, string? Partition)
{
    public override string ToString() => Title;
}

public partial class CloudLibraryWindow : Window
{
    private readonly AccountSession accounts;
    private readonly ObservableCollection<CloudRecordingItem> items = [];
    private CancellationTokenSource requests = new();
    private CancellationTokenSource? detailRequest;
    private CancellationTokenSource? transcriptRequest;
    private string? partition;
    private string? cursor;
    private int generation;
    private bool loading;
    private bool closed;
    private string? audioPath;
    private string? audioRecordingId;
    private CancellationTokenSource? audioRequest;
    private CloudTranscript? loadedTranscript;
    private readonly Func<CloudAccount, string, Task>? remoteDeleted;
    private bool deleting;
    public Func<string, bool>? ConfirmDelete { get; set; }
    public Func<Microsoft.Win32.SaveFileDialog, bool?>? ShowExportDialog { get; set; }
    private bool audioLoading;
    private double? citationSeek;
    private readonly SpeakerProfileStore speakers = new(SpeakerProfileStore.DefaultRoot);
    private readonly CloudContentCache contentCache;
    private CloudSearchHit? searchHit;
    private AccountState displayedAccountState;
    private readonly LocalLibraryView? localLibrary;
    private readonly Action? showAccount;
    private Action? showCurrentMeeting;
    private CancellationTokenSource? librarySearchRequest;
    private readonly Func<DateTime> localToday;
    private DateTime groupedDay;
    private readonly System.Windows.Threading.DispatcherTimer dateRefreshTimer;
    private readonly Func<string, System.Collections.Generic.IReadOnlyList<ProcessingEntry>> processingEntries;
    private bool rebuildingLibrary;
    private bool showingLocal;
    private LibraryRecording? SelectedRecording => Recordings.SelectedItem as LibraryRecording;
    private CloudRecordingItem? SelectedCloud => showingLocal ? null : SelectedRecording?.Cloud;
    public void RefreshDateGroups()
    {
        if (closed || localToday().Date == groupedDay) return;
        groupedDay = localToday().Date;
        (Recordings.ItemsSource as System.ComponentModel.ICollectionView)?.Refresh();
    }
    public void SetCurrentMeeting(RecordingSnapshot snapshot, Action showRecorder)
    {
        if (closed) return;
        var active = snapshot.State is RecordingState.Starting or RecordingState.Recording or RecordingState.Stopping;
        showCurrentMeeting = active ? showRecorder : null;
        CurrentMeeting.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
        CurrentMeetingLabel.Text = active ? "当前会议 · " + (snapshot.Recording?.Title ?? "正在启动") + " · " + TimeSpan.FromMilliseconds(snapshot.Recording?.DurationMs ?? 0).ToString(@"hh\:mm\:ss") : "";
    }
    private void OpenCurrentMeeting(object sender, RoutedEventArgs e) => showCurrentMeeting?.Invoke();

    public CloudLibraryWindow(AccountSession accounts, Func<ProcessingOptions>? processingOptions = null, Func<CloudAccount, string, Task>? remoteDeleted = null, CloudContentCache? contentCache = null, LocalLibraryView? localLibrary = null, Action? showAccount = null, Func<DateTime>? localToday = null, Func<string, System.Collections.Generic.IReadOnlyList<ProcessingEntry>>? processingEntries = null)
    {
        DesktopTheme.EnsureResources();
        InitializeComponent(); this.accounts = accounts; this.remoteDeleted = remoteDeleted;
        this.processingEntries = processingEntries ?? (_ => []);
        this.contentCache = contentCache ?? new(CloudContentCache.DefaultRoot);
        this.localToday = localToday ?? (() => DateTime.Today);
        groupedDay = this.localToday().Date;
        dateRefreshTimer = new() { Interval = TimeSpan.FromMinutes(1) };
        dateRefreshTimer.Tick += (_, _) => RefreshDateGroups();
        Loaded += (_, _) => { RefreshDateGroups(); dateRefreshTimer.Start(); };
        Activated += (_, _) => RefreshDateGroups();
        Closed += (_, _) => dateRefreshTimer.Stop();
        this.localLibrary = localLibrary; this.showAccount = showAccount;
        AccountButton.IsEnabled = showAccount is not null;
        RenderAccountHeader();
        if (localLibrary is not null)
        {
            Title = "Recappi Mini · 录音库";
            localLibrary.UseExternalList(); LocalDetail.Content = localLibrary;
            LocalDetail.Visibility = Visibility.Visible; CloudDetail.Visibility = Visibility.Collapsed; ImportLocalButton.Visibility = Visibility.Visible;
            localLibrary.EntriesChanged += RefreshLocalItems;
            localLibrary.EntrySelected += LocalEntrySelected;
            Closed += (_, _) => { localLibrary.EntriesChanged -= RefreshLocalItems; localLibrary.EntrySelected -= LocalEntrySelected; localLibrary.Dispose(); };
            RefreshLocalRecordings();
        }
        RebuildLibrary();
        Player.PlaybackPositionChanged += seconds => Transcript.UpdatePlayback(audioRecordingId is not null && audioRecordingId == SelectedCloud?.Id ? seconds : null);
        Transcript.SeekRequested += milliseconds =>
        {
            citationSeek = milliseconds / 1000d;
            if (audioRecordingId == SelectedCloud?.Id) Player.SeekTo(citationSeek.Value);
            else Status.Text = "加载所选录音音频后可跳转到片段时间。";
        };
        if (processingOptions is not null) Review.ProcessingOptions = processingOptions;
        Review.VersionSelected += async jobId => await LoadTranscriptAsync(jobId);
        Ask.CitationSelected += citation =>
        {
            if (citation.StartMs is >= 0)
            {
                citationSeek = citation.StartMs.Value / 1000d;
                if (audioRecordingId == SelectedCloud?.Id) Player.SeekTo(citationSeek.Value);
                else Status.Text = "加载所选录音音频后可跳转到引用时间。";
            }
            DetailTabs.SelectedIndex = 0;
            if (!Transcript.Locate(citation.Snippet, citation.StartMs)) Status.Text = "引用：" + citation.Display;
        };
        accounts.Changed += AccountChanged;
        Loaded += async (_, _) => await ResetAsync();
        Closed += (_, _) => { closed = true; librarySearchRequest?.Cancel(); librarySearchRequest?.Dispose(); LibrarySearchResults.ItemsSource = null; ClearAudio(); Ask.Clear(); Review.Clear(); accounts.Changed -= AccountChanged; requests.Cancel(); requests.Dispose(); detailRequest?.Cancel(); detailRequest?.Dispose(); transcriptRequest?.Cancel(); transcriptRequest?.Dispose(); };
    }
    private async void LibraryQueryChanged(object sender, TextChangedEventArgs e) { if (IsLoaded) await SearchLibraryAsync(); }
    public async Task SearchLibraryAsync()
    {
        librarySearchRequest?.Cancel(); librarySearchRequest?.Dispose(); librarySearchRequest = new();
        var cancellation = librarySearchRequest.Token;
        var query = LibraryQuery.Text.Trim(); var accountPartition = VisiblePartition;
        LibrarySearchResults.ItemsSource = null;
        LibraryLists.Visibility = query.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        LibrarySearchResults.Visibility = query.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        LibrarySearchStatus.Text = query.Length == 0 ? "" : "正在搜索…";
        if (query.Length == 0) return;
        try
        {
            await Task.Delay(250, cancellation);
            var localEntries = localLibrary?.Entries ?? [];
            var cached = accountPartition is null ? null : await contentCache.SearchAsync(accountPartition, query, cancellation: cancellation);
            if (closed || cancellation.IsCancellationRequested || accountPartition != VisiblePartition || LibraryQuery.Text.Trim() != query) return;
            var hits = (cached?.Hits ?? []).GroupBy(x => x.Recording.Id).ToDictionary(x => x.Key, x => x.First());
            var rows = LibraryRecording.Merge(localEntries, hits.Values.Select(x => x.Recording).ToArray(), ReadProcessingLinks(accountPartition), accountPartition);
            var results = rows.Where(x => x.Cloud is not null || x.Local!.Title.Contains(query, StringComparison.OrdinalIgnoreCase))
                .OrderByDescending(x => x.CreatedAt).Select(x => x.Cloud is { } remote
                    ? new LibrarySearchEntry(x.Title, (x.Local is null ? "云端缓存" : "本机与云端缓存") + " · " + hits[remote.Id].Source, hits[remote.Id].Snippet, null, hits[remote.Id], accountPartition)
                    : new LibrarySearchEntry(x.Title, "本机 · 标题", x.Local!.StartedAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm"), x.Local.Id, null, null)).ToArray();
            LibrarySearchResults.ItemsSource = results.Take(100).ToArray();
            LibrarySearchStatus.Text = $"找到 {Math.Min(results.Length, 100)} 个结果。搜索本机标题和当前账号已缓存内容。" + (results.Length >= 100 || cached?.Truncated == true ? "请缩小搜索范围以查看其他结果。" : "");
        }
        catch (OperationCanceledException) { }
        catch (Exception) { if (!closed && !cancellation.IsCancellationRequested) LibrarySearchStatus.Text = "搜索失败，请重试。"; }
    }
    private void SelectLibrarySearchResult(object sender, SelectionChangedEventArgs e)
    {
        if (LibrarySearchResults.SelectedItem is not LibrarySearchEntry hit) return;
        if (hit.LocalId is { } id) { SelectLocalId(id); return; }
        if (hit.Cloud is not { } cloud || hit.Partition != VisiblePartition) return;
        var item = items.FirstOrDefault(x => x.Id == cloud.Recording.Id);
        if (item is null) { item = cloud.Recording; items.Add(item); RebuildLibrary(); }
        searchHit = cloud;
        SelectCloudId(item.Id);
    }
    private void OpenAccount(object sender, RoutedEventArgs e) => showAccount?.Invoke();
    private async void ImportLocal(object sender, RoutedEventArgs e) { if (localLibrary is not null) await localLibrary.PickImportFileAsync(); }
    public void RefreshLocalRecordings(string? recordingId = null)
    {
        if (localLibrary is null) return;
        localLibrary.RefreshRecordings(recordingId);
        if (recordingId is not null) SelectLocalId(recordingId);
    }
    private void RefreshLocalItems()
    {
        if (localLibrary is null || closed) return;
        RebuildLibrary();
    }
    private void LocalEntrySelected(LocalRecording? recording)
    {
        if (!closed && !rebuildingLibrary && recording is not null && SelectedRecording?.Local?.Id != recording.Id) SelectLocalId(recording.Id);
    }
    public void RebuildLibrary()
    {
        if (closed) return;
        var previous = SelectedRecording;
        var currentPartition = VisiblePartition;
        var links = ReadProcessingLinks(currentPartition);
        var rows = LibraryRecording.Merge(localLibrary?.Entries ?? [], items, links, currentPartition);
        var selected = rows.FirstOrDefault(x => x.Key == previous?.Key) ?? rows.FirstOrDefault(x => x.Cloud?.Id is { } id && id == previous?.Cloud?.Id);
        rebuildingLibrary = true;
        try
        {
            Recordings.ItemsSource = RecordingDateGroups.Create(rows, nameof(LibraryRecording.CreatedAt), () => groupedDay);
            Recordings.SelectedItem = selected;
        }
        finally { rebuildingLibrary = false; }
        CopyActions.Visibility = selected is { Local: not null, Cloud: not null } ? Visibility.Visible : Visibility.Collapsed;
        if (previous?.Local?.Id != selected?.Local?.Id || previous?.Cloud?.Id != selected?.Cloud?.Id)
            _ = ShowSelectedAsync(showingLocal && selected?.Local is not null);
    }
    private System.Collections.Generic.IReadOnlyList<ProcessingEntry> ReadProcessingLinks(string? accountPartition)
    {
        try { return accountPartition is null ? [] : processingEntries(accountPartition); }
        catch (Exception) { Status.Text = "本机与云端关联暂不可读，录音分别显示。"; return []; }
    }
    private void SelectLocalId(string id)
    {
        var row = Recordings.Items.Cast<LibraryRecording>().FirstOrDefault(x => x.Local?.Id == id);
        if (row is null) return;
        rebuildingLibrary = true;
        try { Recordings.SelectedItem = row; } finally { rebuildingLibrary = false; }
        _ = ShowSelectedAsync(true);
    }
    private void SelectCloudId(string id)
    {
        var row = Recordings.Items.Cast<LibraryRecording>().FirstOrDefault(x => x.Cloud?.Id == id);
        if (row is null) return;
        if (SelectedCloud?.Id == id) { ApplySearchHit(); return; }
        rebuildingLibrary = true;
        try { Recordings.SelectedItem = row; } finally { rebuildingLibrary = false; }
        _ = ShowSelectedAsync(false);
    }
    private async void OpenLocalCopy(object sender, RoutedEventArgs e) { if (SelectedRecording?.Local is not null) await ShowSelectedAsync(true); }
    private async void OpenCloudCopy(object sender, RoutedEventArgs e) { if (SelectedRecording?.Cloud is not null) await ShowSelectedAsync(false); }
    private void AccountChanged(AccountSnapshot _) => Dispatcher.BeginInvoke(async () =>
    {
        if (!closed) RenderAccountHeader();
        if (!closed && (partition != VisiblePartition || displayedAccountState != accounts.Snapshot.State)) await ResetAsync();
    });
    private void RenderAccountHeader()
    {
        var text = AccountHeaderText.From(accounts.Snapshot);
        AccountIdentity.Text = text.Identity; AccountConnection.Text = text.Status;
        AccountButton.ToolTip = text.Identity + "\n" + text.Status;
        System.Windows.Automation.AutomationProperties.SetName(AccountButton, text.Identity + "，" + text.Status);
    }
    private async Task ResetAsync()
    {
        librarySearchRequest?.Cancel(); LibrarySearchResults.ItemsSource = null;
        requests.Cancel(); requests.Dispose(); requests = new();
        audioLoading = false;
        if (partition != VisiblePartition) ClearAudio();
        generation++; loading = false; cursor = null; RefreshButton.IsEnabled = true; MoreButton.IsEnabled = false;
        partition = VisiblePartition;
        displayedAccountState = accounts.Snapshot.State;
        items.Clear(); RebuildLibrary(); Heading.Text = "选择一条云端录音"; Transcript.Clear(); Summary.Clear();
        await LoadAsync();
        if (!closed && LibraryQuery.Text.Trim().Length > 0) await SearchLibraryAsync();
    }
    private async void RefreshClick(object sender, RoutedEventArgs e)
    {
        RefreshLocalRecordings();
        if (accounts.Snapshot.State == AccountState.Offline) await accounts.RefreshAsync(); else await ResetAsync();
    }
    private async void MoreClick(object sender, RoutedEventArgs e) => await LoadAsync();
    private void SearchCache(object sender, RoutedEventArgs e)
    {
        if (accounts.Snapshot is not { State: AccountState.SignedIn or AccountState.Offline, Account: { } account }) { Status.Text = "请先登录账号。"; return; }
        new CloudSearchWindow(contentCache, accounts, account.Partition, hit =>
        {
            if (VisiblePartition != account.Partition) return;
            var item = items.FirstOrDefault(x => x.Id == hit.Recording.Id);
            if (item is null) { item = hit.Recording; items.Add(item); RebuildLibrary(); }
            searchHit = hit;
            SelectCloudId(item.Id);
        }) { Owner = this }.Show();
    }
    private void ApplySearchHit()
    {
        if (searchHit is not { } hit || SelectedCloud?.Id != hit.Recording.Id) return;
        DetailTabs.SelectedIndex = hit.Source == "摘要" ? 1 : 0;
        if (hit.Source == "逐字稿") Transcript.Locate(hit.Snippet, hit.StartMs);
        if (hit.Source == "摘要")
        {
            var index = Summary.Text.IndexOf(hit.Snippet, StringComparison.Ordinal);
            if (index >= 0) { Summary.Select(index, hit.Snippet.Length); Summary.ScrollToLine(Summary.GetLineIndexFromCharacterIndex(index)); }
        }
    }
    private string? VisiblePartition => accounts.Snapshot.State is AccountState.SignedIn or AccountState.Offline ? accounts.Snapshot.Account?.Partition : null;
    private bool Current(int version, CloudAccount account) => !closed && generation == version && account.Partition == VisiblePartition;
    private async Task LoadAsync()
    {
        if (loading) return;
        if (accounts.Snapshot is not { State: AccountState.SignedIn or AccountState.Offline, Account: { } account }) { Status.Text = localLibrary is null ? "请先登录账号。" : "本机录音可直接使用；登录后可访问云端录音。"; MoreButton.IsEnabled = false; return; }
        var version = generation;
        loading = true; RefreshButton.IsEnabled = false; MoreButton.IsEnabled = false; Status.Text = "正在加载云端录音…";
        try
        {
            if (accounts.Snapshot.State == AccountState.Offline)
            {
                var cached = await contentCache.ListAsync(account.Partition, requests.Token);
                if (!Current(version, account)) return;
                var knownIds = items.Select(x => x.Id).ToHashSet(StringComparer.Ordinal);
                foreach (var item in cached) if (knownIds.Add(item.Id)) items.Add(item);
                RebuildLibrary();
                Status.Text = $"离线模式：显示 {items.Count} 条本机缓存录音。联网后点刷新重新连接。";
                return;
            }
            using var client = accounts.Client(account);
            var page = CloudRecordingPage.Parse(await client.ListAsync(cursor, requests.Token));
            if (!Current(version, account)) return;
            var loadedIds = items.Select(x => x.Id).ToHashSet(StringComparer.Ordinal);
            foreach (var item in page.Items) if (loadedIds.Add(item.Id)) items.Add(item);
            RebuildLibrary();
            cursor = page.NextCursor == cursor ? null : page.NextCursor;
            Status.Text = items.Count == 0 ? "还没有云端录音。" : $"已加载 {items.Count} 条录音";
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { if (Current(version, account)) Status.Text = error is CloudException ? error.Message : "云端录音加载失败，请重试。"; }
        finally { if (version == generation && !closed) { loading = false; RefreshButton.IsEnabled = true; MoreButton.IsEnabled = cursor is not null; } }
    }
    private async void SelectRecording(object sender, SelectionChangedEventArgs e)
    {
        if (!rebuildingLibrary) await ShowSelectedAsync(SelectedRecording?.Cloud is null);
    }
    private async Task ShowSelectedAsync(bool local)
    {
        showingLocal = local || SelectedRecording?.Cloud is null;
        CopyActions.Visibility = SelectedRecording is { Local: not null, Cloud: not null } ? Visibility.Visible : Visibility.Collapsed;
        LocalCopyButton.IsEnabled = !showingLocal; CloudCopyButton.IsEnabled = showingLocal;
        detailRequest?.Cancel(); detailRequest?.Dispose();
        detailRequest = null;
        Transcript.Clear(); Summary.Clear(); Ask.Clear(); Review.Clear(); citationSeek = null; loadedTranscript = null;
        if (searchHit?.Recording.Id != SelectedCloud?.Id) searchHit = null;
        ExportButton.IsEnabled = false; BrowserButton.IsEnabled = DeleteButton.IsEnabled = SelectedCloud is not null && !deleting;
        DeleteButton.IsEnabled &= accounts.Snapshot.State == AccountState.SignedIn;
        RenderAudioButton();
        transcriptRequest?.Cancel(); transcriptRequest?.Dispose(); transcriptRequest = null;
        if (showingLocal)
        {
            if (SelectedRecording?.Local is not null) ClearAudio();
            localLibrary?.SelectEntry(SelectedRecording?.Local?.Id);
            CloudDetail.Visibility = localLibrary is null ? Visibility.Visible : Visibility.Collapsed;
            LocalDetail.Visibility = localLibrary is null ? Visibility.Collapsed : Visibility.Visible;
            Heading.Text = "选择一条云端录音";
            return;
        }
        if (SelectedCloud is not { } item || accounts.Snapshot.Account is not { } account) { Heading.Text = "选择一条云端录音"; return; }
        localLibrary?.SelectEntry(null);
        LocalDetail.Visibility = Visibility.Collapsed; CloudDetail.Visibility = Visibility.Visible;
        Heading.Text = item.Title;
        detailRequest = CancellationTokenSource.CreateLinkedTokenSource(requests.Token);
        if (accounts.Snapshot.State == AccountState.SignedIn)
        {
            _ = Ask.SelectAsync(accounts, account, item.Id);
            _ = Review.SelectAsync(accounts, account, item);
        }
        await LoadTranscriptAsync(null);
    }
    private async Task LoadTranscriptAsync(string? jobId)
    {
        if (detailRequest is null || SelectedCloud is not { } item || accounts.Snapshot.Account is not { } account) return;
        transcriptRequest?.Cancel(); transcriptRequest?.Dispose();
        transcriptRequest = CancellationTokenSource.CreateLinkedTokenSource(detailRequest.Token);
        var cancellation = transcriptRequest.Token; var version = generation;
        Transcript.Clear(); Summary.Clear(); loadedTranscript = null; ExportButton.IsEnabled = false;
        Status.Text = "正在读取转写和摘要…";
        try
        {
            if (accounts.Snapshot.State == AccountState.Offline)
            {
                var cached = await Task.Run(() => contentCache.Load(account.Partition, item.Id), cancellation);
                if (cancellation.IsCancellationRequested || !Current(version, account)) return;
                if (cached is null) { Status.Text = "这条录音尚未缓存在本机。"; return; }
                loadedTranscript = cached.Transcript; ExportButton.IsEnabled = true;
                Transcript.SetSpeakerContext(speakers, account.Partition, item.Id); Transcript.ShowTranscript(cached.Transcript);
                Summary.Text = cached.Transcript.Summary; ApplySearchHit();
                Status.Text = "离线内容 · 缓存于 " + cached.SavedAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm");
                return;
            }
            using var client = accounts.Client(account);
            var transcript = CloudTranscript.Parse(await client.TranscriptAsync(item.Id, jobId, cancellation));
            if (cancellation.IsCancellationRequested || !Current(version, account)) return;
            if (jobId is null)
            {
                try { await Task.Run(() => contentCache.Save(account.Partition, item, transcript), cancellation); }
                catch (Exception) when (!cancellation.IsCancellationRequested) { /* Reading the remote result remains usable when disk caching fails. */ }
                if (cancellation.IsCancellationRequested || !Current(version, account)) return;
            }
            loadedTranscript = transcript; ExportButton.IsEnabled = true;
            Transcript.SetSpeakerContext(speakers, account.Partition, item.Id);
            Transcript.ShowTranscript(transcript);
            Transcript.UpdatePlayback(audioRecordingId == item.Id ? Player.PlaybackSeconds : null);
            Summary.Text = transcript.Summary.Length == 0 ? "暂无摘要。" : transcript.Summary;
            ApplySearchHit();
            if (jobId is null) Review.UpdateSummaryStatus(transcript.SummaryStatus);
            Status.Text = transcript.SummaryStatus is "pending" or "queued" or "running" ? "摘要正在生成，可稍后刷新。" : "已加载";
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested) { }
        catch (Exception error)
        {
            if (cancellation.IsCancellationRequested || !Current(version, account)) return;
            if (jobId is null && (error is System.Net.Http.HttpRequestException or OperationCanceledException || error is CloudException cloud && (int)cloud.Status >= 500))
            {
                try
                {
                    var cached = await Task.Run(() => contentCache.Load(account.Partition, item.Id), cancellation);
                    if (cancellation.IsCancellationRequested || !Current(version, account)) return;
                    if (cached is not null)
                    {
                        loadedTranscript = cached.Transcript; ExportButton.IsEnabled = true;
                        Transcript.SetSpeakerContext(speakers, account.Partition, item.Id); Transcript.ShowTranscript(cached.Transcript);
                        Summary.Text = cached.Transcript.Summary; ApplySearchHit();
                        Status.Text = "网络不可用，显示本机缓存（" + cached.SavedAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm") + "）。";
                        return;
                    }
                }
                catch (Exception) { }
            }
            if (cancellation.IsCancellationRequested || !Current(version, account)) return;
            Status.Text = error is CloudException { Status: HttpStatusCode.NotFound } ? "这条录音还没有转写结果。" : "转写加载失败，请重新选择录音重试。";
        }
    }
    private void ClearAudio()
    {
        audioRequest?.Cancel(); audioRequest?.Dispose(); audioRequest = null;
        ReleaseAudio(); citationSeek = null; audioLoading = false; LoadAudioButton.IsEnabled = false;
    }
    private void ReleaseAudio()
    {
        Player.Clear(); audioRecordingId = null; PlaybackLabel.Text = ""; SaveAudioButton.IsEnabled = false;
        if (audioPath is not null) { try { File.Delete(audioPath); } catch (IOException) { } audioPath = null; }
    }
    private void RenderAudioButton() => LoadAudioButton.IsEnabled = accounts.Snapshot.State == AccountState.SignedIn && !audioLoading && SelectedCloud is { } selected && selected.Id != audioRecordingId;
    private async void LoadAudio(object sender, RoutedEventArgs e)
    {
        if (audioLoading || detailRequest is null || SelectedCloud is not { } item || accounts.Snapshot.Account is not { } account) return;
        audioLoading = true; LoadAudioButton.IsEnabled = false; Status.Text = "正在下载音频…";
        audioRequest?.Cancel(); audioRequest?.Dispose(); audioRequest = CancellationTokenSource.CreateLinkedTokenSource(requests.Token);
        var cancellation = audioRequest.Token; var version = generation; var seek = citationSeek;
        var target = Path.Combine(Path.GetTempPath(), "RecappiMini", account.Partition, Guid.NewGuid().ToString("N") + ".audio");
        try
        {
            using var client = accounts.Client(account); target = await client.DownloadAudioAsync(item.Id, target, cancellation);
            if (cancellation.IsCancellationRequested || !Current(version, account)) { File.Delete(target); return; }
            ReleaseAudio(); audioPath = target; audioRecordingId = item.Id; PlaybackLabel.Text = "播放音频：" + item.Title;
            Player.Open(target, SelectedCloud?.Id == item.Id ? citationSeek : seek); SaveAudioButton.IsEnabled = true; Status.Text = "音频已加载";
        }
        catch (OperationCanceledException) { }
        catch (Exception) { if (!cancellation.IsCancellationRequested && Current(version, account)) Status.Text = "音频加载失败，请重试。"; }
        finally { if (!cancellation.IsCancellationRequested && Current(version, account)) { audioLoading = false; RenderAudioButton(); } }
    }
    private void OpenBrowser(object sender, RoutedEventArgs e)
    {
        if (SelectedCloud is not { } item || accounts.Snapshot.Account is not { } account) return;
        try { var url = new Uri(CloudClient.ValidateOrigin(account.Origin), "/recordings/" + Uri.EscapeDataString(item.Id)); Process.Start(new ProcessStartInfo(url.AbsoluteUri) { UseShellExecute = true }); }
        catch (Exception) { Status.Text = "无法打开浏览器。"; }
    }
    private void ExportText(object sender, RoutedEventArgs e)
    {
        if (loadedTranscript is not { } transcript || SelectedCloud is not { } recording || VisiblePartition is not { } exportPartition) return;
        var version = generation;
        var title = Heading.Text;
        var dialog = new Microsoft.Win32.SaveFileDialog { FileName = "recording.txt", Filter = "文本 (*.txt)|*.txt|Markdown (*.md)|*.md", AddExtension = true };
        if ((ShowExportDialog is { } show ? show(dialog) : dialog.ShowDialog(this)) != true) return;
        // Native modal dialogs run a nested dispatcher loop: account/detail state can change.
        if (closed || generation != version || exportPartition != VisiblePartition || SelectedCloud?.Id != recording.Id || !ReferenceEquals(loadedTranscript, transcript))
        { if (!closed) Status.Text = "录音或账号已变化，请重新选择要导出的内容。"; return; }
        try { File.WriteAllText(dialog.FileName, title + "\n\n摘要\n" + transcript.Summary + "\n\n逐字稿\n" + transcript.Text, new UTF8Encoding(false)); Status.Text = "文字已导出。"; }
        catch (Exception) { Status.Text = "导出失败，请检查目标位置。"; }
    }
    private void SaveAudio(object sender, RoutedEventArgs e)
    {
        if (audioPath is not { } source || VisiblePartition is not { } exportPartition) return;
        var version = generation;
        var recordingId = audioRecordingId;
        var dialog = new Microsoft.Win32.SaveFileDialog { FileName = "recording" + Path.GetExtension(source), Filter = "音频文件|*.*" };
        if ((ShowExportDialog is { } show ? show(dialog) : dialog.ShowDialog(this)) != true) return;
        if (closed || generation != version || exportPartition != VisiblePartition || audioPath != source || audioRecordingId != recordingId)
        { if (!closed) Status.Text = "音频或账号已变化，请重新选择要保存的副本。"; return; }
        try { File.Copy(source, dialog.FileName, true); Status.Text = "音频副本已保存。"; }
        catch (Exception) { Status.Text = "保存失败，请检查目标位置。"; }
    }
    private async void DeleteRecording(object sender, RoutedEventArgs e)
    {
        if (deleting || SelectedCloud is not { } item || accounts.Snapshot.Account is not { } account) return;
        var approved = ConfirmDelete?.Invoke(item.Title) ?? MessageBox.Show(this, $"删除云端录音“{item.Title}”？此操作无法撤销，本机录音文件仍会保留。", "删除云端录音", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) == MessageBoxResult.Yes;
        if (!approved) return;
        deleting = true; DeleteButton.IsEnabled = false; var cancellation = requests.Token;
        try
        {
            using var client = accounts.Client(account); await client.DeleteAsync(item.Id, cancellation);
            try { speakers.Delete(account.Partition, item.Id); } catch (Exception) { /* Remote deletion is already committed; do not report it as failed. */ }
            try { contentCache.Delete(account.Partition, item.Id); } catch (Exception) { /* A cache cleanup failure must not undo remote success. */ }
            if (!closed && account.Partition == VisiblePartition)
            {
                var removed = items.FirstOrDefault(x => x.Id == item.Id); if (removed is not null) items.Remove(removed);
                RebuildLibrary();
                if (audioRecordingId == item.Id) ClearAudio();
                Status.Text = "云端录音已删除。";
            }
            if (remoteDeleted is not null)
            {
                try { await remoteDeleted(account, item.Id); }
                catch (Exception) { if (!closed && account.Partition == VisiblePartition) Status.Text = "云端录音已删除，本地处理关联清理失败。"; }
            }
        }
        catch (Exception) { if (!closed && account.Partition == VisiblePartition) Status.Text = "删除结果未确认，请刷新列表核对。"; }
        finally { deleting = false; if (!closed) DeleteButton.IsEnabled = SelectedCloud is not null && accounts.Snapshot.State == AccountState.SignedIn; }
    }
}
