using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Recappi.Core;
using Windows.Media.Core;
using Windows.Media.Playback;
using Windows.Storage.Pickers;

namespace Recappi.WinUI;

internal sealed class LibraryWindow : DesktopWindow
{
    private readonly IDesktopHost app;
    private readonly Func<Task<string?>> pickImportFile;
    private readonly Func<string, IProgress<double>, CancellationToken, Task<LocalRecording>> importAudio;
    private readonly CloudContentCache cache;
    private readonly List<CloudRecordingItem> remote = [];
    private readonly ListView list = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly TextBox search = new() { PlaceholderText = "搜索录音" };
    private readonly TextBlock heading = Ui.Text("选择录音", 24);
    private readonly TextBlock location = Ui.Text("");
    private readonly TextBlock importStatus = Ui.Text("");
    private readonly SummaryDocument summary = new();
    private readonly ListView transcript = new() { SelectionMode = ListViewSelectionMode.Single };
    private readonly TextBox filter = new() { PlaceholderText = "过滤逐字稿", MinWidth = 160 };
    private readonly ComboBox speaker = new() { PlaceholderText = "说话人", MinWidth = 120 };
    private readonly StackPanel details = new() { Spacing = 12 };
    private MediaPlayer player = new() { AutoPlay = false };
    private MediaSource? playbackSource;
    private Stream? playbackFile;
    private Windows.Storage.Streams.IRandomAccessStream? playbackStream;
    private bool mediaOpened;
    private TimeSpan? pendingSeek;
    private readonly MediaPlayerElement media;
    private readonly DispatcherTimer playbackTimer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private readonly Slider seek = new() { Minimum = 0, Maximum = 1, IsEnabled = false, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock playbackTime = Ui.Text("00:00 / 00:00", 12);
    private readonly Button play;
    private bool updatingSeek;
    private readonly CancellationTokenSource lifetime = new();
    private CancellationTokenSource detailRequest = new();
    private CancellationTokenSource? import;
    private IReadOnlyList<LocalRecording> local = [];
    private CloudTranscript? content;
    private string? nextCursor;
    private string? partition;
    private string? audioPath;
    private Task? audioLoading;
    private long selectedDurationMs;
    private int generation;
    private int refreshGeneration;
    private bool closed;
    private bool refreshing;
    private bool rebuild;
    private bool localView;
    private ReviewPanel? review;
    private AskPanel? ask;
    private readonly SelectorBar tabs = new();
    private readonly ContentControl askTab = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly ContentControl reviewTab = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
    private readonly TextBlock accountLabel = Ui.Text("");
    private readonly TextBlock accountInitial = new() { FontSize = 13 };
    private readonly TextBlock meetingLabel = Ui.Text("");
    private readonly Grid detailLayout = new() { RowSpacing = 12, Visibility = Visibility.Collapsed };
    private readonly StackPanel emptyDetail = new() { Spacing = 12, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock emptyList = Ui.Text("还没有录音\n开始录音，或导入已有音频。", 13);
    private readonly Button cancelImport;
    private readonly Button loadMore;
    private readonly Button localCopy;
    private readonly Button cloudCopy;
    private readonly SpeakerProfileStore profiles;
    private IReadOnlyList<LibraryRecording> displayed = [];
    private LibraryRecording? Selected => list.SelectedItem as LibraryRecording;
    public LibraryWindow(IDesktopHost app, Func<Task<string?>>? pickImportFile = null,
        Func<string, IProgress<double>, CancellationToken, Task<LocalRecording>>? importAudio = null) : base("Recappi Mini · 录音库", 1120, 760)
    {
        this.app = app; cache = new CloudContentCache(Path.Combine(app.ApplicationRoot, "CloudContent"));
        this.pickImportFile = pickImportFile ?? PickImportFile;
        this.importAudio = importAudio ?? ((path, progress, cancellation) => new AudioImport(app.Store).ImportAsync(path, app.Preferences.Processing, progress, cancellation));
        profiles = new SpeakerProfileStore(Path.Combine(app.ApplicationRoot, "Speakers"));
        ToolTipService.SetToolTip(search, "搜索本机标题与当前账号已缓存的内容");
        partition = app.Account.Snapshot.Account?.Partition;
        list.HorizontalContentAlignment = HorizontalAlignment.Stretch;
        list.ItemContainerStyle = (Style)Microsoft.UI.Xaml.Markup.XamlReader.Load("<Style xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='ListViewItem'><Setter Property='HorizontalContentAlignment' Value='Stretch'/><Setter Property='HorizontalAlignment' Value='Stretch'/><Setter Property='Padding' Value='10,0'/><Setter Property='Margin' Value='0,1'/><Setter Property='CornerRadius' Value='8'/></Style>");
        ((ScrollViewer)Content).Content = null;
        var layout = new Grid();
        layout.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(264) }); layout.ColumnDefinitions.Add(new ColumnDefinition());
        // Sidebar: status · search and import · recordings · account.
        Body.Padding = new Thickness(0); Body.Spacing = 8;
        Error.Style = RecappiTheme.Style("RecappiError"); Error.FontSize = 12;
        meetingLabel.Style = RecappiTheme.Style("RecappiStatusAccent"); meetingLabel.Visibility = Visibility.Collapsed; Body.Children.Add(meetingLabel);
        var sidebar = new Grid { RowSpacing = 12, Padding = new Thickness(12, 4, 10, 12) };
        foreach (var height in new[] { GridLength.Auto, GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto }) sidebar.RowDefinitions.Add(new RowDefinition { Height = height });
        sidebar.Children.Add(Body);
        var controls = new StackPanel { Spacing = 8 }; controls.Children.Add(search);
        var importButton = Ui.Button("导入音频", Import, this); importButton.HorizontalAlignment = HorizontalAlignment.Stretch;
        var returnToRecorder = Ui.IconButton("录音控制", "", () => { app.ShowRecorder(); return Task.CompletedTask; }, this);
        ToolTipService.SetToolTip(returnToRecorder, "打开录音条");
        var actions = new Grid { ColumnSpacing = 4 };
        actions.ColumnDefinitions.Add(new ColumnDefinition()); actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var refreshButton = Ui.IconButton("刷新", "", Refresh, this);
        Grid.SetColumn(refreshButton, 1); Grid.SetColumn(returnToRecorder, 2);
        actions.Children.Add(importButton); actions.Children.Add(refreshButton); actions.Children.Add(returnToRecorder);
        controls.Children.Add(actions);
        importStatus.Style = RecappiTheme.Style("RecappiCaption"); importStatus.Visibility = Visibility.Collapsed;
        cancelImport = Ui.Button("取消导入", () => { import?.Cancel(); return Task.CompletedTask; }, this); cancelImport.Visibility = Visibility.Collapsed;
        controls.Children.Add(importStatus); controls.Children.Add(cancelImport);
        Grid.SetRow(controls, 1); sidebar.Children.Add(controls);
        Grid.SetRow(list, 2); sidebar.Children.Add(list);
        emptyList.Style = RecappiTheme.Style("RecappiBodySecondary"); emptyList.Margin = new Thickness(8, 18, 8, 0); Grid.SetRow(emptyList, 2); sidebar.Children.Add(emptyList);
        loadMore = Ui.Button("加载更多", LoadMore, this); loadMore.Visibility = Visibility.Collapsed; loadMore.HorizontalAlignment = HorizontalAlignment.Stretch;
        accountLabel.Style = RecappiTheme.Style("RecappiCaption"); accountLabel.TextWrapping = TextWrapping.NoWrap; accountLabel.IsTextSelectionEnabled = false; accountLabel.FontSize = 12; accountLabel.LineHeight = 17;
        var footer = new StackPanel { Spacing = 8 }; footer.Children.Add(loadMore);
        var accountContent = new Grid { ColumnSpacing = 10 };
        accountContent.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); accountContent.ColumnDefinitions.Add(new ColumnDefinition());
        var avatar = new Border { Width = 30, Height = 30, CornerRadius = new CornerRadius(15), Child = accountInitial };
        RecappiTheme.Bind(avatar, "RecappiAccentChipFill", brush => avatar.Background = brush);
        accountInitial.Style = RecappiTheme.Style("RecappiStatusAccent"); accountInitial.HorizontalAlignment = HorizontalAlignment.Center;
        accountContent.Children.Add(avatar); Grid.SetColumn(accountLabel, 1); accountContent.Children.Add(accountLabel);
        var accountButton = Ui.Button("账号", () => { app.ShowAccount(); return Task.CompletedTask; }, this);
        accountButton.Style = RecappiTheme.Style("RecappiSubtleButton"); accountButton.Content = accountContent;
        accountButton.HorizontalAlignment = HorizontalAlignment.Stretch; accountButton.HorizontalContentAlignment = HorizontalAlignment.Stretch; accountButton.Padding = new Thickness(6);
        footer.Children.Add(accountButton); Grid.SetRow(footer, 3); sidebar.Children.Add(footer);
        layout.Children.Add(sidebar);
        list.ItemTemplate = (DataTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load("<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'><StackPanel Padding='2,10' Spacing='4'><TextBlock Text='{Binding Title}' FontWeight='SemiBold' FontSize='13.5' TextTrimming='CharacterEllipsis'/><TextBlock x:Name='Metadata' Text='{Binding Location}' FontSize='11.5' Opacity='0.6' TextTrimming='CharacterEllipsis'/></StackPanel></DataTemplate>");
        list.ContainerContentChanging += (_, e) =>
        {
            if (e.Item is LibraryRecording item && e.ItemContainer.ContentTemplateRoot is FrameworkElement root && root.FindName("Metadata") is TextBlock metadata)
            {
                var duration = item.Local?.DurationMs ?? item.Cloud?.DurationMs ?? 0;
                var date = item.CreatedAt?.ToLocalTime().ToString("M月d日") ?? "";
                metadata.Text = string.Join(" · ", new[] { date, duration > 0 ? $"{Math.Ceiling(duration / 60000d):0} 分钟" : "", item.Location }.Where(x => x.Length > 0));
            }
        };
        transcript.ItemTemplate = (DataTemplate)Microsoft.UI.Xaml.Markup.XamlReader.Load("<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' xmlns:x='http://schemas.microsoft.com/winfx/2006/xaml'><StackPanel Padding='6,12' Spacing='8'><Button x:Name='Timestamp' Content='{Binding Label}' HorizontalAlignment='Left' ToolTipService.ToolTip='定位到这段录音'/><TextBlock Text='{Binding Text}' FontSize='14' LineHeight='24' TextWrapping='Wrap' IsTextSelectionEnabled='True'/></StackPanel></DataTemplate>");
        transcript.ContainerContentChanging += (_, e) =>
        {
            if (e.ItemContainer.ContentTemplateRoot is FrameworkElement root && root.FindName("Timestamp") is Button button)
            {
                button.Style ??= RecappiTheme.Style("RecappiTimestampButton");
                button.Click -= TranscriptTimestampClick;
                button.Tag = e.InRecycleQueue ? null : e.Item;
                button.IsEnabled = button.Tag is CloudTranscriptSegment { StartMs: not null };
                button.Click += TranscriptTimestampClick;
            }
        };
        // Detail card: title and copies · sections · playback bar.
        heading.Style = RecappiTheme.Style("RecappiPageTitle"); heading.MaxLines = 2; heading.TextTrimming = TextTrimming.CharacterEllipsis;
        location.Style = RecappiTheme.Style("RecappiCaption"); location.IsTextSelectionEnabled = false;
        details.Spacing = 8; details.Children.Add(heading);
        localCopy = Ui.Button("本机副本", () => Select(true), this); cloudCopy = Ui.Button("云端副本", () => Select(false), this);
        foreach (var copy in new[] { localCopy, cloudCopy }) { copy.MinHeight = 26; copy.FontSize = 12; copy.Padding = new Thickness(10, 0, 10, 0); }
        var meta = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        meta.Children.Add(location); meta.Children.Add(localCopy); meta.Children.Add(cloudCopy);
        details.Children.Add(meta);
        media = new MediaPlayerElement { AreTransportControlsEnabled = false, Visibility = Visibility.Collapsed };
        media.SetMediaPlayer(player);
        var audioControls = new Grid { ColumnSpacing = 14, Padding = new Thickness(0, 14, 0, 0) };
        foreach (var width in new[] { GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto, GridLength.Auto }) audioControls.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        play = Ui.IconButton("播放 / 暂停", "", TogglePlayback, this);
        play.Style = RecappiTheme.Style("RecappiPlayButton"); play.ClearValue(FrameworkElement.WidthProperty); play.ClearValue(FrameworkElement.HeightProperty);
        audioControls.Children.Add(play); audioControls.Children.Add(media);
        Grid.SetColumn(seek, 1); audioControls.Children.Add(seek);
        playbackTime.Style = RecappiTheme.Style("RecappiDuration"); playbackTime.IsTextSelectionEnabled = false;
        Grid.SetColumn(playbackTime, 2); audioControls.Children.Add(playbackTime);
        var rates = new double[] { 0.5, 0.75, 1, 1.25, 1.5, 2 }.Select(x => new ComboBoxItem { Content = x + "×", Tag = x }).ToArray();
        var speed = new ComboBox { ItemsSource = rates, SelectedItem = rates[2], MinWidth = 84, VerticalAlignment = VerticalAlignment.Center };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(speed, "播放速度");
        ToolTipService.SetToolTip(speed, "播放速度");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(seek, "播放位置");
        speed.SelectionChanged += (_, _) => { if (speed.SelectedItem is ComboBoxItem { Tag: double value }) player.PlaybackSession.PlaybackRate = value; };
        Grid.SetColumn(speed, 3); audioControls.Children.Add(speed);
        var audioBar = new Border { Child = audioControls, BorderThickness = new Thickness(0, 1, 0, 0) };
        RecappiTheme.Bind(audioBar, "RecappiBorderHairline", brush => audioBar.BorderBrush = brush);
        seek.ValueChanged += (_, e) => { if (!updatingSeek && audioPath is not null) SeekAudio(TimeSpan.FromSeconds(e.NewValue)); };
        playbackTimer.Tick += (_, _) => RenderPlayback();
        var moreActions = new StackPanel { Spacing = 2, MinWidth = 200 };
        var more = Ui.IconButton("更多操作", "", () => Task.CompletedTask, this);
        more.Flyout = new Flyout { Content = moreActions };
        moreActions.Children.Add(Ui.Button("完整标题", async () =>
        {
            var title = Selected?.Title;
            if (title is null) return;
            more.Flyout.Hide();
            var dialog = new ContentDialog
            {
                Title = "完整标题", XamlRoot = Content.XamlRoot, RequestedTheme = ((FrameworkElement)Content).ActualTheme,
                Content = new ScrollViewer { Content = Ui.Text(title), MaxHeight = 300 },
                CloseButtonText = "关闭", DefaultButton = ContentDialogButton.Close
            };
            await dialog.ShowAsync();
        }, this));
        foreach (var control in new[] { Ui.Button("上传 / 继续处理", Upload, this), Ui.Button("从本机库移除", RemoveLocal, this), Ui.Button("删除云端录音", DeleteCloud, this),
            Ui.Button("导出文字", ExportText, this), Ui.Button("音频副本", ExportAudio, this), Ui.Button("导出字幕 JSONL", () => ExportCaptions(true), this), Ui.Button("打开目录", OpenFolder, this), Ui.Button("打开网页", OpenBrowser, this) }) moreActions.Children.Add(control);
        foreach (var action in moreActions.Children.OfType<Button>()) action.Style = RecappiTheme.Style("RecappiMenuButton");
        var detailHeader = new Grid { ColumnSpacing = 16 };
        detailHeader.ColumnDefinitions.Add(new ColumnDefinition()); detailHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        detailHeader.Children.Add(details); Grid.SetColumn(more, 1); more.VerticalAlignment = VerticalAlignment.Top; detailHeader.Children.Add(more);
        var transcriptLayout = new Grid { RowSpacing = 8 };
        transcriptLayout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); transcriptLayout.RowDefinitions.Add(new RowDefinition());
        var transcriptTools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 12, 0, 0) };
        transcriptTools.Children.Add(filter); transcriptTools.Children.Add(speaker); transcriptTools.Children.Add(Ui.Button("编辑说话人", EditSpeaker, this));
        transcriptLayout.Children.Add(transcriptTools);
        Grid.SetRow(transcript, 1); transcriptLayout.Children.Add(transcript);
        var sectionHost = new ContentControl { HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
        var sectionViews = new UIElement[] { new ScrollViewer { Content = summary }, transcriptLayout, askTab, reviewTab };
        foreach (var name in new[] { "摘要", "逐字稿", "问答", "处理历史" }) tabs.Items.Add(new SelectorBarItem { Text = name });
        tabs.SelectionChanged += (_, _) => { var index = tabs.Items.IndexOf(tabs.SelectedItem); if (index >= 0) sectionHost.Content = sectionViews[index]; };
        tabs.SelectedItem = tabs.Items[0];
        tabs.Margin = new Thickness(-12, 0, 0, 0);
        var sectionLayout = new Grid { RowSpacing = 4 };
        sectionLayout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); sectionLayout.RowDefinitions.Add(new RowDefinition());
        sectionLayout.Children.Add(tabs); Grid.SetRow(sectionHost, 1); sectionLayout.Children.Add(sectionHost);
        detailLayout.RowSpacing = 14;
        detailLayout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); detailLayout.RowDefinitions.Add(new RowDefinition());
        detailLayout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        detailLayout.Children.Add(detailHeader); Grid.SetRow(sectionLayout, 1); detailLayout.Children.Add(sectionLayout);
        Grid.SetRow(audioBar, 2); detailLayout.Children.Add(audioBar);
        emptyDetail.Spacing = 10;
        var emptyTile = RecappiTheme.LogoTile(52); emptyTile.HorizontalAlignment = HorizontalAlignment.Center; emptyTile.Margin = new Thickness(0, 0, 0, 6); emptyDetail.Children.Add(emptyTile);
        var emptyTitle = new TextBlock { Text = "从一段录音开始", Style = RecappiTheme.Style("RecappiSectionTitle"), FontSize = 18, HorizontalAlignment = HorizontalAlignment.Center }; emptyDetail.Children.Add(emptyTitle);
        var emptyHint = new TextBlock { Text = "选择左侧录音，查看摘要、逐字稿与问答。", Style = RecappiTheme.Style("RecappiBodySecondary"), HorizontalAlignment = HorizontalAlignment.Center }; emptyDetail.Children.Add(emptyHint);
        var emptyImport = Ui.Button("导入音频", Import, this); emptyImport.HorizontalAlignment = HorizontalAlignment.Center; emptyImport.Margin = new Thickness(0, 8, 0, 0); emptyDetail.Children.Add(emptyImport);
        var detailContainer = new Grid(); detailContainer.Children.Add(detailLayout); detailContainer.Children.Add(emptyDetail);
        var detailSurface = Ui.Surface(detailContainer, new Thickness(28, 22, 28, 16));
        detailSurface.BorderThickness = new Thickness(1, 1, 0, 0); detailSurface.CornerRadius = new CornerRadius(12, 0, 0, 0);
        Grid.SetColumn(detailSurface, 1); layout.Children.Add(detailSurface); Content = PageFrame(layout, "录音库");
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter) { presenter.PreferredMinimumWidth = (int)(820 * Scale); presenter.PreferredMinimumHeight = (int)(560 * Scale); }
        search.TextChanged += async (_, _) => await Run(Search);
        filter.TextChanged += (_, _) => RenderTranscript(); speaker.SelectionChanged += (_, _) => RenderTranscript();
        transcript.SelectionChanged += async (_, _) =>
        {
            if (transcript.SelectedItem is CloudTranscriptSegment segment) await SeekTranscript(segment);
        };
        list.SelectionChanged += async (_, _) => { if (!rebuild) await Run(() => Select(Selected?.Cloud is null)); };
        list.KeyDown += (_, e) =>
        {
            if (e.Key != Windows.System.VirtualKey.Enter) return;
            var focused = Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(list.XamlRoot) as DependencyObject;
            while (focused is not null && focused != list)
            {
                if (focused is ListViewItem item && item.Content is LibraryRecording recording && list.Items.Contains(recording))
                {
                    list.SelectedItem = recording;
                    e.Handled = true;
                    return;
                }
                focused = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(focused);
            }
        };
        app.Account.Changed += AccountChanged;
        app.Engine.Changed += RecordingChanged; RenderAccount();
        Closed += (_, _) =>
        {
            closed = true; playbackTimer.Stop(); lifetime.Cancel(); detailRequest.Cancel(); import?.Cancel(); ask?.Dispose(); review?.Dispose();
            app.Account.Changed -= AccountChanged; app.Engine.Changed -= RecordingChanged; DisposePlayback();
        };
    }
    private void AccountChanged(AccountSnapshot snapshot) => UiDispatcher.TryEnqueue(() =>
    {
        if (closed) return;
        RenderAccount();
        // Invalidate even same-account token refreshes; pending operations carry the old credential.
        generation++; refreshGeneration++; detailRequest.Cancel(); ask?.Dispose(); review?.Dispose();
        content = null; summary.Text = ""; transcript.ItemsSource = null; ResetPlayback(); selectedDurationMs = 0; RenderPlayback(); heading.Text = "选择录音"; location.Text = ""; askTab.Content = null; reviewTab.Content = null;
        detailLayout.Visibility = Visibility.Collapsed; emptyDetail.Visibility = Visibility.Visible;
        if (snapshot.Account?.Partition != partition || snapshot.State is AccountState.SignedOut or AccountState.Expired)
        { remote.Clear(); nextCursor = null; partition = snapshot.State is AccountState.SignedOut or AccountState.Expired ? null : snapshot.Account?.Partition; }
        _ = Run(Refresh);
    });
    public void ProcessingChanged()
    {
        if (!closed && !refreshing) _ = Run(Refresh);
    }
    public async Task SelectRecording(string id) { await Refresh(); list.SelectedItem = displayed.FirstOrDefault(x => x.Local?.Id == id); }
    private void RecordingChanged(RecordingSnapshot snapshot) => UiDispatcher.TryEnqueue(() =>
    {
        if (closed) return;
        meetingLabel.Text = snapshot.State is RecordingState.Starting or RecordingState.Recording or RecordingState.Stopping
            ? "● 正在录音 · " + TimeSpan.FromMilliseconds(snapshot.Recording?.DurationMs ?? 0).ToString(@"hh\:mm\:ss") : "";
        meetingLabel.Visibility = meetingLabel.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
    });
    private void RenderAccount()
    {
        var email = app.Account.Snapshot.Account?.Email;
        accountLabel.Text = (email ?? "尚未登录") + "\n" +
            (app.Account.Snapshot.State == AccountState.SignedIn ? "已连接云端" : app.Account.Snapshot.State == AccountState.Offline ? "离线 · 可查看已缓存内容" : "本机录音可用");
        accountInitial.Text = string.IsNullOrEmpty(email) ? "?" : email[..1].ToUpperInvariant();
    }
    private bool IsCurrent(int version, CloudAccount? account = null) => !closed && version == generation &&
        (account is null || app.Account.Snapshot.Account is { } current && current.Partition == account.Partition && current.Token == account.Token && app.Account.Snapshot.State == AccountState.SignedIn);
    private CloudAccount RequireAccount() => app.Account.Snapshot is { State: AccountState.SignedIn, Account: { } account } ? account : throw new InvalidOperationException("请先连接账号。");
    public async Task Refresh()
    {
        var version = ++refreshGeneration; refreshing = true;
        try
        {
            var items = await Task.Run(app.Store.List);
            if (closed || version != refreshGeneration) return;
            local = items;
            if (app.Account.Snapshot is { State: AccountState.SignedIn, Account: { } account })
            {
                using var client = app.Account.Client(account);
                try
                {
                    var page = CloudRecordingPage.Parse(await client.ListAsync(cancellation: lifetime.Token));
                    if (closed || version != refreshGeneration || app.Account.Snapshot.Account?.Token != account.Token) return;
                    partition = account.Partition; remote.Clear(); remote.AddRange(page.Items); nextCursor = page.NextCursor;
                }
                catch (Exception error) when (error is not OperationCanceledException) { if (version == refreshGeneration) SetError("云端刷新失败：" + error.Message); }
            }
            else if (app.Account.Snapshot is { State: AccountState.Offline, Account: { } offline })
            {
                var cached = await cache.ListAsync(offline.Partition, lifetime.Token);
                if (closed || version != refreshGeneration) return;
                partition = offline.Partition; remote.Clear(); remote.AddRange(cached); nextCursor = null;
            }
            await Search();
        }
        finally { if (version == refreshGeneration) refreshing = false; }
    }
    private async Task LoadMore()
    {
        if (nextCursor is null) return;
        var account = RequireAccount(); var cursor = nextCursor; var version = refreshGeneration;
        using var client = app.Account.Client(account);
        var page = CloudRecordingPage.Parse(await client.ListAsync(cursor, lifetime.Token));
        if (closed || version != refreshGeneration || app.Account.Snapshot.Account?.Token != account.Token || nextCursor != cursor) return;
        remote.AddRange(page.Items.Where(x => remote.All(y => y.Id != x.Id))); nextCursor = page.NextCursor; await Search();
    }
    private int searchGeneration;
    private async Task Search()
    {
        var version = ++searchGeneration; var query = search.Text.Trim(); var scope = partition;
        var cloud = remote.ToList(); var matches = new HashSet<string>();
        if (query.Length > 0 && scope is not null)
        {
            var result = await cache.SearchAsync(scope, query, cancellation: lifetime.Token);
            if (closed || version != searchGeneration || scope != partition) return;
            foreach (var hit in result.Hits) { matches.Add(hit.Recording.Id); if (cloud.All(x => x.Id != hit.Recording.Id)) cloud.Add(hit.Recording); }
        }
        var links = scope is null ? [] : app.Processing.List(scope);
        var rows = LibraryRecording.Merge(local, cloud, links, scope).Where(x => query.Length == 0 || x.Title.Contains(query, StringComparison.OrdinalIgnoreCase) || x.Cloud is { } r && matches.Contains(r.Id)).OrderByDescending(x => x.CreatedAt).ToArray();
        var selected = Selected?.Key;
        displayed = rows;
        emptyList.Text = query.Length == 0 ? "还没有录音\n开始录音，或导入已有音频。" : "没有找到匹配的录音。";
        emptyList.Visibility = rows.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        loadMore.Visibility = nextCursor is null ? Visibility.Collapsed : Visibility.Visible;
        rebuild = true;
        try { list.ItemsSource = rows; list.SelectedItem = rows.FirstOrDefault(x => x.Key == selected); }
        finally { rebuild = false; }
        if (selected is not null && Selected is null) await Select(true);
        else if (Selected is { } current)
        {
            if (detailLayout.Visibility == Visibility.Collapsed || localView && current.Local is null || !localView && current.Cloud is null)
                await Select(current.Cloud is null);
            else
            {
                // A background upload can attach a cloud copy without changing the row key.
                // Reconcile available actions without rebuilding playback or an active draft.
                UpdateCopyActions(current);
                heading.Text = current.Title;
            }
        }
    }
    private void UpdateCopyActions(LibraryRecording selected)
    {
        var visibility = selected.Local is not null && selected.Cloud is not null ? Visibility.Visible : Visibility.Collapsed;
        localCopy.Visibility = cloudCopy.Visibility = visibility;
    }
    private async Task Select(bool preferLocal)
    {
        var version = ++generation; detailRequest.Cancel(); detailRequest.Dispose(); detailRequest = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        ask?.Dispose(); review?.Dispose();
        askTab.Content = null; reviewTab.Content = null;
        ask = null; review = null;
        content = null; summary.Text = ""; transcript.ItemsSource = null; ResetPlayback(); selectedDurationMs = 0; RenderPlayback();
        filter.Text = ""; speaker.ItemsSource = null;
        var selected = Selected;
        detailLayout.Visibility = selected is null ? Visibility.Collapsed : Visibility.Visible;
        emptyDetail.Visibility = selected is null ? Visibility.Visible : Visibility.Collapsed;
        if (selected is null) { heading.Text = "选择录音"; location.Text = ""; return; }
        UpdateCopyActions(selected);
        heading.Text = selected.Title; location.Text = selected.Location;
        selectedDurationMs = Math.Max(0, selected.Local?.DurationMs ?? selected.Cloud?.DurationMs ?? 0); RenderPlayback();
        askTab.Content = Ui.Text("连接账号并完成云端处理后，可向这段录音提问。");
        reviewTab.Content = Ui.Text("通过「更多操作」上传录音后，可在这里查看处理历史。");
        localView = preferLocal && selected.Local is not null || selected.Cloud is null;
        if (localView && selected.Local is { } localRecording)
        {
            summary.Text = "这段录音保存在本机。\n\n实时字幕可在「逐字稿」中查看；连接账号后，可通过「更多操作」上传并生成摘要。";
            location.Text = "本机 · " + (localRecording.State switch
            {
                RecordingState.Starting => "正在启动", RecordingState.Recording => "录音中", RecordingState.Stopping => "正在保存",
                RecordingState.Done => "已保存", RecordingState.Error => "录音异常", _ => "准备录音"
            }) + (localRecording.Error is { } error ? " · " + error : "");
            if (localRecording.State is RecordingState.Done or RecordingState.Error)
            {
                var cancellation = detailRequest.Token;
                var rows = await Task.Run(() => CaptionArchiveOrder.Read(app.Store.CaptionPath(localRecording)).Select(x =>
                {
                    cancellation.ThrowIfCancellationRequested();
                    return new CloudTranscriptSegment(CaptionText.Format(x.Text, x.IsFailed), x.Stream == "translation" ? "译文" : "原文", null, null);
                }).ToArray(), cancellation);
                if (!IsCurrent(version)) return;
                // Local text exports stream from the archive; avoid duplicating the entire transcript string.
                content = new CloudTranscript("", "", "") { Segments = rows }; RenderTranscript();
            }
            return;
        }
        var cloudRecording = selected.Cloud!;
        summary.Text = "正在加载摘要…";
        var snapshot = app.Account.Snapshot;
        if (snapshot.Account is not { } account) return;
        if (snapshot.State == AccountState.Offline)
        {
            askTab.Content = Ui.Text("当前离线，重新连接账号后可继续提问。");
            reviewTab.Content = Ui.Text("当前离线，处理历史需要连接云端。");
            content = cache.Load(account.Partition, cloudRecording.Id)?.Transcript;
            summary.Text = content is null ? "离线缓存不可用。" : SummaryText(content); RenderTranscript(); return;
        }
        if (snapshot.State != AccountState.SignedIn) return;
        using var client = app.Account.Client(account);
        try
        {
            var loaded = CloudTranscript.Parse(await client.TranscriptAsync(cloudRecording.Id, cancellation: detailRequest.Token));
            if (!IsCurrent(version, account)) return;
            content = loaded; ApplySpeakerProfiles(account.Partition, cloudRecording.Id);
            cache.Save(account.Partition, cloudRecording, content); summary.Text = SummaryText(content);
            speaker.ItemsSource = new[] { "全部说话人" }.Concat(content.Segments.Select(x => x.Speaker).Where(x => x is not null).Distinct()).ToArray(); speaker.SelectedIndex = 0; RenderTranscript();
        }
        catch (CloudException error) when (error.Status == System.Net.HttpStatusCode.NotFound)
        {
            if (!IsCurrent(version, account)) return;
            summary.Text = "暂无逐字稿，可在处理历史中查看进度或重新转录。";
        }
        review = new ReviewPanel(this, app, account, cloudRecording, () => IsCurrent(version, account), async jobId =>
        {
            using var connection = app.Account.Client(account);
            var value = CloudTranscript.Parse(await connection.TranscriptAsync(cloudRecording.Id, jobId, detailRequest.Token));
            if (!IsCurrent(version, account)) return; content = value; ApplySpeakerProfiles(account.Partition, cloudRecording.Id); summary.Text = SummaryText(value); RenderTranscript(); review?.UpdateTranscript(value);
        });
        ask = new AskPanel(this, app, account, cloudRecording.Id, () => IsCurrent(version, account), async citation =>
        {
            await LoadAudio(); if (IsCurrent(version, account) && citation.StartMs is { } ms) SeekAudio(TimeSpan.FromMilliseconds(ms));
        });
        reviewTab.Content = new ScrollViewer { Content = review.Root, HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        askTab.Content = ask.Root;
        if (content is not null) review.UpdateTranscript(content);
        await Task.WhenAll(review.Load(), ask.Load());
    }
    private async void TranscriptTimestampClick(object sender, RoutedEventArgs args)
    {
        if (sender is Button { Tag: CloudTranscriptSegment segment } && transcript.Items.Contains(segment)) await SeekTranscript(segment);
    }
    private async Task SeekTranscript(CloudTranscriptSegment segment)
    {
        if (segment.StartMs is not { } ms) return;
        var version = generation;
        await Run(async () => { if (audioPath is null) await LoadAudio(); if (IsCurrent(version) && audioPath is not null) SeekAudio(TimeSpan.FromMilliseconds(ms)); });
    }
    private void RenderTranscript()
    {
        var selectedSpeaker = speaker.SelectedItem as string;
        transcript.ItemsSource = content?.Segments.Where(x => x.Text.Contains(filter.Text, StringComparison.OrdinalIgnoreCase) &&
            (selectedSpeaker is null or "全部说话人" || x.Speaker == selectedSpeaker)).ToArray();
    }
    private async Task Import()
    {
        if (closed || import is not null) return;
        using var pending = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); import = pending;
        var decoding = true;
        cancelImport.Visibility = Visibility.Visible; importStatus.Visibility = Visibility.Visible; importStatus.Text = "选择要导入的音频…";
        try
        {
            var file = await pickImportFile();
            if (file is null) return; pending.Token.ThrowIfCancellationRequested();
            var recording = await importAudio(file,
                new Progress<double>(value =>
                {
                    if (!closed && ReferenceEquals(import, pending) && decoding && !pending.IsCancellationRequested)
                        importStatus.Text = $"正在导入 {value:P0}";
                }), pending.Token);
            decoding = false;
            if (closed) return;
            cancelImport.Visibility = Visibility.Collapsed;
            importStatus.Text = "导入完成"; await Refresh();
            list.SelectedItem = displayed.FirstOrDefault(x => x.Local?.Id == recording.Id);
        }
        catch (OperationCanceledException) when (pending.IsCancellationRequested)
        {
            // The import status owns expected cancellation feedback; avoid a second window-level error.
        }
        catch (System.Runtime.InteropServices.COMException error) when (error.HResult == unchecked((int)0xC00D36C4))
        {
            if (!closed) importStatus.Visibility = Visibility.Collapsed;
            throw new InvalidDataException("无法读取这个音频文件，文件可能已损坏或格式不受支持。请尝试其他音频，或先转换为 WAV/MP3。", error);
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            if (!closed) importStatus.Text = "导入失败";
            throw;
        }
        finally
        {
            decoding = false;
            import = null;
            if (!closed)
            {
                cancelImport.Visibility = Visibility.Collapsed;
                if (pending.IsCancellationRequested) importStatus.Text = "导入已取消";
                else if (importStatus.Text == "选择要导入的音频…") importStatus.Visibility = Visibility.Collapsed;
            }
        }
    }
    private async Task<string?> PickImportFile()
    {
        var picker = new FileOpenPicker(); WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        foreach (var type in new[] { ".wav", ".mp3", ".m4a", ".mp4", ".aac", ".flac", ".wma" }) picker.FileTypeFilter.Add(type);
        return (await picker.PickSingleFileAsync())?.Path;
    }
    private static string SummaryText(CloudTranscript transcript) => !string.IsNullOrWhiteSpace(transcript.Summary) ? transcript.Summary : transcript.SummaryStatus switch
    {
        "skipped" => "这段录音未生成摘要。可在处理历史中重新生成摘要。",
        "pending" or "queued" or "processing" or "running" => "摘要正在生成，可稍后刷新查看。",
        "failed" => "摘要生成失败。可在处理历史中重试。",
        _ => "暂无摘要。可查看逐字稿，或在处理历史中重新生成摘要。"
    };
    private async Task LoadAudio()
    {
        if (audioPath is not null && player.Source is not null) return;
        var pending = audioLoading ??= LoadAudioCore();
        try { await pending; }
        finally { if (ReferenceEquals(audioLoading, pending)) audioLoading = null; }
    }
    private async Task LoadAudioCore()
    {
        var selected = Selected; if (selected is null) return; var version = generation;
        string sourcePath;
        if (localView && selected.Local is { } recording)
        {
            if (recording.State is not (RecordingState.Done or RecordingState.Error)) throw new InvalidOperationException("请先结束录音。");
            sourcePath = recording.AudioPath;
        }
        else
        {
            var account = RequireAccount(); var cloud = selected.Cloud!;
            var directory = Path.Combine(app.ApplicationRoot, "Playback", account.Partition); Directory.CreateDirectory(directory);
            var path = Path.Combine(directory, Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(cloud.Id))) + ".audio");
            using var client = app.Account.Client(account);
            var downloaded = await client.DownloadAudioAsync(cloud.Id, path, detailRequest.Token);
            if (!IsCurrent(version, account)) return; sourcePath = downloaded;
        }
        if (!IsCurrent(version)) return;
        if (!File.Exists(sourcePath)) throw new FileNotFoundException("音频文件不存在，请检查本机副本或重新下载。", sourcePath);
        // A player belongs to exactly one source. Late callbacks from a previous source
        // must not clear or reposition the newly selected recording.
        ResetPlayback();
        player.MediaOpened += PlaybackOpened;
        player.MediaFailed += PlaybackFailed;
        player.PlaybackSession.PlaybackStateChanged += PlaybackStateChanged;
        try
        {
            // Open with .NET's long-path support instead of making Media Foundation
            // resolve a file URI, which can fail for deep account cache directories.
            playbackFile = File.OpenRead(sourcePath);
            playbackStream = playbackFile.AsRandomAccessStream();
            var contentType = Path.GetExtension(sourcePath).ToLowerInvariant() switch
            {
                ".wav" => "audio/wav", ".mp3" => "audio/mpeg", ".m4a" or ".mp4" => "audio/mp4",
                ".aac" => "audio/aac", ".ogg" => "audio/ogg", ".webm" => "audio/webm",
                ".flac" => "audio/flac", ".wma" => "audio/x-ms-wma", _ => "application/octet-stream"
            };
            playbackSource = MediaSource.CreateFromStream(playbackStream, contentType);
            audioPath = sourcePath; player.Source = playbackSource;
        }
        catch { ResetPlayback(); throw; }
    }
    private void DisposePlayback()
    {
        playbackTimer.Stop();
        player.MediaOpened -= PlaybackOpened;
        player.MediaFailed -= PlaybackFailed;
        player.PlaybackSession.PlaybackStateChanged -= PlaybackStateChanged;
        media.SetMediaPlayer(null);
        player.Source = null; player.Dispose(); playbackSource?.Dispose(); playbackSource = null;
        playbackStream?.Dispose(); playbackStream = null;
        playbackFile?.Dispose(); playbackFile = null;
        audioPath = null; pendingSeek = null; mediaOpened = false;
    }
    private void ResetPlayback()
    {
        var rate = player.PlaybackSession.PlaybackRate;
        DisposePlayback();
        player = new MediaPlayer { AutoPlay = false };
        player.PlaybackSession.PlaybackRate = rate;
        media.SetMediaPlayer(player);
        audioLoading = null;
    }
    private void PlaybackOpened(MediaPlayer sender, object args) => UiDispatcher.TryEnqueue(() =>
    {
        if (closed || !ReferenceEquals(sender, player)) return;
        mediaOpened = true;
        if (pendingSeek is { } position) SeekAudio(position);
        RenderPlayback();
    });
    private void PlaybackStateChanged(MediaPlaybackSession sender, object args) => UiDispatcher.TryEnqueue(() =>
    {
        if (!closed && ReferenceEquals(sender, player.PlaybackSession)) RenderPlayback();
    });
    private void PlaybackFailed(MediaPlayer sender, MediaPlayerFailedEventArgs args)
    {
        var message = string.IsNullOrWhiteSpace(args.ErrorMessage)
            ? $"无法读取此音频，请重试或检查文件。({args.Error}, 0x{args.ExtendedErrorCode?.HResult ?? 0:X8})"
            : args.ErrorMessage;
        UiDispatcher.TryEnqueue(() =>
        {
            if (closed || !ReferenceEquals(sender, player)) return;
            ResetPlayback(); SetError("音频播放失败：" + message); RenderPlayback();
        });
    }
    private void SeekAudio(TimeSpan position)
    {
        if (!mediaOpened) { pendingSeek = position; return; }
        pendingSeek = null;
        var session = player.PlaybackSession;
        if (session.CanSeek) session.Position = TimeSpan.FromSeconds(Math.Clamp(position.TotalSeconds, 0, session.NaturalDuration.TotalSeconds));
        RenderPlayback();
    }
    private async Task TogglePlayback()
    {
        var version = generation;
        if (audioPath is null) await LoadAudio();
        if (!IsCurrent(version) || audioPath is null) return;
        if (player.PlaybackSession.PlaybackState == MediaPlaybackState.Playing) player.Pause(); else player.Play();
        RenderPlayback();
    }
    private void RenderPlayback()
    {
        if (closed) return;
        var session = player.PlaybackSession;
        if (session.PlaybackState == MediaPlaybackState.Playing) playbackTimer.Start(); else playbackTimer.Stop();
        var duration = !mediaOpened ? TimeSpan.FromMilliseconds(selectedDurationMs) : session.NaturalDuration;
        var position = audioPath is null ? TimeSpan.Zero : session.Position;
        updatingSeek = true;
        try { seek.Maximum = Math.Max(1, duration.TotalSeconds); seek.Value = Math.Clamp(position.TotalSeconds, 0, seek.Maximum); seek.IsEnabled = mediaOpened && session.CanSeek && duration.TotalSeconds > 0; }
        finally { updatingSeek = false; }
        static string Stamp(TimeSpan value) => value.TotalHours >= 1 ? value.ToString(@"h\:mm\:ss") : value.ToString(@"mm\:ss");
        playbackTime.Text = Stamp(position) + " / " + Stamp(duration);
        if (play.Content is FontIcon icon) icon.Glyph = session.PlaybackState == MediaPlaybackState.Playing ? "\uE769" : "\uE768";
    }
    private async Task<string?> SavePath(string name, string extension)
    {
        var picker = new FileSavePicker { SuggestedFileName = name };
        picker.FileTypeChoices.Add(extension, new List<string> { extension });
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        return (await picker.PickSaveFileAsync())?.Path;
    }
    private void CheckExportPath(string path)
    {
        var root = Path.TrimEndingDirectorySeparator(app.Store.Root);
        var full = Path.GetFullPath(path);
        if (full.Equals(root, StringComparison.OrdinalIgnoreCase) || full.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("请选择录音存储目录以外的位置。");
    }
    private async Task ExportAudio()
    {
        var version = generation; var selected = Selected; if (selected is null) return;
        if (audioPath is null) await LoadAudio(); if (!IsCurrent(version) || audioPath is null) return;
        var source = audioPath; var destination = await SavePath("录音副本", Path.GetExtension(source));
        if (destination is null || !IsCurrent(version)) return; CheckExportPath(destination);
        await Task.Run(() => File.Copy(source, destination, true));
    }
    private Task OpenFolder()
    {
        var directory = Selected?.Local?.Directory ?? app.Store.Root;
        Directory.CreateDirectory(directory); Process.Start(new ProcessStartInfo(directory) { UseShellExecute = true }); return Task.CompletedTask;
    }
    private async Task Upload()
    {
        var selected = Selected?.Local; if (selected is null) throw new InvalidOperationException("请选择本机录音。");
        var account = RequireAccount(); await app.Processing.StartAsync(selected, account, selected.Processing ?? app.Preferences.Processing); await Refresh();
    }
    private async Task RemoveLocal()
    {
        var recording = Selected?.Local; var version = generation; if (recording is null) return;
        if (!await Confirm("从本机库移除", $"移除“{recording.Title}”的库记录？音频、字幕文件和云端副本会保留。", "移除") || !IsCurrent(version)) return;
        ResetPlayback(); app.Store.RemoveFromLibrary(recording); await Refresh();
    }
    private async Task DeleteCloud()
    {
        var recording = Selected?.Cloud; var version = generation; if (recording is null) return; var account = RequireAccount();
        if (!await Confirm("删除云端录音", $"删除“{recording.Title}”的云端录音及处理结果？本机文件会保留。", "删除") || !IsCurrent(version, account)) return;
        using var client = app.Account.Client(account); await client.DeleteAsync(recording.Id, detailRequest.Token);
        cache.Delete(account.Partition, recording.Id); await app.Processing.ForgetRemoteAsync(account.Partition, recording.Id);
        if (IsCurrent(version, account)) await Refresh();
    }
    private async Task ExportText()
    {
        if (localView) { await ExportCaptions(false); return; }
        if (content is null) return; var version = generation; var text = content.Summary + "\n\n" + content.Text;
        var path = await SavePath("录音文字", ".txt"); if (path is null || !IsCurrent(version)) return;
        CheckExportPath(path); await File.WriteAllTextAsync(path, text);
    }
    private async Task ExportCaptions(bool json)
    {
        var recording = Selected?.Local; var version = generation; if (recording is null) throw new InvalidOperationException("请选择有字幕归档的本机录音。");
        await app.StopCaptionsIfFinished();
        var path = await SavePath("录音字幕", json ? ".jsonl" : ".txt"); if (path is null || !IsCurrent(version)) return;
        await Task.Run(() => CaptionExport.Save(app.Store, recording, path, json));
    }
    private Task OpenBrowser()
    {
        var recording = Selected?.Cloud; if (recording is null) return Task.CompletedTask; var account = RequireAccount();
        var uri = new Uri(CloudClient.ValidateOrigin(account.Origin), "/recordings/" + Uri.EscapeDataString(recording.Id));
        Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true }); return Task.CompletedTask;
    }
    private async Task EditSpeaker()
    {
        var selected = Selected?.Cloud; var version = generation; if (selected is null || localView) return;
        var account = RequireAccount(); var label = speaker.SelectedItem as string;
        if (label is null or "全部说话人") label = (transcript.SelectedItem as CloudTranscriptSegment)?.Speaker;
        if (label is null) throw new InvalidOperationException("请先选择一个说话人或逐字稿片段。");
        var existing = profiles.Load(account.Partition, selected.Id).GetValueOrDefault(label);
        var name = new TextBox { Header = "姓名", Text = existing?.Name ?? label, MaxLength = 100 };
        var emoji = new TextBox { Header = "图标", Text = existing?.Emoji ?? "", MaxLength = 16 };
        var note = new TextBox { Header = "备注", Text = existing?.Note ?? "", MaxLength = 1000, AcceptsReturn = true };
        var form = new StackPanel { Spacing = 10 }; form.Children.Add(name); form.Children.Add(emoji); form.Children.Add(note);
        var dialog = new ContentDialog { Title = "说话人显示资料", Content = form, XamlRoot = Content.XamlRoot, RequestedTheme = ((FrameworkElement)Content).ActualTheme, PrimaryButtonText = "保存", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary || !IsCurrent(version, account)) return;
        profiles.Save(account.Partition, selected.Id, label, new SpeakerProfile(name.Text, emoji.Text, note.Text));
        ApplySpeakerProfiles(account.Partition, selected.Id); RenderTranscript();
    }
    private void ApplySpeakerProfiles(string scope, string id)
    {
        if (content is null) return;
        var saved = profiles.Load(scope, id);
        content = content with { Segments = content.Segments.Select(x => x with { Profile = x.Speaker is { } label ? saved.GetValueOrDefault(label) : null }).ToArray() };
    }
}
