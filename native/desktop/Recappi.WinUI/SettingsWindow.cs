using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Recappi.Core;

namespace Recappi.WinUI;

internal sealed class SettingsWindow : DesktopWindow
{
    private readonly IDesktopHost app;
    private readonly Dictionary<Control, Func<DesktopPreferences, DesktopPreferences>> pending = [];
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer timer;
    private readonly TextBlock saved = Ui.Text("");
    private readonly Button retrySave;
    private StackPanel section = null!;
    private StackPanel? group;
    private readonly StackPanel tabStrip = new() { Orientation = Orientation.Horizontal, Spacing = 2 };
    private readonly List<(string Name, Button Button)> tabs = [];
    private readonly NavigationView navigation = new() { IsSettingsVisible = false, IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed, PaneDisplayMode = NavigationViewPaneDisplayMode.Top, IsPaneToggleButtonVisible = false };
    private readonly Dictionary<string, StackPanel> sections = [];
    // Section names stay Chinese as keys (navigation tags, tests); this maps them to the shown label.
    private readonly Dictionary<string, string> sectionLabels = [];
    private readonly ScrollViewer sectionViewer = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
    private readonly TextBlock updateStatus = Ui.Text("");
    private readonly CancellationTokenSource lifetime = new();
    private CancellationTokenSource? download;
    private DesktopRelease? release;
    private bool checkingUpdate;
    private bool closed;
    private readonly Button downloadUpdate;
    private readonly Button cancelUpdate;
    private readonly DesktopDistribution distribution;
    private readonly Func<DesktopUpdates> createUpdates;
    private static string CurrentVersion => typeof(SettingsWindow).Assembly.GetCustomAttributes(typeof(System.Reflection.AssemblyInformationalVersionAttribute), false)
        .OfType<System.Reflection.AssemblyInformationalVersionAttribute>().FirstOrDefault()?.InformationalVersion ?? "0.1.0-preview.1";
    public SettingsWindow(IDesktopHost app, bool recovery, DesktopDistribution? distribution = null, Func<DesktopUpdates>? createUpdates = null) : base(L.T("Recappi Mini · 设置", "Recappi Mini · Settings"), 600, 640)
    {
        this.app = app;
        this.distribution = distribution ?? DesktopDistributionDetector.Detect();
        this.createUpdates = createUpdates ?? (() => new DesktopUpdates());
        timer = DispatcherQueue.CreateTimer(); timer.Interval = TimeSpan.FromMilliseconds(350); timer.Tick += (_, _) => Flush();
        retrySave = Ui.Button(L.T("重新保存设置", "Save again"), () => { Flush(); return Task.CompletedTask; }, this);
        retrySave.Visibility = Visibility.Collapsed;
        // Save status sits above the navigation and collapses when there is nothing to report.
        var heading = new Grid { ColumnSpacing = 12 }; heading.ColumnDefinitions.Add(new ColumnDefinition()); heading.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        saved.Style = RecappiTheme.Style("RecappiBodySecondary"); saved.FontSize = 12.5; saved.VerticalAlignment = VerticalAlignment.Center;
        heading.Children.Add(saved); Grid.SetColumn(retrySave, 1); heading.Children.Add(retrySave);
        Body.Padding = new Thickness(20, 0, 20, 4); Body.Spacing = 6; Body.Children.Add(heading);
        Error.Style = RecappiTheme.Style("RecappiError"); Error.FontSize = 12;
        saved.Visibility = Visibility.Collapsed;
        ((ScrollViewer)Content).Content = null;
        var layout = new Grid(); layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); layout.RowDefinitions.Add(new RowDefinition());
        layout.Children.Add(Body); Grid.SetRow(navigation, 1); layout.Children.Add(navigation); Content = PageFrame(layout, L.T("设置", "Settings")); CloseWithKeyboard(layout, Flush);
        navigation.Content = sectionViewer;
        // Each tab sizes the window to its content, like the macOS preferences window.
        FitHeightTo(sectionViewer);
        // Tall toolbar tabs so the icon-over-label items clear the selection indicator.
        navigation.IsPaneVisible = false;
        tabStrip.HorizontalAlignment = HorizontalAlignment.Center; tabStrip.Margin = new Thickness(0, 0, 0, 6);
        var toolbar = new Border { Child = tabStrip, BorderThickness = new Thickness(0, 0, 0, 1) };
        RecappiTheme.Bind(toolbar, "RecappiBorderHairline", brush => toolbar.BorderBrush = brush);
        layout.RowDefinitions.Insert(1, new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(toolbar, 1); layout.Children.Add(toolbar); Grid.SetRow(navigation, 2);
        navigation.SelectionChanged += (_, args) =>
        {
            if (args.SelectedItem is NavigationViewItem { Tag: string key }) { sectionViewer.Content = sections[key]; Title = "Recappi Mini · " + sectionLabels[key]; }
            PaintTabs();
        };
        // Tab colours follow theme changes too (a light brush stayed on the selected tab in dark mode).
        tabStrip.ActualThemeChanged += (_, _) => PaintTabs();
        if (recovery)
        {
            saved.Text = L.T("设置读取失败。已暂时关闭自动上传、自动转写、实时字幕、麦克风和录音建议。原设置尚未覆盖；修改后保存。",
                "Couldn't read settings. Auto upload, auto transcribe, live captions, microphone and recording suggestions are off for now. Your original settings are untouched; change something to save.");
            saved.Visibility = Visibility.Visible;
        }
        Section("通用", "General", Symbol.Setting);
        Choice("外观", "Appearance", app.Preferences.Theme, ["system", "light", "dark"], (p, v) => p with { Theme = v });
        AddRow(L.T("重新打开使用引导", "Show onboarding again"), Ui.Button(L.T("重新开始", "Start over"), () => { app.ShowOnboarding(true); return Task.CompletedTask; }, this));
        AddRow(L.T("Windows 麦克风权限", "Windows microphone access"), Ui.Button(L.T("打开设置", "Open Settings"), () => { Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true }); return Task.CompletedTask; }, this));
        Section("云端处理", "Cloud", Symbol.Upload);
        Toggle("保存后自动上传", "Upload after saving", app.Preferences.AutoUpload, (p, v) => p with { AutoUpload = v });
        Toggle("上传后自动转写", "Transcribe after upload", app.Preferences.AutoTranscribe, (p, v) => p with { AutoTranscribe = v });
        Language("转写语言", "Transcription language", app.Preferences.TranscriptionLanguage, "auto", L.T("自动识别", "Auto-detect"), (p, v) => p with { TranscriptionLanguage = v });
        Choice("场景", "Scene", app.Preferences.Scene, ["meeting", "podcast", "interview", "casual", "lecture"], (p, v) => p with { Scene = v });
        Field("额外上下文", "Extra context", app.Preferences.ExtraContext, (p, v) => p with { ExtraContext = v });
        // The account is a row like every other setting, not a loose button under the group.
        group = null;
        var accountState = new TextBlock { Style = RecappiTheme.Style("RecappiCaption"), FontSize = 11.5, TextTrimming = TextTrimming.CharacterEllipsis };
        void ShowAccountState() => accountState.Text = app.Account.Snapshot is { State: AccountState.SignedIn, Account: { } signedIn } ? L.T("已连接 · ", "Connected · ") + (signedIn.Email ?? "Recappi Cloud") : L.T("未连接，云端处理需要先连接账号", "Not connected. Connect an account to use Cloud processing.");
        ShowAccountState();
        void AccountChanged(AccountSnapshot _) => UiDispatcher.TryEnqueue(() => { if (!closed) ShowAccountState(); });
        app.Account.Changed += AccountChanged; Closed += (_, _) => app.Account.Changed -= AccountChanged;
        AddRow(Labelled(L.T("Recappi 账号", "Recappi account"), accountState), Ui.Button(L.T("管理账号", "Manage account"), () => { app.ShowAccount(); return Task.CompletedTask; }, this));
        Section("录音与字幕", "Captions", Symbol.Microphone);
        Toggle("开启实时字幕", "Live captions", app.Preferences.CaptionsEnabled, (p, v) => p with { CaptionsEnabled = v });
        Toggle("默认录制麦克风", "Record microphone by default", app.Preferences.IncludeMicrophone, (p, v) => p with { IncludeMicrophone = v });
        Language("字幕语言", "Caption language", app.Preferences.CaptionLanguage, null, null, (p, v) => p with { CaptionLanguage = v });
        Language("翻译为", "Translate to", app.Preferences.TranslationLanguage, "", L.T("不翻译", "Don't translate"), (p, v) => p with { TranslationLanguage = v });
        Section("录音提醒", "Reminders", Symbol.Important);
        Toggle("应用声音录音建议", "Suggest recording for app audio", app.Preferences.RecordingSuggestions, (p, v) => p with { RecordingSuggestions = v });
        Toggle("声音不活跃提醒", "Remind when audio goes quiet", app.Preferences.InactivityReminders, (p, v) => p with { InactivityReminders = v });
        MinutesChoice("隐藏录音时提醒", "Remind while bar is hidden", app.Preferences.LongReminderMinutes, (p, v) => p with { LongReminderMinutes = v });
        MinutesChoice("录音时长提醒", "Recording length reminder", app.Preferences.MaxDurationMinutes, (p, v) => p with { MaxDurationMinutes = v });
        Section("存储", "Storage", Symbol.Folder);
        // macOS-style rows: what it is on the left (with its detail beneath), actions on the right.
        var folder = new TextBlock { Text = app.Preferences.RecordingsRoot, Style = RecappiTheme.Style("RecappiCaption"), FontSize = 11.5, TextTrimming = TextTrimming.CharacterEllipsis, IsTextSelectionEnabled = true };
        ToolTipService.SetToolTip(folder, app.Preferences.RecordingsRoot);
        var change = Ui.Button(L.T("更改…", "Change…"), () => PickRecordingsRoot(folder), this);
        var reveal = Ui.Button(L.T("打开", "Open"), () =>
        {
            var path = folder.Text; if (Directory.Exists(path)) Process.Start(new ProcessStartInfo("explorer.exe", "\"" + path + "\"") { UseShellExecute = true });
            return Task.CompletedTask;
        }, this);
        AddRow(Labelled(L.T("本地录音目录", "Recordings folder"), folder), new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { change, reveal } });
        section.Children.Add(Note(L.T("更改后重启 Recappi 生效；已有录音不会移动。", "Takes effect after restarting Recappi. Existing recordings aren't moved.")));
        // About is its own page, laid out like the macOS About panel: centred identity, then updates.
        Section("关于", "About", Symbol.Help);
        var identity = new StackPanel { Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 12, 0, 8) };
        var logo = RecappiTheme.LogoTile(72); logo.HorizontalAlignment = HorizontalAlignment.Center; logo.Margin = new Thickness(0, 0, 0, 6);
        identity.Children.Add(logo);
        identity.Children.Add(new TextBlock { Text = "Recappi Mini", Style = RecappiTheme.Style("RecappiSectionTitle"), FontSize = 20, HorizontalAlignment = HorizontalAlignment.Center });
        identity.Children.Add(new TextBlock { Text = L.T("版本 ", "Version ") + CurrentVersion.Split('+')[0], Style = RecappiTheme.Style("RecappiBodySecondary"), FontSize = 12.5, HorizontalAlignment = HorizontalAlignment.Center });
        identity.Children.Add(new TextBlock { Text = L.T("Windows 原生桌面版 · WinUI 3", "Native Windows app · WinUI 3"), Style = RecappiTheme.Style("RecappiCaption"), FontSize = 11.5, HorizontalAlignment = HorizontalAlignment.Center });
        var releases = Ui.Button(L.T("发布页面", "Release page"), () => { Process.Start(new ProcessStartInfo(DesktopUpdates.ReleasesPage.AbsoluteUri) { UseShellExecute = true }); return Task.CompletedTask; }, this);
        releases.Style = RecappiTheme.Style("RecappiQuietButton"); releases.HorizontalAlignment = HorizontalAlignment.Center;
        RecappiTheme.Bind(releases, "RecappiAccent", brush => releases.Foreground = brush);
        // Only the portable build updates from the release page; installed builds use their channel.
        releases.Visibility = this.distribution == DesktopDistribution.Portable ? Visibility.Visible : Visibility.Collapsed;
        identity.Children.Add(releases);
        section.Children.Add(identity);
        updateStatus.Style = RecappiTheme.Style("RecappiCaption"); updateStatus.FontSize = 11.5; updateStatus.TextWrapping = TextWrapping.Wrap; updateStatus.TextTrimming = TextTrimming.None;
        var checkUpdate = Ui.Button(L.T("检查更新", "Check for updates"), CheckUpdate, this);
        downloadUpdate = Ui.Button(L.T("下载更新", "Download update"), DownloadUpdate, this); downloadUpdate.IsEnabled = false;
        cancelUpdate = Ui.Button(L.T("取消下载", "Cancel download"),() => { download?.Cancel(); return Task.CompletedTask; }, this); cancelUpdate.IsEnabled = false;
        // Download and cancel appear only when they can act, instead of sitting there disabled.
        foreach (var conditional in new[] { downloadUpdate, cancelUpdate })
        {
            conditional.Visibility = Visibility.Collapsed;
            conditional.IsEnabledChanged += (_, _) => conditional.Visibility = conditional.IsEnabled ? Visibility.Visible : Visibility.Collapsed;
        }
        if (this.distribution == DesktopDistribution.Portable)
        {
            updateStatus.Text = L.T("从官方发布页面检查新版本。", "Checks the official releases page for new versions.");
            AddRow(Labelled(L.T("软件更新", "Software update"), updateStatus), Ui.Row(checkUpdate, downloadUpdate, cancelUpdate));
        }
        else
        {
            checkUpdate.IsEnabled = false;
            updateStatus.Text = this.distribution == DesktopDistribution.Packaged
                ? L.T("当前为 MSIX 安装版，更新由原安装渠道管理。从 Microsoft Store 安装的版本，请在商店中检查更新；测试或组织分发的版本，请使用原渠道提供的新版安装包。",
                    "This is the MSIX install; updates come through the channel you installed from. If you installed from the Microsoft Store, check for updates there. For test or organization builds, use the new installer from that channel.")
                : L.T("暂时无法识别此应用的安装方式。请关闭并重新打开设置后重试，或从原安装渠道获取更新。",
                    "Can't tell how this app was installed. Close and reopen Settings to try again, or get updates from where you installed it.");
            var store = Ui.Button(L.T("打开 Microsoft Store 更新", "Update in Microsoft Store"), () =>
            {
                Process.Start(new ProcessStartInfo("ms-windows-store://downloadsandupdates") { UseShellExecute = true });
                return Task.CompletedTask;
            }, this);
            store.Visibility = this.distribution == DesktopDistribution.Packaged ? Visibility.Visible : Visibility.Collapsed;
            AddRow(Labelled(L.T("软件更新", "Software update"), updateStatus), store);
        }
        foreach (var page in sections.Values) foreach (var button in page.Children.OfType<Button>()) RecappiTheme.Compact(button);
        foreach (var button in new[] { change, reveal, checkUpdate, downloadUpdate, cancelUpdate }) RecappiTheme.Compact(button);
        navigation.SelectedItem = navigation.MenuItems[0];
        AppWindow.Closing += (_, e) => { if (!Flush()) e.Cancel = true; };
        Closed += (_, _) => { closed = true; timer.Stop(); lifetime.Cancel(); download?.Cancel(); };
    }
    private async Task CheckUpdate()
    {
        if (distribution != DesktopDistribution.Portable || checkingUpdate || download is not null) return;
        checkingUpdate = true; downloadUpdate.IsEnabled = false; release = null;
        updateStatus.Text = L.T("正在检查官方发布…", "Checking for updates…");
        try
        {
            using var updates = createUpdates();
            var runtime = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "win-arm64" : "win-x64";
            var result = await updates.CheckAsync(CurrentVersion, runtime, lifetime.Token);
            if (closed) return;
            release = result.Update;
            updateStatus.Text = release is { } available ? L.T("可用更新：", "Update available: ") + available.Version : result.HasCompatibleRelease ? L.T("已是最新版本。", "You're up to date.") : L.T("暂无适用的发布版本。", "No compatible release yet.");
        }
        catch (OperationCanceledException)
        {
            if (!closed) updateStatus.Text = L.T("检查超时，请稍后重试。", "The check timed out. Try again later.");
        }
        catch (HttpRequestException error) when (error.StatusCode is System.Net.HttpStatusCode.Forbidden or System.Net.HttpStatusCode.TooManyRequests)
        {
            if (!closed) updateStatus.Text = L.T("官方更新服务暂时拒绝请求或达到访问限额，请稍后重试，或打开发布页面。", "The update service refused the request or hit its rate limit. Try again later, or open the releases page.");
        }
        catch (Exception)
        {
            if (!closed) updateStatus.Text = L.T("无法检查更新，请稍后重试或打开官方发布页面。", "Couldn't check for updates. Try again later or open the releases page.");
        }
        finally { checkingUpdate = false; if (!closed) downloadUpdate.IsEnabled = release is not null; }
    }
    private async Task DownloadUpdate()
    {
        if (distribution != DesktopDistribution.Portable || release is not { } available || download is not null || checkingUpdate) return;
        using var pendingDownload = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
        download = pendingDownload; downloadUpdate.IsEnabled = false; cancelUpdate.IsEnabled = true;
        try
        {
            var picker = new Windows.Storage.Pickers.FileSavePicker { SuggestedFileName = Path.GetFileNameWithoutExtension(available.FileName) };
            picker.FileTypeChoices.Add(L.T("ZIP 更新包", "ZIP update package"), new List<string> { ".zip" });
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            var file = await picker.PickSaveFileAsync();
            if (file is null || closed) return;
            pendingDownload.Token.ThrowIfCancellationRequested();
            using var updates = createUpdates();
            await updates.DownloadAsync(available, file.Path, new Progress<double>(value => { if (!closed) updateStatus.Text = L.T($"正在下载 {value:P0}", $"Downloading {value:P0}"); }), pendingDownload.Token);
            if (!closed) updateStatus.Text = L.T("下载完成，完整性校验通过。解压后即可使用新版本。", "Downloaded and verified. Unzip it to use the new version.");
        }
        catch (OperationCanceledException) { if (!closed) updateStatus.Text = L.T("下载已取消。", "Download canceled."); }
        catch (Exception) { if (!closed) updateStatus.Text = L.T("下载或完整性校验失败，原文件保留，请重试。", "Download or verification failed. The original file was kept; try again."); }
        finally { download = null; if (!closed) { downloadUpdate.IsEnabled = release is not null; cancelUpdate.IsEnabled = false; } }
    }
    // name is the Chinese key (dictionary key, navigation tag); the tab shows L.T(name, english).
    private void Section(string name, string english, Symbol icon)
    {
        section = new StackPanel { Spacing = 14, Padding = new Thickness(20, 16, 20, 24), Width = 560, HorizontalAlignment = HorizontalAlignment.Center };
        sections[name] = section;
        var label = L.T(name, english); sectionLabels[name] = label;
        group = null;
        var item = new NavigationViewItem { Content = label, Tag = name };
        navigation.MenuItems.Add(item);
        var tab = new StackPanel { Spacing = 2 };
        tab.Children.Add(new SymbolIcon(icon) { HorizontalAlignment = HorizontalAlignment.Center, RenderTransform = new Microsoft.UI.Xaml.Media.ScaleTransform { ScaleX = 0.9, ScaleY = 0.9, CenterX = 10, CenterY = 10 } });
        tab.Children.Add(new TextBlock { Text = label, FontSize = 11, HorizontalAlignment = HorizontalAlignment.Center });
        var button = new Button { Content = tab, Style = RecappiTheme.Style("RecappiTabButton") };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, label);
        button.Click += (_, _) => navigation.SelectedItem = item;
        tabStrip.Children.Add(button); tabs.Add((name, button));
    }
    private void PaintTabs()
    {
        foreach (var (name, button) in tabs)
        {
            var active = navigation.SelectedItem is NavigationViewItem { Tag: string current } && current == name;
            button.Background = active ? RecappiTheme.Brush("RecappiControlHover", button.ActualTheme) : null;
            button.Foreground = RecappiTheme.Brush(active ? "RecappiAccent" : "RecappiLabelSecondary", button.ActualTheme);
        }
    }
    private void Edited(Control control, Func<DesktopPreferences, DesktopPreferences> edit) { pending[control] = edit; timer.Stop(); timer.Start(); }
    // Settings rows share one card per section: label on the left, control on the right.
    private static StackPanel Labelled(string label, TextBlock detail)
    {
        var stack = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        stack.Children.Add(new TextBlock { Text = label, Style = RecappiTheme.Style("RecappiBody"), FontSize = 13, LineHeight = 18 });
        stack.Children.Add(detail);
        return stack;
    }
    private static TextBlock Note(string text) => new() { Text = text, Style = RecappiTheme.Style("RecappiCaption"), FontSize = 11.5, Margin = new Thickness(12, -6, 0, 0), TextWrapping = TextWrapping.Wrap };
    private async Task PickRecordingsRoot(TextBlock folder)
    {
        var picker = new Windows.Storage.Pickers.FolderPicker { SuggestedStartLocation = Windows.Storage.Pickers.PickerLocationId.DocumentsLibrary };
        picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
        if (await picker.PickSingleFolderAsync() is not { } chosen || closed) return;
        folder.Text = chosen.Path; ToolTipService.SetToolTip(folder, chosen.Path);
        Edited(recordingsRootKey, p => p with { RecordingsRoot = chosen.Path });
    }
    private readonly Control recordingsRootKey = new ContentControl();
    private void AddRow(string label, FrameworkElement control) => AddRow(new TextBlock { Text = label, Style = RecappiTheme.Style("RecappiBody"), FontSize = 13, LineHeight = 18, VerticalAlignment = VerticalAlignment.Center }, control, label);
    private void AddRow(FrameworkElement left, FrameworkElement control, string? name = null)
    {
        if (group is null)
        {
            group = new StackPanel();
            var surface = Squircles.Surface(group, 10, new Thickness(0));
            var shape = Squircles.ShapeOf(surface);
            RecappiTheme.Bind(surface, "RecappiCardSubtleActive", brush => shape.Fill = brush);
            section.Children.Add(surface);
        }
        var row = new Grid { ColumnSpacing = 16, Padding = new Thickness(12, 5, 10, 5), MinHeight = 40, BorderThickness = new Thickness(0, group.Children.Count == 0 ? 0 : 1, 0, 0) };
        RecappiTheme.Bind(row, "RecappiBorderHairline", brush => row.BorderBrush = brush);
        row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.Children.Add(left);
        if (control is ComboBox picker) RecappiTheme.ChipPicker(picker); else if (control is Control input and not ToggleSwitch) RecappiTheme.Compact(input);
        control.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(control, 1); row.Children.Add(control);
        if (name is not null) Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(control, name);
        group.Children.Add(row);
    }
    // label is the Chinese key kept in the control's Tag (tests find controls by it); the row shows L.T(label, english).
    private void Toggle(string label, string english, bool initial, Func<DesktopPreferences, bool, DesktopPreferences> edit)
    {
        var control = new ToggleSwitch { Tag = label, IsOn = initial, OnContent = "", OffContent = "", MinWidth = 0, Margin = new Thickness(0, 0, -12, 0) };
        control.Toggled += (_, _) => Edited(control, p => edit(p, control.IsOn)); AddRow(L.T(label, english), control);
    }
    private void Field(string label, string english, string initial, Func<DesktopPreferences, string, DesktopPreferences> edit)
    {
        var control = new TextBox { Tag = label, Text = initial, Width = 200 };
        control.TextChanging += (_, _) => Edited(control, p => edit(p, control.Text)); AddRow(L.T(label, english), control);
    }
    // Pickers instead of free text for codes and numbers (language codes, minutes, "0 = off").
    private void Language(string label, string english, string initial, string? extra, string? extraName, Func<DesktopPreferences, string, DesktopPreferences> edit)
    {
        var items = new List<ComboBoxItem>();
        if (extra is not null) items.Add(new ComboBoxItem { Tag = extra, Content = extraName });
        items.AddRange(RecorderWindow.Languages.Select(x => new ComboBoxItem { Tag = x.Code, Content = x.Name }));
        if (items.All(x => (string)x.Tag != initial)) items.Add(new ComboBoxItem { Tag = initial, Content = initial.Length == 0 ? L.T("未设置", "Not set") : initial });
        Picker(label, english, items, initial, edit);
    }
    private void MinutesChoice(string label, string english, int initial, Func<DesktopPreferences, int, DesktopPreferences> edit)
    {
        var values = new[] { 0, 15, 30, 45, 60, 90, 120, 180 }.Append(initial).Distinct().Order();
        var items = values.Select(x => new ComboBoxItem { Tag = x.ToString(), Content = x == 0 ? L.T("关闭", "Off")
            : x < 60 || x % 60 != 0 ? L.T($"{x} 分钟", $"{x} min")
            : L.T($"{x / 60} 小时", x == 60 ? "1 hour" : $"{x / 60} hours") }).ToList();
        Picker(label, english, items, initial.ToString(), (p, v) => edit(p, int.Parse(v)));
    }
    private void Picker(string label, string english, List<ComboBoxItem> items, string initial, Func<DesktopPreferences, string, DesktopPreferences> edit)
    {
        var control = new ComboBox { Tag = label, ItemsSource = items, SelectedItem = items.First(x => (string)x.Tag == initial), MinWidth = 140 };
        control.SelectionChanged += (_, _) => { if (control.SelectedItem is ComboBoxItem { Tag: string value }) Edited(control, p => edit(p, value)); }; AddRow(L.T(label, english), control);
    }
    private void Choice(string label, string english, string initial, string[] values, Func<DesktopPreferences, string, DesktopPreferences> edit)
    {
        var items = values.Select(value => new ComboBoxItem { Tag = value, Content = value switch
        {
            "system" => L.T("跟随系统", "System"), "light" => L.T("浅色", "Light"), "dark" => L.T("深色", "Dark"),
            "meeting" => L.T("会议", "Meeting"), "podcast" => L.T("播客", "Podcast"),
            "interview" => L.T("访谈", "Interview"), "casual" => L.T("日常对话", "Conversation"), "lecture" => L.T("课程", "Lecture"), _ => value
        } }).ToArray();
        var control = new ComboBox { ItemsSource = items, SelectedItem = items.First(x => (string)x.Tag == initial), MinWidth = 140 };
        control.SelectionChanged += (_, _) => { if (control.SelectedItem is ComboBoxItem { Tag: string value }) Edited(control, p => edit(p, value)); }; AddRow(L.T(label, english), control);
    }
    public bool Flush()
    {
        timer.Stop(); if (pending.Count == 0) return true;
        try
        {
            var value = pending.Values.Aggregate(app.Preferences, (current, edit) => edit(current));
            app.SavePreferences(value); pending.Clear(); saved.Text = L.T("已保存", "Saved"); saved.Visibility = Visibility.Visible;
            retrySave.Visibility = Visibility.Collapsed; return true;
        }
        catch (Exception error)
        {
            saved.Text = L.T("设置未保存：", "Settings not saved: ") + error.Message; saved.Visibility = Visibility.Visible;
            retrySave.Visibility = Visibility.Visible; return false;
        }
    }
}
