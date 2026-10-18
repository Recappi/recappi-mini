using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Recappi.Core;

namespace Recappi.WinUI;

internal sealed class RecorderWindow : DesktopWindow
{
    private readonly IDesktopHost app;
    private readonly TextBlock state = Ui.Text("准备录音", 14);
    private readonly TextBlock elapsed = Ui.Text("00:00:00", 18);
    private readonly TextBlock activeSource = Ui.Text("", 12);
    private readonly TextBox title = new() { Header = "录音标题", PlaceholderText = "未命名录音" };
    private readonly ComboBox source = new() { PlaceholderText = "声音来源", DisplayMemberPath = "Label", Width = 170, MaxWidth = 260 };
    private readonly ComboBox microphone = new() { Header = "麦克风", DisplayMemberPath = "Label", HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly CheckBox includeMicrophone = new() { Content = "录制麦克风" };
    private readonly CheckBox captions = new() { Content = "实时字幕" };
    private readonly ProgressBar systemMeter = new() { Maximum = 100 };
    private readonly ProgressBar microphoneMeter = new() { Maximum = 100 };
    private readonly StackPanel setup = new() { Spacing = 12 };
    private readonly WrapPanel actions = new();
    private readonly WrapPanel idleRow = new();
    private readonly StackPanel activePanel = new() { Spacing = 8 };
    private readonly Flyout options = new() { ShouldConstrainToRootBounds = false };
    private readonly Flyout recordingMenu = new() { ShouldConstrainToRootBounds = false };
    private readonly WrapPanel donePanel = new();
    private readonly TextBlock savedStatus = Ui.Text("已保存到本机", 14);
    private readonly TextBlock savedDuration = Ui.Text("", 12);
    private readonly TextBlock savedDetail = Ui.Text("", 12);
    private ProcessingEntry? savedProcessing;
    private readonly Button newRecording;
    private bool dismissedDone;
    private readonly TextBlock attention = Ui.Text("");
    private readonly WrapPanel attentionActions;
    private readonly Button start;
    private readonly Button stop;
    private readonly Button discard;
    private readonly Button toggle;
    private readonly Button idleMicrophone;
    private bool busy;
    private bool refreshing;
    private bool closed;
    private long lastSystem;
    private long lastMicrophone;
    private readonly Func<(IReadOnlyList<AudioSource> Sources, IReadOnlyList<MicrophoneDevice> Microphones)> discover;
    public bool IsActive => app.Engine.Snapshot.State is RecordingState.Starting or RecordingState.Recording or RecordingState.Stopping;
    public RecordingState State => app.Engine.Snapshot.State;
    public int SourceCount => source.Items.Count;
    public int MicrophoneCount => microphone.Items.Count;
    public bool CanStart => !IsActive && !busy && !refreshing && source.SelectedItem is AudioSource selected &&
        (selected.Id != "microphone-only" || includeMicrophone.IsChecked == true) && (includeMicrophone.IsChecked != true || microphone.SelectedItem is MicrophoneDevice);
    public RecorderWindow(IDesktopHost app, Func<(IReadOnlyList<AudioSource> Sources, IReadOnlyList<MicrophoneDevice> Microphones)>? discover = null) : base("Recappi Mini", 520, 70)
    {
        this.app = app;
        this.discover = discover ?? (() => (AudioDevices.ListSources(), AudioDevices.ListMicrophones()));
        Body.Padding = new Thickness(10); Body.Spacing = 8;
        CompactChrome("移动录音面板", 300);
        PlaceAtTopRight();
        if (AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter presenter) { presenter.IsAlwaysOnTop = true; presenter.IsMaximizable = false; }
        foreach (var control in new UIElement[] { title, microphone, includeMicrophone, captions }) setup.Children.Add(control);
        setup.Children.Add(Ui.Button("刷新声音设备", RefreshDevices, this));
        var originalLanguage = new TextBox { Header = "字幕语言", Text = app.Preferences.CaptionLanguage, MaxLength = 20 };
        var translationLanguage = new TextBox { Header = "翻译语言（留空关闭）", Text = app.Preferences.TranslationLanguage, MaxLength = 20 };
        originalLanguage.TextChanged += (_, _) => app.SetRecordingLanguage(originalLanguage.Text, translationLanguage.Text);
        translationLanguage.TextChanged += (_, _) => app.SetRecordingLanguage(originalLanguage.Text, translationLanguage.Text);
        setup.Children.Add(originalLanguage); setup.Children.Add(translationLanguage);
        setup.Children.Add(Ui.Row(Ui.Button("设置", () => { options.Hide(); app.ShowSettings(); return Task.CompletedTask; }, this),
            Ui.Button("账号", () => { options.Hide(); app.ShowAccount(); return Task.CompletedTask; }, this), Ui.Button("退出", app.Quit, this)));
        options.Content = new ScrollViewer { Content = setup, MaxHeight = 480, Width = 310 };
        start = Ui.Button("开始录音", () => Guard(Start), this);
        stop = Ui.Button("停止并保存", () => Guard(app.StopRecording), this);
        stop.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        discard = Ui.Button("丢弃录音", () => Guard(async () =>
        {
            recordingMenu.Hide();
            var target = app.Engine.Snapshot.Recording?.Id;
            if (target is null || !await Confirm("丢弃录音", "删除当前录音的本地音频和字幕？此操作无法撤销。", "丢弃")) return;
            if (app.Engine.Snapshot.Recording?.Id != target || app.Engine.Snapshot.State != RecordingState.Recording)
                throw new InvalidOperationException("录音状态已变化，未执行丢弃。");
            await app.StopCaptions(true);
            await app.Engine.DiscardAsync(target);
        }), this);
        toggle = Ui.IconButton("切换麦克风", "\uE720", () => Guard(async () => await app.Engine.SetMicrophoneEnabledAsync(!app.Engine.MicrophoneEnabled)), this);
        idleMicrophone = Ui.IconButton("录制麦克风", "\uE720", () => { includeMicrophone.IsChecked = includeMicrophone.IsChecked != true; Render(); return Task.CompletedTask; }, this);
        var optionButton = Ui.IconButton("录音选项", "\uE713", () => Task.CompletedTask, this); optionButton.Flyout = options;
        foreach (var control in new UIElement[] { Ui.IconButton("录音库", "\uE8F1", () => { app.ShowLibrary(); Hide(); return Task.CompletedTask; }, this), source, idleMicrophone, optionButton,
            Ui.IconButton("隐藏", "\uE8A7", () => { options.Hide(); Hide(); return Task.CompletedTask; }, this), start }) idleRow.Children.Add(control);
        Body.Children.Add(idleRow);
        newRecording = Ui.Button("新录音", () => { dismissedDone = true; title.Text = ""; Render(); return Task.CompletedTask; }, this);
        donePanel.Children.Add(savedStatus);
        donePanel.Children.Add(savedDuration);
        donePanel.Children.Add(Ui.Button("查看录音", () => { if (app.Engine.Snapshot.Recording is { } recording) { app.ShowRecording(recording.Id); Hide(); } return Task.CompletedTask; }, this));
        donePanel.Children.Add(newRecording); donePanel.Children.Add(Ui.IconButton("隐藏", "\uE8A7", () => { Hide(); return Task.CompletedTask; }, this));
        Body.Children.Add(donePanel);
        savedDetail.Opacity = 0.7;
        savedDetail.Visibility = Visibility.Collapsed;
        Body.Children.Add(savedDetail);
        var moreMenu = new StackPanel { Spacing = 8 }; moreMenu.Children.Add(discard);
        moreMenu.Children.Add(Ui.Button("字幕", () => { recordingMenu.Hide(); app.ShowCaptions(); return Task.CompletedTask; }, this));
        moreMenu.Children.Add(Ui.Button("录音库", () => { recordingMenu.Hide(); app.ShowLibrary(); return Task.CompletedTask; }, this));
        moreMenu.Children.Add(Ui.Button("退出", () => { recordingMenu.Hide(); return app.Quit(); }, this));
        recordingMenu.Content = moreMenu;
        var moreButton = Ui.IconButton("更多操作", "\uE712", () => Task.CompletedTask, this); moreButton.Flyout = recordingMenu;
        foreach (var button in new[] { toggle, moreButton, stop, Ui.IconButton("隐藏", "\uE8A7", () => { Hide(); return Task.CompletedTask; }, this) }) actions.Children.Add(button);
        var meters = new StackPanel { Spacing = 4, Width = 60, VerticalAlignment = VerticalAlignment.Center };
        systemMeter.Height = 4; microphoneMeter.Height = 4; meters.Children.Add(systemMeter); meters.Children.Add(microphoneMeter);
        state.VerticalAlignment = elapsed.VerticalAlignment = VerticalAlignment.Center;
        elapsed.FontSize = 17;
        elapsed.FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas");
        state.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold;
        var recordingDot = new Microsoft.UI.Xaml.Shapes.Ellipse { Width = 8, Height = 8, Fill = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.IndianRed) };
        activePanel.Children.Add(Ui.Row(recordingDot, state, elapsed, meters, actions));
        activeSource.Opacity = 0.6; activeSource.TextTrimming = TextTrimming.CharacterEllipsis; activeSource.TextWrapping = TextWrapping.NoWrap;
        activePanel.Children.Add(activeSource); Body.Children.Add(activePanel);
        attentionActions = Ui.Row(Ui.Button("继续录音", () => { attention.Text = ""; attention.Visibility = Visibility.Collapsed; attentionActions!.Visibility = Visibility.Collapsed; return Task.CompletedTask; }, this),
            Ui.Button("停止并保存", () => Guard(app.StopRecording), this));
        attentionActions.Visibility = Visibility.Collapsed;
        attention.Visibility = Visibility.Collapsed;
        Body.Children.Add(attention); Body.Children.Add(attentionActions);
        source.SelectionChanged += (_, _) => Render(); microphone.SelectionChanged += (_, _) => Render();
        includeMicrophone.Checked += (_, _) => Render(); includeMicrophone.Unchecked += (_, _) => Render();
        ApplyPreferences();
        app.Engine.Changed += EngineChanged;
        app.Engine.Level += EngineLevel;
        app.Processing.Changed += ProcessingChanged;
        app.Account.Changed += AccountChanged;
        Closed += (_, _) =>
        {
            closed = true;
            app.Engine.Changed -= EngineChanged;
            app.Engine.Level -= EngineLevel;
            app.Processing.Changed -= ProcessingChanged;
            app.Account.Changed -= AccountChanged;
        };
        Render();
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
                var meter = value.Input == "system" ? systemMeter : microphoneMeter;
                meter.Value = !IsActive || (value.Input == "microphone" && !app.Engine.MicrophoneEnabled) ? 0 : Math.Clamp((value.RmsDb + 60) / 60 * 100, 0, 100);
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
            var sourceId = (source.SelectedItem as AudioSource)?.Id ?? app.Preferences.SourceId;
            var micId = (microphone.SelectedItem as MicrophoneDevice)?.Id ?? app.Preferences.MicrophoneId;
            var devices = await Task.Run(discover);
            if (closed) return;
            var sources = devices.Item1.Select(item => item.Id == "system" ? item with { Label = "系统声音 · 所有应用" } : item).Concat([new AudioSource("microphone-only", "仅麦克风")]).ToArray();
            source.ItemsSource = sources; microphone.ItemsSource = devices.Item2;
            source.SelectedItem = sources.FirstOrDefault(x => x.Id == (sourceId ?? "system"));
            microphone.SelectedItem = micId is null ? devices.Item2.FirstOrDefault(x => x.IsDefault) ?? devices.Item2.FirstOrDefault() : devices.Item2.FirstOrDefault(x => x.Id == micId);
        }
        finally { refreshing = false; Render(); }
    }
    private async Task Start()
    {
        if (source.SelectedItem is not AudioSource selected) throw new InvalidOperationException("请选择可用的声音来源。");
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
        state.Text = snapshot.State switch { RecordingState.Starting => "启动中", RecordingState.Recording => "录音中", RecordingState.Stopping => "保存中", RecordingState.Done => "已保存到本地", RecordingState.Error => "录音失败", _ => "准备录音" };
        elapsed.Text = TimeSpan.FromMilliseconds(snapshot.Recording?.DurationMs ?? 0).ToString(@"hh\:mm\:ss");
        activeSource.Text = source.SelectedItem is AudioSource selected ? selected.Label + (app.Engine.MicrophoneEnabled ? " · 麦克风已开启" : " · 麦克风已关闭") : "";
        if (IsActive) options.Hide();
        var showDone = snapshot.State == RecordingState.Done && !dismissedDone;
        idleRow.Visibility = IsActive || showDone ? Visibility.Collapsed : Visibility.Visible;
        donePanel.Visibility = showDone ? Visibility.Visible : Visibility.Collapsed;
        RenderSavedState(snapshot, showDone);
        activePanel.Visibility = IsActive ? Visibility.Visible : Visibility.Collapsed;
        SetSetupEnabled(!IsActive && !busy && !refreshing);
        start.Visibility = IsActive ? Visibility.Collapsed : Visibility.Visible;
        start.IsEnabled = CanStart;
        idleMicrophone.IsEnabled = !busy && !refreshing && !IsActive;
        idleMicrophone.Opacity = includeMicrophone.IsChecked == true ? 1 : 0.5;
        ToolTipService.SetToolTip(idleMicrophone, includeMicrophone.IsChecked == true ? "关闭麦克风录制" : "开启麦克风录制");
        foreach (var button in new[] { stop, discard, toggle })
        { button.Visibility = IsActive ? Visibility.Visible : Visibility.Collapsed; button.IsEnabled = !busy && snapshot.State == RecordingState.Recording; }
        ToolTipService.SetToolTip(toggle, app.Engine.MicrophoneEnabled ? "关闭麦克风" : "开启麦克风");
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(toggle, app.Engine.MicrophoneEnabled ? "关闭麦克风" : "开启麦克风");
        toggle.Opacity = app.Engine.MicrophoneEnabled ? 1 : 0.55;
        if (!IsActive) { systemMeter.Value = 0; microphoneMeter.Value = 0; attention.Text = ""; attention.Visibility = Visibility.Collapsed; attentionActions.Visibility = Visibility.Collapsed; }
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
        foreach (var control in setup.Children.OfType<Control>()) control.IsEnabled = enabled;
    }
    public void RequestAttention(AttentionAction action)
    {
        if (!IsActive || attention.Text.Length > 0) return;
        attention.Text = action == AttentionAction.DurationLimit ? "已达到时长提醒。停止保存，还是继续录音？" : "声音来源似乎已停止。停止保存，还是继续录音？";
        attention.Visibility = Visibility.Visible; attentionActions.Visibility = Visibility.Visible;
    }
    public async Task SelectSuggestedSource(AudioSource suggested)
    {
        if (IsActive) return;
        await RefreshDevices();
        source.SelectedItem = ((IEnumerable<AudioSource>)source.ItemsSource).FirstOrDefault(x => x.Id == suggested.Id);
    }
}
