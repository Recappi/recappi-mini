using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media.Animation;
using Recappi.Core;

namespace Recappi.WinUI;

// Compact recorder pill. Layout and tokens follow the macOS recording panel;
// every control draws its own chrome instead of using default WinUI styles.
internal sealed class RecorderWindow : DesktopWindow
{
    private const double RowHeight = 28;
    private readonly IDesktopHost app;
    private readonly TextBlock state = RecappiTheme.Label("准备录音", "RecappiLabelPrimary");
    private readonly TextBlock elapsed = RecappiTheme.Label("00:00", "RecappiTimer");
    private readonly TextBlock activeSource = RecappiTheme.Label("", "RecappiLabelSecondary");
    private readonly TextBox title = new() { Header = "录音标题", PlaceholderText = "未命名录音" };
    private readonly Button source;
    private readonly TextBlock sourceLabel = RecappiTheme.Label("声音来源", "RecappiLabelPrimary");
    private readonly MenuFlyout sourceMenu = new() { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft };
    private IReadOnlyList<AudioSource> sources = [];
    private AudioSource? selectedSource;
    private readonly ComboBox microphone = new() { Header = "麦克风", DisplayMemberPath = "Label", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly CheckBox includeMicrophone = new() { Content = "录制麦克风" };
    private readonly CheckBox captions = new() { Content = "实时字幕" };
    private readonly DotMatrixMeter waveform = new();
    private readonly DispatcherTimer waveformTimer = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private double systemLevel;
    private double microphoneLevel;
    private readonly StackPanel setup = new() { Spacing = 12 };
    private readonly List<Control> setupControls = [];
    private readonly Grid idleRow = Row();
    private readonly StackPanel activePanel = new() { Spacing = 6 };
    private readonly Grid recordingControls = Row();
    private readonly FrameworkElement recordingDot;
    private readonly Storyboard recordingPulse;
    private readonly Flyout options = new() { ShouldConstrainToRootBounds = false };
    private readonly Flyout recordingMenu = new() { ShouldConstrainToRootBounds = false };
    private readonly Grid donePanel = Row();
    private readonly FontIcon savedIcon = RecappiTheme.Glyph("", 13);
    private readonly TextBlock savedStatus = RecappiTheme.Label("已保存到本机", "RecappiStatusAccent");
    private readonly TextBlock savedDuration = RecappiTheme.Label("", "RecappiDuration");
    private readonly TextBlock savedDetail = RecappiTheme.Label("", "RecappiLabelSecondary");
    private ProcessingEntry? savedProcessing;
    private readonly Button newRecording;
    private bool dismissedDone;
    private readonly TextBlock attention = RecappiTheme.Label("", "RecappiLabelPrimary");
    private readonly Grid attentionActions = Row();
    private readonly Button start;
    private readonly Button stop;
    private readonly Button discard;
    private readonly ToggleButton toggle;
    private readonly ToggleButton idleMicrophone;
    private readonly Button optionsChip;
    private readonly ProgressRing startProgress = new() { Width = 14, Height = 14, IsActive = false, Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.White) };
    private bool busy;
    private bool refreshing;
    private bool closed;
    private long lastSystem;
    private long lastMicrophone;
    private readonly Func<(IReadOnlyList<AudioSource> Sources, IReadOnlyList<MicrophoneDevice> Microphones)> discover;
    public bool IsActive => app.Engine.Snapshot.State is RecordingState.Starting or RecordingState.Recording or RecordingState.Stopping;
    public RecordingState State => app.Engine.Snapshot.State;
    public int SourceCount => sources.Count;
    public int MicrophoneCount => microphone.Items.Count;
    public bool CanStart => !IsActive && !busy && !refreshing && selectedSource is { } selected &&
        (selected.Id != "microphone-only" || includeMicrophone.IsChecked == true) && (includeMicrophone.IsChecked != true || microphone.SelectedItem is MicrophoneDevice);
    public RecorderWindow(IDesktopHost app, Func<(IReadOnlyList<AudioSource> Sources, IReadOnlyList<MicrophoneDevice> Microphones)>? discover = null) : base("Recappi Mini", 370, 94)
    {
        RecappiTheme.Ensure();
        this.app = app;
        this.discover = discover ?? (() => (AudioDevices.ListSources(), AudioDevices.ListMicrophones()));
        // macOS panel metrics: 344pt wide, 6pt padding, 28pt controls, 6pt gaps.
        Body.Padding = new Thickness(5, 6, 6, 6); Body.Spacing = 6;
        CompactChrome("移动录音面板", 300, "RecappiSurfacePanel", minimumHeight: 40, pill: true);
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter compact) compact.PreferredMinimumWidth = (int)(300 * Scale);
        Error.Style = RecappiTheme.Style("RecappiError"); Error.FontSize = 11; Error.IsTextSelectionEnabled = false; Error.Margin = new Thickness(2, 0, 2, 0);
        PlaceAtTopRight();
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter) { presenter.IsAlwaysOnTop = true; presenter.IsMaximizable = false; }

        // Options popover laid out like macOS: accent section headers, label rows with
        // controls on the right, and an "open settings" footer below a divider.
        setup.Spacing = 0; setup.Padding = new Thickness(14, 12, 14, 6);
        var includeSwitch = OptionSwitch(includeMicrophone); var captionSwitch = OptionSwitch(captions);
        var originalLanguage = LanguagePicker(app.Preferences.CaptionLanguage, false);
        var translationLanguage = LanguagePicker(app.Preferences.TranslationLanguage, true);
        void LanguageChanged() => app.SetRecordingLanguage(Code(originalLanguage), Code(translationLanguage));
        originalLanguage.SelectionChanged += (_, _) => LanguageChanged(); translationLanguage.SelectionChanged += (_, _) => LanguageChanged();
        RecappiTheme.ChipPicker(microphone);
        microphone.Header = null; microphone.Width = 170; microphone.HorizontalAlignment = HorizontalAlignment.Right;
        OptionSection("录音");
        OptionRow("麦克风", null, microphone);
        OptionRow("录制麦克风", "把麦克风混入录音", includeSwitch);
        OptionSection("实时字幕");
        OptionRow("开启", "录音时显示浮动字幕条", captionSwitch);
        OptionRow("字幕语言", null, originalLanguage);
        OptionRow("翻译", null, translationLanguage);
        var refresh = Ui.Button("刷新声音设备", RefreshDevices, this);
        refresh.Style = RecappiTheme.Style("RecappiQuietButton");
        RecappiTheme.Bind(refresh, "RecappiAccent", brush => refresh.Foreground = brush);
        refresh.HorizontalAlignment = HorizontalAlignment.Left; refresh.Margin = new Thickness(-6, 4, 0, 0);
        setup.Children.Add(refresh); setupControls.Add(refresh);
        var divider = new Border { Height = 1, Margin = new Thickness(0, 6, 0, 4) };
        RecappiTheme.Bind(divider, "RecappiBorderSubtle", brush => divider.Background = brush);
        setup.Children.Add(divider);
        setup.Children.Add(OptionLink("", "打开设置…", () => { options.Hide(); app.ShowSettings(); return Task.CompletedTask; }));
        setup.Children.Add(OptionLink("", "账号", () => { options.Hide(); app.ShowAccount(); return Task.CompletedTask; }));
        setup.Children.Add(OptionLink("", "退出 Recappi", app.Quit));
        options.Content = new ScrollViewer { Content = setup, MaxHeight = 520, Width = 320 };
        options.FlyoutPresenterStyle = Popover(0, 12);

        // Idle: brand tile · source · microphone · options · hide · record.
        var library = Action("录音库", RecappiTheme.LogoTile(RowHeight), "RecappiIconButton", () => { app.ShowLibrary(); Hide(); return Task.CompletedTask; }, "打开录音库");
        library.Width = library.Height = RowHeight; library.Background = null;
        var sourceContent = new Grid { ColumnSpacing = 6 };
        sourceContent.ColumnDefinitions.Add(new ColumnDefinition()); sourceContent.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var chevron = RecappiTheme.Glyph("\uEC8F", 11); chevron.Style = RecappiTheme.Style("RecappiIconNeutral");
        Grid.SetColumn(chevron, 1); sourceContent.Children.Add(sourceLabel); sourceContent.Children.Add(chevron);
        source = Action("声音来源", sourceContent, "RecappiChipButton", () => Task.CompletedTask);
        source.HorizontalAlignment = HorizontalAlignment.Stretch; source.HorizontalContentAlignment = HorizontalAlignment.Stretch; source.Padding = new Thickness(10, 0, 9, 0);
        source.Flyout = sourceMenu;
        idleMicrophone = Toggle("录制麦克风", () => { includeMicrophone.IsChecked = idleMicrophone!.IsChecked == true; Render(); return Task.CompletedTask; });
        var optionsContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        var optionsChevron = RecappiTheme.Glyph("\uE70D", 9); optionsChevron.Style = RecappiTheme.Style("RecappiIconNeutral");
        optionsContent.Children.Add(RecappiTheme.Glyph("\uE9E9", 12));
        optionsContent.Children.Add(new TextBlock { Text = "选项", FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        optionsContent.Children.Add(optionsChevron);
        optionsChip = Action("录音选项", optionsContent, "RecappiChipButton", () => Task.CompletedTask, "录音选项：麦克风、字幕、标题与语言");
        optionsChip.Padding = new Thickness(9, 0, 8, 0); optionsChip.Flyout = options;
        var hideIdle = Action("隐藏", RecappiTheme.Glyph("", 11), "RecappiIconButton", () => { options.Hide(); Hide(); return Task.CompletedTask; }, "隐藏面板");
        var startContent = new Grid();
        startContent.Children.Add(new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 10, Height = 10, Fill = startProgress.Foreground });
        startContent.Children.Add(startProgress);
        start = Action("开始录音", startContent, "RecappiRecordButton", () => Guard(Start));
        Place(idleRow, (library, false), (source, true), (optionsChip, false), (hideIdle, false), (start, false));
        Body.Children.Add(idleRow);

        // Saved: status · duration · view · new · hide, with an optional detail line.
        newRecording = Action("关闭", new TextBlock { Text = "关闭" }, "RecappiQuietButton", () => { dismissedDone = true; title.Text = ""; Render(); return Task.CompletedTask; }, "关闭这条提示，录音已保存");
        var viewContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5 };
        viewContent.Children.Add(new TextBlock { Text = "查看", VerticalAlignment = VerticalAlignment.Center });
        viewContent.Children.Add(RecappiTheme.Glyph("", 9));
        var view = Action("查看录音", viewContent, "RecappiAccentChipButton", () => { if (app.Engine.Snapshot.Recording is { } recording) { app.ShowRecording(recording.Id); Hide(); } return Task.CompletedTask; });
        var hideDone = Action("隐藏", RecappiTheme.Glyph("", 10), "RecappiIconButton", () => { Hide(); return Task.CompletedTask; }, "隐藏面板");
        savedIcon.Margin = new Thickness(2, 0, 0, 0); savedIcon.VerticalAlignment = VerticalAlignment.Center;
        savedStatus.TextTrimming = TextTrimming.CharacterEllipsis; savedStatus.FontSize = 11.5; savedStatus.FontWeight = Microsoft.UI.Text.FontWeights.Medium;
        savedDuration.FontSize = 11;
        view.Height = 22; view.FontSize = 11; newRecording.Height = 22; newRecording.FontSize = 10.5;
        Place(donePanel, (savedIcon, false), (savedStatus, false), (Separator(), false), (savedDuration, false), (new Border(), true), (view, false), (newRecording, false));
        _ = hideDone;
        Body.Children.Add(donePanel);
        savedDetail.TextWrapping = TextWrapping.Wrap; savedDetail.Margin = new Thickness(2, 0, 2, 0); savedDetail.FontSize = 11;
        savedDetail.Visibility = Visibility.Collapsed;
        Body.Children.Add(savedDetail);

        // Recording: live header above waveform · microphone · more · stop.
        var dot = new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 6, Height = 6, Style = RecappiTheme.Style("RecappiDotAccent"), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(2, 0, 0, 0) };
        recordingDot = dot; recordingPulse = RecappiTheme.Pulse(dot);
        var captionButton = Action("字幕", RecappiTheme.Glyph("\uED1E", 12), "RecappiIconButton", () => { app.ShowCaptions(); return Task.CompletedTask; }, "显示实时字幕");
        var hideRecording = Action("隐藏", RecappiTheme.Glyph("", 10), "RecappiIconButton", () => { Hide(); return Task.CompletedTask; }, "隐藏面板 · 录音在后台继续");
        // Square hit and hover areas centred on the glyph; the larger target overhangs the 18pt header.
        foreach (var small in new[] { captionButton, hideRecording }) { small.Width = small.Height = 22; small.Margin = new Thickness(0, -2, 0, -2); small.CornerRadius = new CornerRadius(6); }
        ((FontIcon)captionButton.Content).FontSize = 10.5; ((FontIcon)hideRecording.Content).FontSize = 9;
        elapsed.FontSize = 11; elapsed.FontWeight = Microsoft.UI.Text.FontWeights.Medium;
        state.FontSize = 11; state.FontWeight = Microsoft.UI.Text.FontWeights.Medium; activeSource.FontSize = 11;
        var header = Row(); header.Height = 18; header.MinHeight = 18;
        Place(header, (dot, false), (elapsed, false), (state, false), (Separator(), false), (activeSource, true), (captionButton, false), (hideRecording, false));
        activePanel.Children.Add(header);
        toggle = Toggle("切换麦克风", () => Guard(async () => await app.Engine.SetMicrophoneEnabledAsync(!app.Engine.MicrophoneEnabled)));
        discard = Menu("丢弃录音", "", () => Guard(async () =>
        {
            recordingMenu.Hide();
            var target = app.Engine.Snapshot.Recording?.Id;
            if (target is null || !await Confirm("丢弃录音", "删除当前录音的本地音频和字幕？此操作无法撤销。", "丢弃")) return;
            if (app.Engine.Snapshot.Recording?.Id != target || app.Engine.Snapshot.State != RecordingState.Recording)
                throw new InvalidOperationException("录音状态已变化，未执行丢弃。");
            await app.StopCaptions(true);
            await app.Engine.DiscardAsync(target);
        }));
        ((FontIcon)((StackPanel)discard.Content).Children[0]).Style = RecappiTheme.Style("RecappiIconDanger");
        var moreMenu = new StackPanel { Spacing = 1, MinWidth = 150 };
        moreMenu.Children.Add(Menu("录音库", "", () => { recordingMenu.Hide(); app.ShowLibrary(); return Task.CompletedTask; }));
        moreMenu.Children.Add(discard);
        moreMenu.Children.Add(Menu("退出", "", () => { recordingMenu.Hide(); return app.Quit(); }));
        recordingMenu.Content = moreMenu; recordingMenu.FlyoutPresenterStyle = Popover(5, 10);
        var moreButton = Action("更多操作", RecappiTheme.Glyph("", 14), "RecappiIconButton", () => Task.CompletedTask); moreButton.Flyout = recordingMenu;
        var stopContent = new Border { Width = 9, Height = 9, CornerRadius = new CornerRadius(2), Background = startProgress.Foreground };
        stop = Action("停止并保存", stopContent, "RecappiRecordButton", () => Guard(app.StopRecording));
        waveform.Margin = new Thickness(4, 0, 0, 0);
        Place(recordingControls, (waveform, true), (toggle, false), (moreButton, false), (stop, false));
        activePanel.Children.Add(recordingControls);

        // Reminders replace the control row until the user chooses.
        var attentionIcon = RecappiTheme.Glyph("", 12); attentionIcon.Style = RecappiTheme.Style("RecappiIconAccent"); attentionIcon.Width = 18;
        attention.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; attention.FontSize = 11.5;
        var keep = Action("继续录音", new TextBlock { Text = "继续" }, "RecappiChipButton", () => { ClearAttention(); return Task.CompletedTask; });
        keep.Height = 24; keep.Padding = new Thickness(8, 0, 8, 0); keep.FontSize = 11;
        var stopNow = Action("停止并保存", new TextBlock { Text = "停止" }, "RecappiDangerChipButton", () => Guard(app.StopRecording)); stopNow.FontSize = 11; stopNow.Padding = new Thickness(8, 0, 8, 0);
        Place(attentionActions, (attentionIcon, false), (attention, true), (keep, false), (stopNow, false));
        attentionActions.Visibility = Visibility.Collapsed;
        activePanel.Children.Add(attentionActions);
        Body.Children.Add(activePanel);

        waveformTimer.Tick += (_, _) => waveform.Push(Math.Max(systemLevel, app.Engine.MicrophoneEnabled ? microphoneLevel : 0));
        microphone.SelectionChanged += (_, _) => Render();
        includeMicrophone.Checked += (_, _) => Render(); includeMicrophone.Unchecked += (_, _) => Render();
        ApplyPreferences();
        app.Engine.Changed += EngineChanged;
        app.Engine.Level += EngineLevel;
        app.Processing.Changed += ProcessingChanged;
        app.Account.Changed += AccountChanged;
        Closed += (_, _) =>
        {
            closed = true;
            waveformTimer.Stop();
            app.Engine.Changed -= EngineChanged;
            app.Engine.Level -= EngineLevel;
            app.Processing.Changed -= ProcessingChanged;
            app.Account.Changed -= AccountChanged;
        };
        Render();
    }
    private static Grid Row() => new() { ColumnSpacing = 6, MinHeight = RowHeight };
    // Background hosts that own windows or audio sessions but are never what people mean to record.
    private static readonly HashSet<string> HiddenSourceApps = new(StringComparer.OrdinalIgnoreCase)
    {
        "Windows Explorer", "Host Process for Windows Services", "Application Frame Host", "CredentialUIBroker",
        "Microsoft® Windows® Operating System", "Windows Shell Experience Host", "Windows Input Experience", "Desktop Window Manager"
    };
    private static string AppName(AudioSource source)
    {
        var label = source.Label;
        var pid = label.LastIndexOf(" (PID ", StringComparison.Ordinal);
        return pid > 0 ? label[..pid] : label;
    }
    private static IconElement AppIcon(int processId)
    {
        var icon = new ImageIcon { Width = 16, Height = 16 };
        _ = LoadAppIcon(icon, processId);
        return icon;
    }
    private static async Task LoadAppIcon(ImageIcon icon, int processId)
    {
        try
        {
            var path = ProcessPath(processId);
            if (path is null) return;
            var file = await Windows.Storage.StorageFile.GetFileFromPathAsync(path);
            using var thumbnail = await file.GetThumbnailAsync(Windows.Storage.FileProperties.ThumbnailMode.SingleItem, 32);
            var image = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage();
            await image.SetSourceAsync(thumbnail);
            icon.Source = image;
        }
        catch (Exception) { /* Icons are decoration; protected processes keep the plain row. */ }
    }
    private static string? ProcessPath(int processId)
    {
        var handle = OpenProcess(0x1000, false, processId);
        if (handle == 0) return null;
        try
        {
            var buffer = new System.Text.StringBuilder(1024); var size = buffer.Capacity;
            return QueryFullProcessImageName(handle, 0, buffer, ref size) ? buffer.ToString() : null;
        }
        finally { CloseHandle(handle); }
    }
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern nint OpenProcess(uint access, bool inherit, int processId);
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)] private static extern bool QueryFullProcessImageName(nint process, int flags, System.Text.StringBuilder name, ref int size);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern bool CloseHandle(nint handle);
    internal static readonly (string Code, string Name)[] Languages =
        [("en", "英语"), ("zh", "中文"), ("ja", "日语"), ("ko", "韩语"), ("es", "西班牙语"), ("fr", "法语"), ("de", "德语"), ("pt", "葡萄牙语"), ("ru", "俄语"), ("it", "意大利语")];
    private static ComboBox LanguagePicker(string current, bool allowOff)
    {
        var items = new List<ComboBoxItem>();
        if (allowOff) items.Add(new ComboBoxItem { Content = "关闭", Tag = "" });
        items.AddRange(Languages.Select(x => new ComboBoxItem { Content = x.Name, Tag = x.Code }));
        // Keep a custom code chosen earlier in Settings.
        if (!string.IsNullOrEmpty(current) && items.All(x => (string)x.Tag != current)) items.Add(new ComboBoxItem { Content = current, Tag = current });
        var picker = new ComboBox { ItemsSource = items, SelectedItem = items.FirstOrDefault(x => (string)x.Tag == current) ?? items[0], Width = 130 };
        RecappiTheme.ChipPicker(picker);
        return picker;
    }
    private static string Code(ComboBox picker) => (picker.SelectedItem as ComboBoxItem)?.Tag as string ?? "";
    private void OptionSection(string text)
    {
        var header = new TextBlock { Text = text, FontSize = 11, FontWeight = Microsoft.UI.Text.FontWeights.Bold, CharacterSpacing = 80, Style = RecappiTheme.Style("RecappiStatusAccent"),
            Margin = new Thickness(0, setup.Children.Count == 0 ? 0 : 10, 0, 4) };
        setup.Children.Add(header);
    }
    private void OptionRow(string label, string? detail, FrameworkElement control)
    {
        var row = new Grid { ColumnSpacing = 12, MinHeight = 32, Margin = new Thickness(0, 2, 0, 2) };
        row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var text = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = label, Style = RecappiTheme.Style("RecappiBody"), FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.Medium });
        if (detail is not null) text.Children.Add(new TextBlock { Text = detail, Style = RecappiTheme.Style("RecappiCaption"), FontSize = 11.5, TextWrapping = TextWrapping.Wrap });
        row.Children.Add(text);
        control.VerticalAlignment = VerticalAlignment.Center; Grid.SetColumn(control, 1); row.Children.Add(control);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(control, label);
        if (control is Control input) setupControls.Add(input);
        setup.Children.Add(row);
    }
    // The CheckBox stays the preference model; the switch is its macOS-style view.
    private static ToggleSwitch OptionSwitch(CheckBox model)
    {
        var view = new ToggleSwitch { IsOn = model.IsChecked == true, OnContent = "", OffContent = "", MinWidth = 0, Margin = new Thickness(0, 0, -12, 0) };
        view.Toggled += (_, _) => { if (model.IsChecked != view.IsOn) model.IsChecked = view.IsOn; };
        model.Checked += (_, _) => view.IsOn = true; model.Unchecked += (_, _) => view.IsOn = false;
        return view;
    }
    private Button OptionLink(string glyph, string text, Func<Task> action)
    {
        var content = new Grid { ColumnSpacing = 8 };
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); content.ColumnDefinitions.Add(new ColumnDefinition()); content.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var icon = RecappiTheme.Glyph(glyph, 12); icon.Style = RecappiTheme.Style("RecappiIconNeutral");
        var label = new TextBlock { Text = text, FontSize = 12, FontWeight = Microsoft.UI.Text.FontWeights.Medium, VerticalAlignment = VerticalAlignment.Center };
        var arrow = RecappiTheme.Glyph("\uE8A7", 9); arrow.Style = RecappiTheme.Style("RecappiIconNeutral"); arrow.Opacity = 0.6;
        content.Children.Add(icon); Grid.SetColumn(label, 1); content.Children.Add(label); Grid.SetColumn(arrow, 2); content.Children.Add(arrow);
        var button = Action(text, content, "RecappiMenuButton", action);
        button.HorizontalContentAlignment = HorizontalAlignment.Stretch; button.Height = 28; button.Margin = new Thickness(-8, 0, -8, 0); button.Foreground = null;
        RecappiTheme.Bind(button, "RecappiTextSecondary", brush => button.Foreground = brush);
        return button;
    }
    private static void Place(Grid row, params (FrameworkElement Element, bool Fill)[] items)
    {
        for (var i = 0; i < items.Length; i++)
        {
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = items[i].Fill ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
            items[i].Element.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(items[i].Element, i); row.Children.Add(items[i].Element);
        }
    }
    private static TextBlock Separator() => RecappiTheme.Label("·", "RecappiLabelTertiary");
    private Button Action(string name, object content, string style, Func<Task> action, string? tip = null)
    {
        var button = new Button { Content = content, Style = RecappiTheme.Style(style) };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, name);
        ToolTipService.SetToolTip(button, tip ?? name);
        var running = false;
        button.Click += async (_, _) =>
        {
            if (running) return;
            running = true;
            try { await Run(action); }
            finally { running = false; }
        };
        return button;
    }
    // Popovers own their inset and corners (macOS menus: 5pt inset, 10pt corners; popover 12pt).
    private static Style Popover(double padding, double radius)
    {
        var style = new Style(typeof(FlyoutPresenter));
        style.Setters.Add(new Setter(Control.PaddingProperty, new Thickness(padding)));
        style.Setters.Add(new Setter(Control.CornerRadiusProperty, new CornerRadius(radius)));
        style.Setters.Add(new Setter(FrameworkElement.MinWidthProperty, 0d));
        return style;
    }
    private Button Menu(string label, string glyph, Func<Task> action)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var icon = RecappiTheme.Glyph(glyph, 13); icon.Style = RecappiTheme.Style("RecappiIconNeutral");
        content.Children.Add(icon); content.Children.Add(new TextBlock { Text = label, FontSize = 13, VerticalAlignment = VerticalAlignment.Center });
        var button = Action(label, content, "RecappiMenuButton", action, label);
        button.Height = 28; button.Padding = new Thickness(8, 0, 8, 0); button.CornerRadius = new CornerRadius(5);
        return button;
    }
    private ToggleButton Toggle(string name, Func<Task> action)
    {
        var button = new ToggleButton { Content = RecappiTheme.Glyph("", 13), Style = RecappiTheme.Style("RecappiToggleButton") };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, name);
        button.Click += async (_, _) => await Run(action);
        return button;
    }
    private void ProcessingChanged(ProcessingEntry entry) => UiDispatcher.TryEnqueue(() =>
    {
        if (closed || entry.LocalId != app.Engine.Snapshot.Recording?.Id ||
            entry.Partition != app.Account.Snapshot.Account?.Partition) return;
        savedProcessing = entry;
        Render();
    });
    private void AccountChanged(AccountSnapshot _) => UiDispatcher.TryEnqueue(() =>
    {
        if (closed) return;
        savedProcessing = CurrentProcessing();
        Render();
    });
    private ProcessingEntry? CurrentProcessing() => app.Engine.Snapshot.Recording is { } recording &&
        app.Account.Snapshot.Account is { } account
        ? app.Processing.List(account.Partition).FirstOrDefault(entry => entry.LocalId == recording.Id)
        : null;
    private void EngineChanged(RecordingSnapshot value) => UiDispatcher.TryEnqueue(() =>
    {
        if (closed) return;
        if (value.State == RecordingState.Done && savedProcessing?.LocalId != value.Recording?.Id)
            savedProcessing = CurrentProcessing();
        SetError(value.Error ?? ""); Render();
    });
    private void EngineLevel(AudioLevel value)
    {
            ref var previous = ref (value.Input == "system" ? ref lastSystem : ref lastMicrophone);
            var now = Environment.TickCount64;
            if (now - previous < 100 && !(value.Input == "microphone" && !app.Engine.MicrophoneEnabled)) return;
            previous = now;
            UiDispatcher.TryEnqueue(() =>
            {
                if (closed) return;
                var level = !IsActive || (value.Input == "microphone" && !app.Engine.MicrophoneEnabled) ? 0 : Math.Clamp((value.RmsDb + 60) / 60, 0, 1);
                if (value.Input == "system") systemLevel = level; else microphoneLevel = level;
            });
    }
    public void ApplyPreferences()
    {
        if (IsActive) return;
        includeMicrophone.IsChecked = app.Preferences.IncludeMicrophone;
        captions.IsChecked = app.Preferences.CaptionsEnabled;
    }
    public async Task RefreshDevices()
    {
        if (IsActive || refreshing) return;
        refreshing = true; SetSetupEnabled(false);
        try
        {
            var sourceId = selectedSource?.Id ?? app.Preferences.SourceId;
            var micId = (microphone.SelectedItem as MicrophoneDevice)?.Id ?? app.Preferences.MicrophoneId;
            var devices = await Task.Run(discover);
            if (closed) return;
            sources = devices.Item1.Select(item => item.Id == "system" ? item with { Label = "系统声音 · 所有应用" } : item).Concat([new AudioSource("microphone-only", "仅麦克风")]).ToArray();
            microphone.ItemsSource = devices.Item2;
            SelectSource(sources.FirstOrDefault(x => x.Id == (sourceId ?? "system")));
            microphone.SelectedItem = micId is null ? devices.Item2.FirstOrDefault(x => x.IsDefault) ?? devices.Item2.FirstOrDefault() : devices.Item2.FirstOrDefault(x => x.Id == micId);
        }
        finally { refreshing = false; Render(); }
    }
    private void SelectSource(AudioSource? value)
    {
        selectedSource = value;
        sourceMenu.Items.Clear();
        var seen = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var apps = sources.Where(x => x.ProcessId is not null && !HiddenSourceApps.Contains(AppName(x)) || x == value).OrderBy(x => AppName(x), StringComparer.CurrentCultureIgnoreCase).ToList();
        foreach (var item in sources.Where(x => x.ProcessId is null && x.Id != "microphone-only").Concat(apps).Concat(sources.Where(x => x.Id == "microphone-only")).Distinct())
        {
            var name = AppName(item);
            // Same app in several processes (e.g. two Slack windows): number the extras.
            var count = seen[name] = seen.GetValueOrDefault(name) + 1;
            var entry = new MenuFlyoutItem { Text = count > 1 ? $"{name}（{count}）" : name, KeyboardAcceleratorTextOverride = item == value ? "✓" : "" };
            entry.Icon = item.ProcessId is { } pid ? AppIcon(pid) : new FontIcon { Glyph = item.Id == "microphone-only" ? "\uE720" : "\uE767" };
            ToolTipService.SetToolTip(entry, item.ProcessId is { } id ? $"{name} · 进程 {id}" : name);
            entry.Click += (_, _) => { SelectSource(item); Render(); };
            sourceMenu.Items.Add(entry);
            if (item.ProcessId is null && item.Id != "microphone-only" && apps.Count > 0) sourceMenu.Items.Add(new MenuFlyoutSeparator());
        }
        sourceMenu.Items.Add(new MenuFlyoutSeparator());
        var refresh = new MenuFlyoutItem { Text = "刷新声音设备", Icon = new FontIcon { Glyph = "" } };
        refresh.Click += async (_, _) => await Run(RefreshDevices);
        sourceMenu.Items.Add(refresh);
        sourceLabel.Text = value is null ? "选择声音来源" : AppName(value);
        ToolTipService.SetToolTip(source, value is null ? "选择声音来源" : "录制 " + AppName(value) + "，点击更换来源");
    }
    private async Task Start()
    {
        if (selectedSource is not AudioSource selected) throw new InvalidOperationException("请选择可用的声音来源。");
        var withMic = includeMicrophone.IsChecked == true;
        var mic = microphone.SelectedItem as MicrophoneDevice;
        if (withMic && mic is null) throw new InvalidOperationException("请选择可用的麦克风。");
        if (selected.Id == "microphone-only" && !withMic) throw new InvalidOperationException("仅麦克风模式需要开启麦克风。");
        var preferences = app.Preferences with { SourceId = selected.Id, MicrophoneId = mic?.Id, IncludeMicrophone = withMic, CaptionsEnabled = captions.IsChecked == true };
        dismissedDone = false;
        await app.StartRecording(new RecordingOptions(string.IsNullOrWhiteSpace(title.Text) ? "未命名录音" : title.Text, selected.Id != "microphone-only", withMic,
            selected.ProcessId is { } pid ? (uint)pid : null, mic?.Id, preferences.Processing), preferences);
    }
    private async Task Guard(Func<Task> action)
    {
        if (busy) return;
        busy = true; Render();
        try { await action(); }
        finally { busy = false; Render(); }
    }
    private void Render()
    {
        if (closed) return;
        var snapshot = app.Engine.Snapshot;
        var recording = snapshot.State == RecordingState.Recording;
        state.Text = snapshot.State switch { RecordingState.Starting => "启动中…", RecordingState.Recording => "录音中", RecordingState.Stopping => "保存中…", RecordingState.Done => "已保存到本地", RecordingState.Error => "录音失败", _ => "准备录音" };
        var duration = TimeSpan.FromMilliseconds(snapshot.Recording?.DurationMs ?? 0);
        elapsed.Text = duration.ToString(duration.TotalHours >= 1 ? @"h\:mm\:ss" : @"mm\:ss");
        elapsed.Visibility = recording ? Visibility.Visible : Visibility.Collapsed;
        state.Visibility = recording ? Visibility.Collapsed : Visibility.Visible;
        // Source only, as on macOS; the microphone toggle already shows its state.
        activeSource.Text = selectedSource?.Label ?? "";
        ToolTipService.SetToolTip(activeSource, activeSource.Text);
        if (IsActive) { options.Hide(); sourceMenu.Hide(); }
        var showDone = snapshot.State == RecordingState.Done && !dismissedDone;
        Show(idleRow, !IsActive && !showDone);
        Show(donePanel, showDone);
        RenderSavedState(snapshot, showDone);
        Show(activePanel, IsActive);
        if (IsActive && waveformTimer.IsEnabled == false) { waveform.Clear(); waveformTimer.Start(); recordingPulse.Begin(); }
        else if (!IsActive && waveformTimer.IsEnabled) { waveformTimer.Stop(); recordingPulse.Stop(); }
        recordingDot.Opacity = recording ? 1 : 0.45;
        SetSetupEnabled(!IsActive && !busy && !refreshing);
        source.IsEnabled = !IsActive && !busy && !refreshing;
        var starting = busy && !IsActive && snapshot.State != RecordingState.Done;
        startProgress.IsActive = starting;
        ((UIElement)((Grid)start.Content).Children[0]).Visibility = starting ? Visibility.Collapsed : Visibility.Visible;
        start.IsEnabled = CanStart;
        idleMicrophone.IsEnabled = !busy && !refreshing && !IsActive;
        idleMicrophone.IsChecked = includeMicrophone.IsChecked == true;
        SetMicrophoneGlyph(idleMicrophone, includeMicrophone.IsChecked == true, "关闭麦克风录制", "开启麦克风录制");
        foreach (var button in new Control[] { stop, discard, toggle })
        { button.Visibility = IsActive ? Visibility.Visible : Visibility.Collapsed; button.IsEnabled = !busy && recording; }
        toggle.IsChecked = app.Engine.MicrophoneEnabled;
        SetMicrophoneGlyph(toggle, app.Engine.MicrophoneEnabled, "关闭麦克风", "开启麦克风");
        if (!IsActive) { systemLevel = 0; microphoneLevel = 0; ClearAttention(); }
    }
    private static void SetMicrophoneGlyph(ToggleButton button, bool enabled, string onLabel, string offLabel)
    {
        ((FontIcon)button.Content).Glyph = enabled ? "" : "";
        ToolTipService.SetToolTip(button, enabled ? onLabel : offLabel);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(button, enabled ? onLabel : offLabel);
    }
    private static void Show(UIElement element, bool visible)
    {
        var next = visible ? Visibility.Visible : Visibility.Collapsed;
        if (element.Visibility == next) return;
        element.Visibility = next;
        if (visible) RecappiTheme.FadeIn(element);
    }
    private void RenderSavedState(RecordingSnapshot snapshot, bool visible)
    {
        savedDetail.Visibility = Visibility.Collapsed;
        if (!visible || snapshot.Recording is not { } recording) return;
        var duration = TimeSpan.FromMilliseconds(recording.DurationMs);
        savedDuration.Text = duration.ToString(duration.TotalHours >= 1 ? @"h\:mm\:ss" : @"mm\:ss");
        var entry = savedProcessing;
        if (entry?.LocalId != recording.Id || entry.Partition != app.Account.Snapshot.Account?.Partition) entry = null;
        savedStatus.Text = entry?.Stage switch
        {
            ProcessingStage.Creating => "正在准备上传",
            ProcessingStage.Uploading => "正在上传",
            ProcessingStage.CompletingUpload => "正在确认上传",
            ProcessingStage.Synced => "已同步到云端",
            ProcessingStage.SubmittingTranscription => "正在提交转写",
            ProcessingStage.Queued => "转写排队中",
            ProcessingStage.Transcribing => "正在转写",
            ProcessingStage.Completed => "转写已完成",
            ProcessingStage.Failed => "云端处理失败",
            ProcessingStage.Paused => "云端处理已暂停",
            ProcessingStage.NeedsReconciliation => "需要核对云端状态",
            _ => "已保存到本机"
        };
        var (glyph, tone) = entry?.Stage switch
        {
            ProcessingStage.Failed or ProcessingStage.Paused or ProcessingStage.NeedsReconciliation => ("", "Warning"),
            ProcessingStage.Creating or ProcessingStage.Uploading or ProcessingStage.CompletingUpload => ("", "Neutral"),
            ProcessingStage.SubmittingTranscription or ProcessingStage.Queued or ProcessingStage.Transcribing => ("\uE823", "Neutral"),
            _ => ("\uEC61", "Accent")
        };
        savedIcon.Glyph = glyph;
        savedIcon.Style = RecappiTheme.Style("RecappiIcon" + tone);
        savedStatus.Style = RecappiTheme.Style("RecappiStatus" + tone);
        savedDetail.Text = entry?.Stage switch
        {
            ProcessingStage.Failed or ProcessingStage.Paused or ProcessingStage.NeedsReconciliation => "本机音频已保留。打开录音查看状态并继续处理。",
            ProcessingStage.Creating or ProcessingStage.Uploading or ProcessingStage.CompletingUpload or
            ProcessingStage.SubmittingTranscription or ProcessingStage.Queued or ProcessingStage.Transcribing => "本机音频已保存，云端在后台处理；可以继续新录音。",
            _ => ""
        };
        savedDetail.Visibility = savedDetail.Text.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
    }
    private void SetSetupEnabled(bool enabled)
    {
        foreach (var control in setupControls) control.IsEnabled = enabled;
    }
    private void ClearAttention()
    {
        attention.Text = "";
        attentionActions.Visibility = Visibility.Collapsed;
        recordingControls.Visibility = Visibility.Visible;
    }
    public void RequestAttention(AttentionAction action)
    {
        if (!IsActive || attention.Text.Length > 0) return;
        attention.Text = action == AttentionAction.DurationLimit ? "已达到时长提醒" : "声音来源似乎已停止";
        ToolTipService.SetToolTip(attention, attention.Text + "。停止保存，还是继续录音？");
        recordingControls.Visibility = Visibility.Collapsed;
        Show(attentionActions, true);
    }
    public async Task SelectSuggestedSource(AudioSource suggested)
    {
        if (IsActive) return;
        await RefreshDevices();
        SelectSource(sources.FirstOrDefault(x => x.Id == suggested.Id)); Render();
    }
}
