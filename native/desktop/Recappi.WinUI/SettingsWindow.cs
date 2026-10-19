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
    private readonly ScrollViewer sectionViewer = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
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
    public SettingsWindow(IDesktopHost app, bool recovery, DesktopDistribution? distribution = null, Func<DesktopUpdates>? createUpdates = null) : base("Recappi Mini · 设置", 600, 640)
    {
        this.app = app;
        this.distribution = distribution ?? DesktopDistributionDetector.Detect();
        this.createUpdates = createUpdates ?? (() => new DesktopUpdates());
        timer = DispatcherQueue.CreateTimer(); timer.Interval = TimeSpan.FromMilliseconds(350); timer.Tick += (_, _) => Flush();
        retrySave = Ui.Button("重新保存设置", () => { Flush(); return Task.CompletedTask; }, this);
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
        layout.Children.Add(Body); Grid.SetRow(navigation, 1); layout.Children.Add(navigation); Content = PageFrame(layout, "设置");
        navigation.Content = sectionViewer;
        // Tall toolbar tabs so the icon-over-label items clear the selection indicator.
        navigation.IsPaneVisible = false;
        tabStrip.HorizontalAlignment = HorizontalAlignment.Center; tabStrip.Margin = new Thickness(0, 0, 0, 6);
        var toolbar = new Border { Child = tabStrip, BorderThickness = new Thickness(0, 0, 0, 1) };
        RecappiTheme.Bind(toolbar, "RecappiBorderHairline", brush => toolbar.BorderBrush = brush);
        layout.RowDefinitions.Insert(1, new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(toolbar, 1); layout.Children.Add(toolbar); Grid.SetRow(navigation, 2);
        navigation.SelectionChanged += (_, args) =>
        {
            if (args.SelectedItem is NavigationViewItem { Tag: string key }) { sectionViewer.Content = sections[key]; Title = "Recappi Mini · " + key; }
            foreach (var (name, button) in tabs)
            {
                var active = args.SelectedItem is NavigationViewItem { Tag: string current } && current == name;
                button.Background = active ? RecappiTheme.Brush("RecappiControlHover", button.ActualTheme) : null;
                button.Foreground = RecappiTheme.Brush(active ? "RecappiAccent" : "RecappiLabelSecondary", button.ActualTheme);
            }
        };
        if (recovery)
        {
            saved.Text = "设置读取失败。已暂时关闭自动上传、自动转写、实时字幕、麦克风和录音建议。原设置尚未覆盖；修改后保存。";
            saved.Visibility = Visibility.Visible;
        }
        Section("通用", Symbol.Setting);
        Choice("外观", app.Preferences.Theme, ["system", "light", "dark"], (p, v) => p with { Theme = v });
        AddRow("重新打开使用引导", Ui.Button("重新开始", () => { app.ShowOnboarding(true); return Task.CompletedTask; }, this));
        AddRow("Windows 麦克风权限", Ui.Button("打开设置", () => { Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true }); return Task.CompletedTask; }, this));
        Section("云端处理", Symbol.Upload);
        Toggle("保存后自动上传", app.Preferences.AutoUpload, (p, v) => p with { AutoUpload = v });
        Toggle("上传后自动转写", app.Preferences.AutoTranscribe, (p, v) => p with { AutoTranscribe = v });
        Field("转写语言", app.Preferences.TranscriptionLanguage, (p, v) => p with { TranscriptionLanguage = v.Trim() });
        Choice("场景", app.Preferences.Scene, ["meeting", "podcast", "interview", "casual", "lecture"], (p, v) => p with { Scene = v });
        Field("额外上下文", app.Preferences.ExtraContext, (p, v) => p with { ExtraContext = v });
        section.Children.Add(Ui.Button("连接账号", () => { app.ShowAccount(); return Task.CompletedTask; }, this));
        Section("录音与字幕", Symbol.Microphone);
        Toggle("开启实时字幕", app.Preferences.CaptionsEnabled, (p, v) => p with { CaptionsEnabled = v });
        Toggle("默认录制麦克风", app.Preferences.IncludeMicrophone, (p, v) => p with { IncludeMicrophone = v });
        Field("字幕语言", app.Preferences.CaptionLanguage, (p, v) => p with { CaptionLanguage = v.Trim() });
        Field("翻译语言（留空关闭）", app.Preferences.TranslationLanguage, (p, v) => p with { TranslationLanguage = v.Trim() });
        Section("录音提醒", Symbol.Important);
        Toggle("应用声音录音建议", app.Preferences.RecordingSuggestions, (p, v) => p with { RecordingSuggestions = v });
        Toggle("声音不活跃提醒", app.Preferences.InactivityReminders, (p, v) => p with { InactivityReminders = v });
        Field("隐藏录音提醒间隔（分钟，0 关闭）", app.Preferences.LongReminderMinutes.ToString(), (p, v) => p with { LongReminderMinutes = Minutes(v) });
        Field("录音时长提醒（分钟，0 关闭）", app.Preferences.MaxDurationMinutes.ToString(), (p, v) => p with { MaxDurationMinutes = Minutes(v) });
        Section("存储与关于", Symbol.Folder);
        Field("本地录音目录（重启后生效）", app.Preferences.RecordingsRoot, (p, v) => p with { RecordingsRoot = v.Trim() });
        var about = new Grid { ColumnSpacing = 14 };
        about.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); about.ColumnDefinitions.Add(new ColumnDefinition());
        about.Children.Add(RecappiTheme.LogoTile(44));
        var version = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        version.Children.Add(new TextBlock { Text = "Recappi Mini", Style = RecappiTheme.Style("RecappiSectionTitle") });
        version.Children.Add(new TextBlock { Text = CurrentVersion.Split('+')[0] + " · Windows 原生桌面版 · WinUI 3", Style = RecappiTheme.Style("RecappiCaption") });
        Grid.SetColumn(version, 1); about.Children.Add(version);
        section.Children.Add(about);
        updateStatus.Style = RecappiTheme.Style("RecappiBodySecondary");
        section.Children.Add(updateStatus);
        var checkUpdate = Ui.Button("检查更新", CheckUpdate, this);
        downloadUpdate = Ui.Button("下载已验证更新", DownloadUpdate, this); downloadUpdate.IsEnabled = false;
        cancelUpdate = Ui.Button("取消下载", () => { download?.Cancel(); return Task.CompletedTask; }, this); cancelUpdate.IsEnabled = false;
        if (this.distribution == DesktopDistribution.Portable)
        {
            section.Children.Add(checkUpdate);
            section.Children.Add(Ui.Row(downloadUpdate, cancelUpdate));
            section.Children.Add(Ui.Button("打开发布页面", () => { Process.Start(new ProcessStartInfo(DesktopUpdates.ReleasesPage.AbsoluteUri) { UseShellExecute = true }); return Task.CompletedTask; }, this));
        }
        else
        {
            checkUpdate.IsEnabled = false;
            updateStatus.Text = this.distribution == DesktopDistribution.Packaged
                ? "当前为 MSIX 安装版，更新由原安装渠道管理。从 Microsoft Store 安装的版本，请在商店中检查更新；测试或组织分发的版本，请使用原渠道提供的新版安装包。"
                : "暂时无法识别此应用的安装方式。请关闭并重新打开设置后重试，或从原安装渠道获取更新。";
            if (this.distribution == DesktopDistribution.Packaged)
                section.Children.Add(Ui.Button("打开 Microsoft Store 更新", () =>
                {
                    Process.Start(new ProcessStartInfo("ms-windows-store://downloadsandupdates") { UseShellExecute = true });
                    return Task.CompletedTask;
                }, this));
        }
        foreach (var page in sections.Values) foreach (var button in page.Children.OfType<Button>()) RecappiTheme.Compact(button);
        navigation.SelectedItem = navigation.MenuItems[0];
        AppWindow.Closing += (_, e) => { if (!Flush()) e.Cancel = true; };
        Closed += (_, _) => { closed = true; timer.Stop(); lifetime.Cancel(); download?.Cancel(); };
    }
    private async Task CheckUpdate()
    {
        if (distribution != DesktopDistribution.Portable || checkingUpdate || download is not null) return;
        checkingUpdate = true; downloadUpdate.IsEnabled = false; release = null;
        updateStatus.Text = "正在检查官方发布…";
        try
        {
            using var updates = createUpdates();
            var runtime = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture == System.Runtime.InteropServices.Architecture.Arm64 ? "win-arm64" : "win-x64";
            var result = await updates.CheckAsync(CurrentVersion, runtime, lifetime.Token);
            if (closed) return;
            release = result.Update;
            updateStatus.Text = release is { } available ? "可用更新：" + available.Version : result.HasCompatibleRelease ? "已是最新版本。" : "暂无适用的发布版本。";
        }
        catch (OperationCanceledException)
        {
            if (!closed) updateStatus.Text = "检查超时，请稍后重试。";
        }
        catch (HttpRequestException error) when (error.StatusCode is System.Net.HttpStatusCode.Forbidden or System.Net.HttpStatusCode.TooManyRequests)
        {
            if (!closed) updateStatus.Text = "官方更新服务暂时拒绝请求或达到访问限额，请稍后重试，或打开发布页面。";
        }
        catch (Exception)
        {
            if (!closed) updateStatus.Text = "无法检查更新，请稍后重试或打开官方发布页面。";
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
            picker.FileTypeChoices.Add("ZIP 更新包", new List<string> { ".zip" });
            WinRT.Interop.InitializeWithWindow.Initialize(picker, WinRT.Interop.WindowNative.GetWindowHandle(this));
            var file = await picker.PickSaveFileAsync();
            if (file is null || closed) return;
            pendingDownload.Token.ThrowIfCancellationRequested();
            using var updates = createUpdates();
            await updates.DownloadAsync(available, file.Path, new Progress<double>(value => { if (!closed) updateStatus.Text = $"正在下载 {value:P0}"; }), pendingDownload.Token);
            if (!closed) updateStatus.Text = "下载完成，完整性校验通过。解压后即可使用新版本。";
        }
        catch (OperationCanceledException) { if (!closed) updateStatus.Text = "下载已取消。"; }
        catch (Exception) { if (!closed) updateStatus.Text = "下载或完整性校验失败，原文件保留，请重试。"; }
        finally { download = null; if (!closed) { downloadUpdate.IsEnabled = release is not null; cancelUpdate.IsEnabled = false; } }
    }
    private void Section(string name, Symbol icon)
    {
        section = new StackPanel { Spacing = 14, Padding = new Thickness(20, 16, 20, 24), Width = 560, HorizontalAlignment = HorizontalAlignment.Center };
        sections[name] = section;
        group = null;
        var item = new NavigationViewItem { Content = name, Tag = name };
        navigation.MenuItems.Add(item);
        var tab = new StackPanel { Spacing = 2 };
        tab.Children.Add(new SymbolIcon(icon) { HorizontalAlignment = HorizontalAlignment.Center, RenderTransform = new Microsoft.UI.Xaml.Media.ScaleTransform { ScaleX = 0.9, ScaleY = 0.9, CenterX = 10, CenterY = 10 } });
        tab.Children.Add(new TextBlock { Text = name, FontSize = 11, HorizontalAlignment = HorizontalAlignment.Center });
        var button = new Button { Content = tab, Style = RecappiTheme.Style("RecappiTabButton") };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, name);
        button.Click += (_, _) => navigation.SelectedItem = item;
        tabStrip.Children.Add(button); tabs.Add((name, button));
    }
    private static int Minutes(string text) => int.TryParse(text, out var value) ? value : throw new ArgumentException("提醒时间请填写整数分钟。");
    private void Edited(Control control, Func<DesktopPreferences, DesktopPreferences> edit) { pending[control] = edit; timer.Stop(); timer.Start(); }
    // Settings rows share one card per section: label on the left, control on the right.
    private void AddRow(string label, FrameworkElement control)
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
        row.Children.Add(new TextBlock { Text = label, Style = RecappiTheme.Style("RecappiBody"), FontSize = 13, LineHeight = 18, VerticalAlignment = VerticalAlignment.Center });
        if (control is ComboBox picker) RecappiTheme.ChipPicker(picker); else if (control is Control input and not ToggleSwitch) RecappiTheme.Compact(input);
        control.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(control, 1); row.Children.Add(control);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(control, label);
        group.Children.Add(row);
    }
    private void Toggle(string label, bool initial, Func<DesktopPreferences, bool, DesktopPreferences> edit)
    {
        var control = new ToggleSwitch { Tag = label, IsOn = initial, OnContent = "", OffContent = "", MinWidth = 0, Margin = new Thickness(0, 0, -12, 0) };
        control.Toggled += (_, _) => Edited(control, p => edit(p, control.IsOn)); AddRow(label, control);
    }
    private void Field(string label, string initial, Func<DesktopPreferences, string, DesktopPreferences> edit)
    {
        var control = new TextBox { Tag = label, Text = initial, Width = 200 };
        control.TextChanging += (_, _) => Edited(control, p => edit(p, control.Text)); AddRow(label, control);
    }
    private void Choice(string label, string initial, string[] values, Func<DesktopPreferences, string, DesktopPreferences> edit)
    {
        var items = values.Select(value => new ComboBoxItem { Tag = value, Content = value switch
        {
            "system" => "跟随系统", "light" => "浅色", "dark" => "深色", "meeting" => "会议", "podcast" => "播客",
            "interview" => "访谈", "casual" => "日常对话", "lecture" => "课程", _ => value
        } }).ToArray();
        var control = new ComboBox { ItemsSource = items, SelectedItem = items.First(x => (string)x.Tag == initial), MinWidth = 140 };
        control.SelectionChanged += (_, _) => { if (control.SelectedItem is ComboBoxItem { Tag: string value }) Edited(control, p => edit(p, value)); }; AddRow(label, control);
    }
    public bool Flush()
    {
        timer.Stop(); if (pending.Count == 0) return true;
        try
        {
            var value = pending.Values.Aggregate(app.Preferences, (current, edit) => edit(current));
            app.SavePreferences(value); pending.Clear(); saved.Text = "已保存"; saved.Visibility = Visibility.Visible;
            retrySave.Visibility = Visibility.Collapsed; return true;
        }
        catch (Exception error)
        {
            saved.Text = "设置未保存：" + error.Message; saved.Visibility = Visibility.Visible;
            retrySave.Visibility = Visibility.Visible; return false;
        }
    }
}
