using System.Collections.Concurrent;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Recappi.Core;

namespace Recappi.WinUI;

public partial class App : Application, IDesktopHost
{
    private readonly CancellationTokenSource lifetime = new();
    private readonly List<DesktopWindow> windows = [];
    private readonly ConcurrentDictionary<LiveCaptions, CaptionArchive> archives = new();
    private readonly Dictionary<LiveCaptions, Task> stopping = [];
    private Mutex? instance;
    private Mutex? installGuard;
    private bool ownsInstance;
    private bool quitting;
    private bool quitPending;
    private bool recovery;
    private DispatcherQueue dispatcher = null!;
    private RecorderWindow recorder = null!;
    private TrayIcon? tray;
    private CaptionWindow? captionWindow;
    private LibraryWindow? library;
    private AccountWindow? accountWindow;
    private SettingsWindow? settingsWindow;
    private OnboardingWindow? onboarding;
    private LiveCaptions? captions;
    private string? captionPartition;
    private CloudAccount? recordingAccount;
    private DesktopPreferences recordingPreferences = new();
    private PreferencesStore preferenceStore = null!;
    private readonly RecordingAttention attention = new();
    private readonly RecordingSuggestion suggestions = new();
    private DispatcherQueueTimer? attentionTimer;
    private DispatcherQueueTimer? suggestionTimer;
    private bool checkingAttention;
    private bool checkingSuggestions;
    private int? recordingSourceProcess;
    private double systemRms;
    private double microphoneRms;
    public RecordingEngine Engine { get; private set; } = null!;
    public LocalRecordingStore Store { get; private set; } = null!;
    public AccountSession Account { get; private set; } = null!;
    public CloudProcessing Processing { get; private set; } = null!;
    public DesktopPreferences Preferences { get; private set; } = new();
    public string ApplicationRoot { get; private set; } = "";
    public string Origin { get; } = Environment.GetEnvironmentVariable("RECAPPI_ORIGIN") ?? "https://recordmeet.ing";
    private static string InstanceName => "RecappiMini.Desktop." + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Environment.UserDomainName + "\\" + Environment.UserName)))[..20];
    public App() { InitializeComponent(); }
    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var startupProbe = StartupProbe.Create();
        dispatcher = DispatcherQueue.GetForCurrentThread();
        instance = new Mutex(true, "Local\\" + InstanceName, out ownsInstance);
        if (!ownsInstance)
        {
            try
            {
                using var pipe = new NamedPipeClientStream(".", InstanceName, PipeDirection.Out, PipeOptions.Asynchronous);
                await pipe.ConnectAsync(2500); await pipe.WriteAsync(new byte[] { 1 });
            }
            catch (Exception error) when (error is IOException or TimeoutException) { }
            instance.Dispose(); Exit(); return;
        }
        try
        {
            installGuard = new Mutex(false, "Local\\RecappiMini.Desktop.InstallGuard");
            try { using var maintenance = Mutex.OpenExisting("Local\\RecappiMini.Desktop.Setup"); throw new InvalidOperationException("安装或卸载正在进行，请稍后启动。"); }
            catch (WaitHandleCannotBeOpenedException) { }
            var root = Environment.GetEnvironmentVariable("RECAPPI_DESKTOP_DATA_DIR");
            var arguments = Environment.GetCommandLineArgs().Skip(1).ToArray();
            if (arguments.Length == 2 && arguments[0] == "--validation-data-dir")
            {
                if (!Path.IsPathFullyQualified(arguments[1])) throw new ArgumentException("验证数据目录必须是绝对路径。");
                root = arguments[1];
            }
            ApplicationRoot = Path.GetDirectoryName(Path.GetFullPath(root ?? LocalRecordingStore.DefaultRoot))!;
            preferenceStore = new PreferencesStore(ApplicationRoot);
            (Preferences, recovery) = preferenceStore.LoadForStartup();
            Store = new LocalRecordingStore(root ?? Preferences.RecordingsRoot);
            try { await Task.Run(Store.RecoverInterruptedRecordings); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            Engine = new RecordingEngine(Store);
            Account = new AccountSession(new AccountStore(Path.Combine(ApplicationRoot, "Account")));
            Processing = new CloudProcessing(Path.Combine(ApplicationRoot, "Processing"), Account.Client);
            recorder = Track(new RecorderWindow(this));
            recorder.AppWindow.Closing += (_, e) => { if (!quitting) { e.Cancel = true; suggestions.SuppressActive(); tray?.ClearNotificationAction(); recorder.Hide(); } };
            Account.Changed += value => dispatcher.TryEnqueue(() =>
            {
                if (value.State is AccountState.SignedOut or AccountState.Expired || (captionPartition is not null && value.Account?.Partition != captionPartition))
                { Processing.CancelAll(); _ = recorder.Run(() => StopCaptions(true)); }
            });
            Engine.Audio += samples => Volatile.Read(ref captions)?.Append(samples);
            Engine.Level += value => { var rms = Math.Pow(10, value.RmsDb / 20); if (value.Input == "system") Volatile.Write(ref systemRms, rms); else Volatile.Write(ref microphoneRms, rms); };
            Engine.Changed += value =>
            {
                if (value.State == RecordingState.Starting && value.Recording is { } recording && Volatile.Read(ref captions) is { } stream)
                    AttachArchive(stream, recording, false);
                dispatcher.TryEnqueue(() =>
                {
                    tray?.Update(recorder.IsActive);
                    if (value.State is RecordingState.Done or RecordingState.Error or RecordingState.Idle) _ = recorder.Run(() => StopCaptions());
                });
            };
            Processing.Changed += entry => dispatcher.TryEnqueue(() =>
            {
                if (entry.Partition != Account.Snapshot.Account?.Partition) return;
                if (entry.Stage is ProcessingStage.Completed or ProcessingStage.Synced) tray?.Notify("云端处理完成", entry.Title);
                if (entry.Stage is ProcessingStage.Failed or ProcessingStage.NeedsReconciliation) tray?.Notify("云端处理未完成", "本地音频已保留，可在录音库继续处理。");
                library?.ProcessingChanged();
            });
            tray = new TrayIcon(recorder, recorder.Show, () => _ = recorder.Run(Quit), ("录音库", ShowLibrary), ("账号", ShowAccount), ("字幕", ShowCaptions), ("设置", ShowSettings));
            attentionTimer = dispatcher.CreateTimer(); attentionTimer.Interval = TimeSpan.FromSeconds(5);
            attentionTimer.Tick += async (_, _) => await recorder.Run(CheckAttention); attentionTimer.Start();
            suggestionTimer = dispatcher.CreateTimer(); suggestionTimer.Interval = TimeSpan.FromSeconds(5);
            suggestionTimer.Tick += async (_, _) => await recorder.Run(CheckSuggestions); suggestionTimer.Start();
            _ = ListenForActivation();
            startupProbe?.Observe(recorder); recorder.Show();
            if (recovery) ShowSettings();
            else if (!Preferences.OnboardingCompleted) ShowOnboarding();
            await recorder.Run(recorder.RefreshDevices);
            await Account.RestoreAsync(lifetime.Token);
            if (startupProbe is not null)
            {
                await startupProbe.Complete(Account, recorder);
                if (startupProbe.ExitAfterReady && !recorder.IsActive) await Quit();
            }
        }
        catch (Exception error)
        {
            var failure = new DesktopWindow("Recappi Mini · 启动失败", 500, 280);
            failure.Body.Children.Add(Ui.Text(error.Message));
            failure.Closed += (_, _) => { Cleanup(); Exit(); }; failure.Show();
        }
    }
    private T Track<T>(T window) where T : DesktopWindow
    {
        windows.Add(window); window.ApplyTheme(Preferences.Theme);
        window.Closed += (_, _) => windows.Remove(window);
        return window;
    }
    public void ShowLibrary()
    {
        // Finished captions remain available from the recorder/tray, but should not
        // cover the library when the user moves from recording to review.
        if (!recorder.IsActive) captionWindow?.Hide();
        if (library is null) { library = Track(new LibraryWindow(this)); library.Closed += (_, _) => library = null; }
        library.Show(); _ = library.Run(library.Refresh);
    }
    public void ShowRecorder() => recorder.Show();
    public void ShowRecording(string id) { ShowLibrary(); if (library is { } window) _ = window.Run(() => window.SelectRecording(id)); }
    public void ShowAccount()
    {
        if (accountWindow is null) { accountWindow = Track(new AccountWindow(this)); accountWindow.Closed += (_, _) => accountWindow = null; }
        accountWindow.Show();
    }
    public void ShowSettings()
    {
        if (settingsWindow is null) { settingsWindow = Track(new SettingsWindow(this, recovery)); settingsWindow.Closed += (_, _) => settingsWindow = null; }
        settingsWindow.Show();
    }
    public void ShowOnboarding(bool restart = false)
    {
        if (onboarding is null) { onboarding = Track(new OnboardingWindow(this)); onboarding.Closed += (_, _) => onboarding = null; }
        if (restart) onboarding.Restart();
        onboarding.Show();
    }
    public void ShowCaptions()
    {
        if (captionWindow is null)
        {
            captionWindow = Track(new CaptionWindow(RetryCaptions));
            // Keep the first caption line clear of the always-on-top recorder.
            // Only choose this initial position; subsequent user placement is retained.
            var recorderPosition = recorder.AppWindow.Position;
            var recorderSize = recorder.AppWindow.Size;
            var scale = recorder.Content.XamlRoot?.RasterizationScale ?? 1;
            // Starting a recording adds a source/status line to the compact recorder.
            var reservedHeight = Math.Max(recorderSize.Height, (int)Math.Ceiling(96 * scale));
            captionWindow.AppWindow.Move(new Windows.Graphics.PointInt32(recorderPosition.X, recorderPosition.Y + reservedHeight + (int)Math.Ceiling(12 * scale)));
            captionWindow.AppWindow.Closing += (_, e) => { if (!quitting) { e.Cancel = true; captionWindow.Hide(); } };
        }
        if (Engine.Snapshot.State is RecordingState.Starting or RecordingState.Recording or RecordingState.Stopping &&
            !recordingPreferences.CaptionsEnabled)
            captionWindow.SetStatus("本次录音未启用字幕；可在下次开始前开启。");
        captionWindow.ShowWithoutActivation();
    }
    public void SavePreferences(DesktopPreferences value)
    {
        preferenceStore.Save(value); Preferences = value.Validate(); recovery = false;
        recorder.ApplyPreferences();
        foreach (var window in windows) window.ApplyTheme(Preferences.Theme);
    }
    public void SetRecordingLanguage(string language, string translation) => Preferences = Preferences with { CaptionLanguage = language, TranslationLanguage = translation };
    public async Task StartRecording(RecordingOptions options, DesktopPreferences preferences)
    {
        if (quitPending) return;
        await Task.WhenAll(stopping.Values.ToArray());
        foreach (var stream in stopping.Where(x => x.Value.IsCompleted).Select(x => x.Key).ToArray()) stopping.Remove(stream);
        attention.Reset(); suggestions.SuppressActive(); tray?.ClearNotificationAction(); systemRms = microphoneRms = 0;
        recordingSourceProcess = options.ProcessId is { } process ? (int)process : null;
        recordingPreferences = preferences.Validate(); Preferences = recordingPreferences;
        if (!recovery) preferenceStore.Save(Preferences);
        recordingAccount = Account.Snapshot.State == AccountState.SignedIn ? Account.Snapshot.Account : null;
        captionPartition = recordingAccount?.Partition;
        if (preferences.CaptionsEnabled) { ShowCaptions(); captionWindow!.Reset(preferences.TranslationLanguage.Length > 0); CreateCaptions(); }
        await Engine.StartAsync(options);
    }
    public async Task StopRecording()
    {
        var recording = await Engine.StopAsync();
        await StopCaptions();
        if (recording is { State: RecordingState.Done } && recordingPreferences.AutoUpload && recordingAccount is { } owner &&
            Account.Snapshot is { State: AccountState.SignedIn, Account: { } current } && owner.Partition == current.Partition)
            _ = recorder.Run(async () => { await Processing.StartAsync(recording, current, recording.Processing ?? recordingPreferences.Processing); });
        library?.ProcessingChanged();
    }
    private void CreateCaptions()
    {
        var account = Account.Snapshot.State == AccountState.SignedIn ? Account.Snapshot.Account : null;
        if (account is null || (captionPartition is not null && captionPartition != account.Partition))
        { captionWindow?.SetStatus("登录原账号后可连接字幕；本地录音继续保存。"); return; }
        captionPartition ??= account.Partition;
        var options = new CaptionOptions(recordingPreferences.CaptionLanguage, recordingPreferences.TranslationLanguage);
        var stream = new LiveCaptions(options, async cancellation =>
        {
            using var client = Account.Client(account);
            var claim = await client.CaptionSessionAsync(options, cancellation);
            return await CaptionConnection.ConnectAsync(claim, account.Origin, cancellation);
        }, autoStart: false);
        captions = stream;
        stream.Delta += value => dispatcher.TryEnqueue(() => { if (ReferenceEquals(captions, stream)) captionWindow?.Update(value); });
        stream.Reordered += values => dispatcher.TryEnqueue(() => { if (ReferenceEquals(captions, stream)) captionWindow?.UpdateBatch(values); });
        stream.Changed += value => dispatcher.TryEnqueue(() => { if (ReferenceEquals(captions, stream)) captionWindow?.SetStatus(value.Message ?? value.State); });
    }
    private void AttachArchive(LiveCaptions stream, LocalRecording recording, bool resume)
    {
        try
        {
            var archive = new CaptionArchive(Store.CaptionPath(recording), resume); archives[stream] = archive;
            stream.Delta += archive.Append;
            stream.Reordered += archive.AppendRevisions;
            archive.ErrorChanged += message => dispatcher.TryEnqueue(() => captionWindow?.SetArchiveError(message));
            if (archive.Error is { } error) dispatcher.TryEnqueue(() => captionWindow?.SetArchiveError(error));
        }
        catch (Exception) { dispatcher.TryEnqueue(() => captionWindow?.SetArchiveError("字幕归档不可用；本地音频仍会保留。")); }
        stream.Start();
    }
    private async Task RetryCaptions()
    {
        if (quitPending || Engine.Snapshot is not { State: RecordingState.Recording, Recording: { } recording } || !recordingPreferences.CaptionsEnabled) return;
        if (captions is { } current) { current.TryRetry(); return; }
        await Task.WhenAll(stopping.Values.ToArray());
        if (Engine.Snapshot.State != RecordingState.Recording || Engine.Snapshot.Recording?.Id != recording.Id) return;
        CreateCaptions();
        if (captions is { } stream) AttachArchive(stream, recording, true);
    }
    public Task StopCaptions(bool abort = false)
    {
        var stream = captions;
        if (stream is null)
        {
            if (Engine.Snapshot.State is RecordingState.Done or RecordingState.Error or RecordingState.Idle)
                captionWindow?.SetStatus("实时字幕已停止。");
            return Task.WhenAll(stopping.Values.ToArray());
        }
        if (abort) { captions = null; _ = stream.AbortAsync(); }
        if (stopping.TryGetValue(stream, out var pending)) return pending;
        return stopping[stream] = FinishCaptions(stream);
    }
    public Task StopCaptionsIfFinished() => Engine.Snapshot.State is RecordingState.Starting or RecordingState.Recording or RecordingState.Stopping
        ? Task.CompletedTask : StopCaptions();
    private async Task FinishCaptions(LiveCaptions stream)
    {
        await stream.StopAsync(); await stream.DisposeAsync();
        if (archives.TryRemove(stream, out var archive)) { stream.Delta -= archive.Append; stream.Reordered -= archive.AppendRevisions; await archive.DisposeAsync(); }
        if (ReferenceEquals(captions, stream)) { captions = null; captionWindow?.SetStatus("实时字幕已停止。"); }
    }
    private async Task ListenForActivation()
    {
        while (!lifetime.IsCancellationRequested)
        {
            try
            {
                using var server = new NamedPipeServerStream(InstanceName, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await server.WaitForConnectionAsync(lifetime.Token);
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); timeout.CancelAfter(2500);
                var message = new byte[1];
                if (await server.ReadAsync(message, timeout.Token) == 1 && message[0] == 1) dispatcher.TryEnqueue(recorder.Show);
            }
            catch (OperationCanceledException) { }
            catch (IOException) { if (!lifetime.IsCancellationRequested) await Task.Delay(250); }
        }
    }
    private bool RecorderVisible => recorder.IsUserVisible && recorder.AppWindow.Presenter is Microsoft.UI.Windowing.OverlappedPresenter { State: not Microsoft.UI.Windowing.OverlappedPresenterState.Minimized };
    private async Task CheckAttention()
    {
        if (checkingAttention || Engine.Snapshot is not { State: RecordingState.Recording, Recording: { } recording }) return;
        checkingAttention = true;
        try
        {
            IReadOnlySet<int> active = new HashSet<int>(); var known = true;
            try { active = await Task.Run(() => AudioActivity.ActiveProcessIds()); } catch (Exception) { known = false; }
            if (Engine.Snapshot.State != RecordingState.Recording || Engine.Snapshot.Recording?.Id != recording.Id) return;
            var rms = Math.Max(Volatile.Read(ref systemRms), Engine.MicrophoneEnabled ? Volatile.Read(ref microphoneRms) : 0);
            var value = new AttentionSnapshot((int)(Engine.Snapshot.Recording!.DurationMs / 1000), RecorderVisible, active, recordingSourceProcess, rms, known);
            foreach (var action in attention.Evaluate(value, recordingPreferences.Attention))
            {
                if (action == AttentionAction.LongHiddenRecording) tray?.Notify("录音仍在继续", $"已录制 {value.ElapsedSeconds / 60} 分钟，可从托盘恢复面板。");
                else { recorder.RequestAttention(action); if (!RecorderVisible) tray?.Notify("录音提醒", "打开面板选择停止保存或继续录音。"); }
            }
        }
        finally { checkingAttention = false; }
    }
    private async Task CheckSuggestions()
    {
        if (checkingSuggestions || quitting) return;
        if (!Preferences.RecordingSuggestions || recorder.IsActive) { suggestions.SuppressActive(); return; }
        checkingSuggestions = true;
        try
        {
            var sources = await Task.Run(() =>
            {
                var active = AudioActivity.ActiveProcessIds(requireSignal: true, sameApplicationOnly: true, excludedProcessId: Environment.ProcessId);
                return AudioDevices.ListSources().Where(x => x.ProcessId is { } pid && pid != Environment.ProcessId && active.Contains(pid)).ToArray();
            });
            if (quitting) return;
            var suggestion = suggestions.Observe(DateTimeOffset.UtcNow, sources, Preferences.RecordingSuggestions, recorder.IsActive, RecorderVisible);
            if (suggestion is not null) tray?.Notify("是否录制应用声音？", suggestion.Label + " 正在播放声音。点击选择来源，再确认开始录音。", () =>
            {
                if (recorder.IsActive || !Preferences.RecordingSuggestions) return;
                recorder.Show(); _ = recorder.Run(() => recorder.SelectSuggestedSource(suggestion));
            });
        }
        catch (Exception) { }
        finally { checkingSuggestions = false; }
    }
    public async Task Quit()
    {
        if (quitPending) return;
        quitPending = true;
        try
        {
            if (settingsWindow is not null && !settingsWindow.Flush()) { settingsWindow.Show(); return; }
            if (recorder.IsActive)
            {
                recorder.Show();
                if (!await recorder.Confirm("退出 Recappi Mini", "录音正在进行。停止并保存后退出？", "保存并退出")) return;
            }
            await Engine.DisposeAsync(); await StopCaptions(); await Processing.DisposeAsync();
            Account.CancelLogin(); quitting = true; Cleanup();
            var closingWindows = windows.ToArray();
            // Remove every surface before tearing down XAML, which can clear a visible HWND.
            foreach (var window in closingWindows) window.AppWindow.Hide();
            foreach (var window in closingWindows) window.Close();
            Exit();
        }
        finally { if (!quitting) quitPending = false; }
    }
    private void Cleanup()
    {
        attentionTimer?.Stop(); suggestionTimer?.Stop();
        lifetime.Cancel(); tray?.Dispose(); installGuard?.Dispose();
        if (ownsInstance) { instance?.ReleaseMutex(); ownsInstance = false; }
        instance?.Dispose();
    }
}
