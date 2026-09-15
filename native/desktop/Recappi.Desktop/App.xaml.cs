using System;
using System.ComponentModel;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Linq;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Threading;
using Recappi.Core;
using Forms = System.Windows.Forms;

namespace Recappi.Desktop;

public partial class App : Application
{
    private Mutex? instanceMutex;
    private Mutex? installationGuard;
    private bool ownsMutex;
    private readonly CancellationTokenSource lifetime = new();
    private Forms.NotifyIcon? tray;
    private System.Drawing.Icon? idleTrayIcon;
    private System.Drawing.Icon? recordingTrayIcon;
    private RecorderWindow? recorderWindow;
    private CloudLibraryWindow? cloudLibraryWindow;
    private AccountWindow? accountWindow;
    private AccountSession? accountSession;
    private CloudProcessing? processing;
    private CloudContentCache? cloudContentCache;
    private SpeakerProfileStore? speakerProfiles;
    private CloudAccount? recordingAccount;
    private LiveCaptions? captions;
    private LiveCaptions? recordingCaptions;
    private string? recordingCaptionPartition;
    private bool retryingCaptions;
    private readonly Dictionary<LiveCaptions, Task> stoppingCaptions = [];
    private CaptionWindow? captionWindow;
    private SettingsWindow? settingsWindow;
    private OnboardingWindow? onboardingWindow;
    private PreferencesStore? preferencesStore;
    private DesktopPreferences preferences = new();
    private DesktopPreferences recordingPreferences = new();
    private bool preferencesLoadFailed;
    private readonly ConcurrentDictionary<LiveCaptions, CaptionArchive> captionArchives = new();
    private readonly RecordingAttention attention = new();
    private DispatcherTimer? attentionTimer;
    private DispatcherTimer? suggestionTimer;
    private readonly RecordingSuggestion suggestions = new();
    private bool checkingSuggestions;
    private AudioSource? pendingSuggestion;
    private bool suppressNextSuggestionObservation;
    private bool checkingAttention;
    private int? recordingSourceProcessId;
    private double systemRms;
    private double microphoneRms;
    private string? activeAccountPartition;
    private readonly string backendOrigin = Environment.GetEnvironmentVariable("RECAPPI_ORIGIN") ?? "https://recordmeet.ing";
    private RecorderViewModel? recorder;
    private bool quitting;
    private bool quitPending;
    private static string InstanceName => "RecappiMini.Desktop." + Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Environment.UserDomainName + "\\" + Environment.UserName)))[..20];

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        var startupProbe = StartupProbe.Create();
        instanceMutex = new Mutex(true, "Local\\" + InstanceName, out ownsMutex);
        if (!ownsMutex)
        {
            try
            {
                using var pipe = new NamedPipeClientStream(".", InstanceName, PipeDirection.Out, PipeOptions.Asynchronous);
                await pipe.ConnectAsync(2500);
                await pipe.WriteAsync(new byte[] { 1 });
            }
            catch (Exception error) when (error is IOException or TimeoutException) { }
            Shutdown();
            return;
        }
        installationGuard = new Mutex(false, "Local\\RecappiMini.Desktop.InstallGuard");
        try
        {
            using var maintenance = Mutex.OpenExisting("Local\\RecappiMini.Desktop.Setup");
            MessageBox.Show("安装或卸载正在进行。请关闭安装窗口后再启动 Recappi Mini。", "Recappi Mini");
            Shutdown(); return;
        }
        catch (WaitHandleCannotBeOpenedException) { }
        var overrideRoot = Environment.GetEnvironmentVariable("RECAPPI_DESKTOP_DATA_DIR");
        // Packaged activation doesn't inherit the launching shell's environment.
        // An explicit isolated directory keeps lifecycle validation away from user data.
        if (e.Args.Length == 2 && e.Args[0] == "--validation-data-dir")
        {
            if (!Path.IsPathFullyQualified(e.Args[1]))
            {
                MessageBox.Show("验证数据目录必须是绝对路径。", "Recappi Mini");
                Shutdown(); return;
            }
            overrideRoot = e.Args[1];
        }
        var applicationRoot = Path.GetDirectoryName(Path.GetFullPath(overrideRoot ?? LocalRecordingStore.DefaultRoot))!;
        preferencesStore = new PreferencesStore(applicationRoot);
        try { preferences = preferencesStore.Load(); } catch (Exception) { preferencesLoadFailed = true; }
        DesktopTheme.Apply(preferences.Theme);
        var dataRoot = overrideRoot ?? preferences.RecordingsRoot;
        var store = new LocalRecordingStore(dataRoot);
        // Single-instance ownership is established; no recorder/import can write yet.
        try { await Task.Run(store.RecoverInterruptedRecordings); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { /* Library access errors remain visible when opening the library. */ }
        accountSession = new AccountSession(new AccountStore(Path.Combine(applicationRoot, "Account")));
        processing = new CloudProcessing(Path.Combine(applicationRoot, "Processing"), account => accountSession.Client(account));
        cloudContentCache = new CloudContentCache(Path.Combine(applicationRoot, "CloudContent"));
        speakerProfiles = new SpeakerProfileStore(Path.Combine(applicationRoot, "Speakers"));
        accountSession.Changed += value =>
        {
            var partition = value.Account?.Partition;
            if (value.State is AccountState.SignedOut or AccountState.Expired || (activeAccountPartition is not null && partition != activeAccountPartition))
            {
                processing.CancelAll();
                var previousCaptions = Volatile.Read(ref captions);
                Dispatcher.BeginInvoke(async () => await StopCaptionsAsync(previousCaptions, true));
            }
            activeAccountPartition = partition;
            Dispatcher.BeginInvoke(() =>
            {
                if (CanResumeCaptions() && Volatile.Read(ref captions) is null)
                    captionWindow?.UpdateStatus(new("failed", "账号已连接，可重新连接字幕。"));
            });
        };
        processing.Changed += entry => Dispatcher.BeginInvoke(() =>
        {
            if (entry.Partition != accountSession.Snapshot.Account?.Partition) return;
            if (entry.Stage is ProcessingStage.Synced or ProcessingStage.Completed && cloudLibraryWindow is { } library)
                _ = library.RefreshProcessedRecordingAsync(entry);
            if (entry.Stage == ProcessingStage.Completed) tray?.ShowBalloonTip(3000, "会议处理完成", entry.Title, Forms.ToolTipIcon.Info);
            else if (entry.Stage == ProcessingStage.Synced) tray?.ShowBalloonTip(3000, "录音上传完成", "可在录音库手动转写。", Forms.ToolTipIcon.Info);
            else if (entry.Stage is ProcessingStage.Failed or ProcessingStage.NeedsReconciliation) tray?.ShowBalloonTip(3000, "云端处理未完成", "本地音频已保留，可在录音库继续处理。", Forms.ToolTipIcon.Warning);
        });
        recorder = new RecorderViewModel(new RecordingEngine(store), store, Dispatcher);
        recorder.ApplyPreferences(preferences);
        recorder.BeforeDiscard = () => StopCaptionsAsync(recordingCaptions, true);
        recorder.PropertyChanged += RecordingChanged;
        recorder.Starting += () =>
        {
            suggestions.SuppressActive(); pendingSuggestion = null; suppressNextSuggestionObservation = true;
            attention.Reset(); systemRms = microphoneRms = 0; recordingSourceProcessId = recorder.SelectedSource?.ProcessId;
            recordingPreferences = recorder.Preferences.Validate(); preferences = recordingPreferences;
            if (!preferencesLoadFailed)
            {
                try { preferencesStore.Save(preferences); }
                catch (Exception) { tray?.ShowBalloonTip(3000, "设置未保存", "本次录音仍会使用当前设置。", Forms.ToolTipIcon.Warning); }
            }
            recordingAccount = accountSession.Snapshot.State == AccountState.SignedIn ? accountSession.Snapshot.Account : null;
            StartCaptions();
        };
        recorder.Engine.Audio += samples => Volatile.Read(ref captions)?.Append(samples);
        recorder.Engine.Level += level =>
        {
            var rms = Math.Pow(10, level.RmsDb / 20);
            if (level.Input == "system") Volatile.Write(ref systemRms, rms); else Volatile.Write(ref microphoneRms, rms);
        };
        recorder.Engine.Changed += value =>
        {
            if (value.State == RecordingState.Starting && value.Recording is { } recording && Volatile.Read(ref captions) is { } stream)
            {
                AttachCaptionArchiveAndStart(stream, recording);
            }
            if (value.State is RecordingState.Done or RecordingState.Error or RecordingState.Idle)
            {
                var previousCaptions = Volatile.Read(ref captions);
                Dispatcher.BeginInvoke(async () => await StopCaptionsAsync(previousCaptions));
            }
        };
        recorder.Saved += recording =>
        {
            var account = accountSession.Snapshot;
            if (recordingPreferences.AutoUpload && recordingAccount is not null && account.State == AccountState.SignedIn && account.Account?.Partition == recordingAccount.Partition)
                _ = ProcessRecordingAsync(recording, account.Account);
        };
        recorderWindow = new RecorderWindow(recorder, ShowLibrary, ShowAccount, ShowCaptions, ShowSettings, ShowCloudLibrary, id => ShowLibrary(id), async () => await QuitAsync());
        recorderWindow.Closing += HideOnClose;
        attentionTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        attentionTimer.Tick += async (_, _) => await CheckAttentionAsync();
        MainWindow = recorderWindow;
        idleTrayIcon = LoadTrayIcon("Recappi.ico");
        recordingTrayIcon = LoadTrayIcon("Recappi.Recording.ico");
        tray = new Forms.NotifyIcon { Icon = idleTrayIcon, Text = "Recappi Mini", Visible = true };
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("显示录音面板", null, (_, _) => Dispatcher.BeginInvoke(ShowRecorder));
        menu.Items.Add("录音库", null, (_, _) => Dispatcher.BeginInvoke(ShowLibrary));
        menu.Items.Add("账号", null, (_, _) => Dispatcher.BeginInvoke(ShowAccount));
        menu.Items.Add("字幕窗", null, (_, _) => Dispatcher.BeginInvoke(ShowCaptions));
        menu.Items.Add("设置", null, (_, _) => Dispatcher.BeginInvoke(ShowSettings));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("退出", null, (_, _) => Dispatcher.BeginInvoke(async () => await QuitAsync()));
        tray.ContextMenuStrip = menu;
        tray.DoubleClick += (_, _) => Dispatcher.BeginInvoke(ShowRecorder);
        tray.BalloonTipClicked += (_, _) => Dispatcher.BeginInvoke(async () =>
        {
            var candidate = pendingSuggestion; pendingSuggestion = null;
            ShowRecorder();
            if (candidate is null || recorder.IsActive) return;
            await recorder.RefreshDevicesAsync();
            var current = recorder.Sources.FirstOrDefault(x => x.Id == candidate.Id);
            if (current is not null && !recorder.IsActive) { recorder.SelectSuggestedSource(current); }
        });
        suggestionTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(5) };
        suggestionTimer.Tick += async (_, _) => await CheckSuggestionsAsync();
        suggestionTimer.Start();
        _ = ListenForActivationAsync(lifetime.Token);
        startupProbe?.Observe(recorderWindow);
        recorderWindow.Show();
        if (preferencesLoadFailed) ShowSettings();
        else if (!preferences.OnboardingCompleted) ShowOnboarding();
        await recorder.RefreshDevicesAsync();
        await accountSession.RestoreAsync(lifetime.Token);
        if (startupProbe is not null)
        {
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            await startupProbe.CompleteAsync(accountSession, recorder);
            if (startupProbe.ExitAfterReady && !recorder.IsActive) await QuitAsync();
        }
    }

    private async Task ListenForActivationAsync(CancellationToken token)
    {
        while (!token.IsCancellationRequested)
        {
            try
            {
                using var server = new NamedPipeServerStream(InstanceName, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                await server.WaitForConnectionAsync(token);
                var message = new byte[1];
                using var readTimeout = CancellationTokenSource.CreateLinkedTokenSource(token);
                readTimeout.CancelAfter(2500);
                if (await server.ReadAsync(message, readTimeout.Token) == 1 && message[0] == 1) await Dispatcher.InvokeAsync(ShowRecorder);
            }
            catch (OperationCanceledException) { if (token.IsCancellationRequested) break; }
            catch (IOException) { await Task.Delay(250, token).ConfigureAwait(false); }
        }
    }

    private void ShowRecorder()
    {
        if (recorderWindow is null) return;
        recorderWindow.Show();
        if (recorderWindow.WindowState == WindowState.Minimized) recorderWindow.WindowState = WindowState.Normal;
        recorderWindow.Activate();
    }

    private void ShowLibrary() => ShowLibrary(null);
    private void ShowLibrary(string? recordingId)
    {
        if (recorder is null) return;
        if (cloudLibraryWindow is null)
        {
            var localView = new LocalLibraryView(recorder.Store, accountSession, processing, ShowAccount, () => Task.WhenAll(stoppingCaptions.Values.ToArray()));
            cloudLibraryWindow = new CloudLibraryWindow(accountSession!, () => preferences.Processing,
                (account, id) => processing!.ForgetRemoteAsync(account.Partition, id), contentCache: cloudContentCache, localLibrary: localView, showAccount: ShowAccount, processingEntries: partition => processing!.List(partition), speakerProfiles: speakerProfiles);
            cloudLibraryWindow.Closed += (_, _) => cloudLibraryWindow = null;
        }
        cloudLibraryWindow.RefreshLocalRecordings(recordingId);
        cloudLibraryWindow.SetCurrentMeeting(recorder.Engine.Snapshot, ShowRecorder);
        cloudLibraryWindow.Show();
        cloudLibraryWindow.Activate();
    }

    private void ShowAccount()
    {
        if (accountSession is null) return;
        if (accountWindow is null)
        {
            accountWindow = new AccountWindow(accountSession, backendOrigin);
            accountWindow.Closed += (_, _) => accountWindow = null;
        }
        accountWindow.Show(); accountWindow.Activate();
    }

    private void ShowCloudLibrary()
    {
        ShowLibrary();
    }

    private async Task ProcessRecordingAsync(LocalRecording recording, CloudAccount account)
    {
        try { await processing!.StartAsync(recording, account, recording.Processing ?? preferences.Processing); }
        catch (ProcessingJournalException error) { await Dispatcher.InvokeAsync(() => tray?.ShowBalloonTip(5000, "后台处理无法继续", error.Message, Forms.ToolTipIcon.Warning)); }
        catch { await Dispatcher.InvokeAsync(() => tray?.ShowBalloonTip(3000, "后台处理无法继续", "请从录音库重试；本地音频未删除。", Forms.ToolTipIcon.Warning)); }
    }

    private void ShowSettings()
    {
        if (settingsWindow is null)
        {
            settingsWindow = new SettingsWindow(recorder?.Preferences ?? preferences, value =>
            {
                value = value with { OnboardingCompleted = preferences.OnboardingCompleted, OnboardingStep = preferences.OnboardingStep };
                preferencesStore!.Save(value); preferences = value; preferencesLoadFailed = false; recorder?.ApplyPreferences(value);
                DesktopTheme.Apply(value.Theme);
            }, ShowAccount, preferencesLoadFailed ? "设置读取失败，当前使用默认值。修改设置后可重建设置文件。" : null, RestartOnboarding, () => recorder?.Preferences ?? preferences);
            settingsWindow.Closed += (_, _) => settingsWindow = null;
        }
        settingsWindow.Show(); settingsWindow.Activate();
    }

    private void SaveOnboardingPreferences(DesktopPreferences value)
    {
        preferencesStore!.Save(value); preferences = value; recorder?.ApplyPreferences(value);
    }
    private void RestartOnboarding()
    {
        if (onboardingWindow is not null)
        {
            onboardingWindow.Restart(); onboardingWindow.Show(); onboardingWindow.Activate(); return;
        }
        SaveOnboardingPreferences((recorder?.Preferences ?? preferences) with { OnboardingCompleted = false, OnboardingStep = 0 });
        ShowOnboarding();
    }
    private void ShowOnboarding()
    {
        if (onboardingWindow is null)
        {
            onboardingWindow = new OnboardingWindow(() => recorder?.Preferences ?? preferences,
                SaveOnboardingPreferences, ShowAccount, accountSession, () => quitting);
            onboardingWindow.Closed += (_, _) => onboardingWindow = null;
        }
        onboardingWindow.Show(); onboardingWindow.Activate();
    }

    private void ShowCaptions()
    {
        if (captionWindow is null)
        {
            captionWindow = new CaptionWindow(RetryCaptionsAsync);
            captionWindow.Closing += (_, e) => { if (!quitting) { e.Cancel = true; captionWindow.Hide(); } };
        }
        captionWindow.ConfigureTranslation(!string.IsNullOrWhiteSpace(recorder?.TranslationLanguage));
        captionWindow.Show();
    }
    private bool CanResumeCaptions() => !quitPending && !quitting && recorder?.Engine.Snapshot.State == RecordingState.Recording && recorder.CaptionsEnabled &&
        accountSession?.Snapshot is { State: AccountState.SignedIn, Account: { } account } &&
        ((recordingCaptionPartition ?? recordingAccount?.Partition) is not { } owner || owner == account.Partition);
    private async Task<bool> RetryCaptionsAsync()
    {
        if (retryingCaptions || !CanResumeCaptions()) return false;
        retryingCaptions = true;
        try
        {
        var current = Volatile.Read(ref captions);
        if (current is not null) return current.TryRetry();
        var recording = recorder!.Engine.Snapshot.Recording!;
        var account = accountSession!.Snapshot.Account!;
        await Task.WhenAll(stoppingCaptions.Values.ToArray());
        if (!CanResumeCaptions() || recorder.Engine.Snapshot.Recording?.Id != recording.Id || accountSession.Snapshot.Account?.Token != account.Token) return false;
        StartCaptions(account, reset: false);
        if (captions is not { } stream) return false;
        return AttachCaptionArchiveAndStart(stream, recording, resume: true);
        }
        finally { retryingCaptions = false; }
    }
    private bool AttachCaptionArchiveAndStart(LiveCaptions stream, LocalRecording recording, bool resume = false)
    {
        var window = captionWindow;
        void ReportArchiveError(string? error)
        {
            if (ReferenceEquals(Volatile.Read(ref captions), stream)) window?.UpdateArchiveError(error);
        }
        ReportArchiveError(null);
        try
        {
            var archive = new CaptionArchive(recorder!.Store.CaptionPath(recording), resume);
            captionArchives[stream] = archive;
            archive.ErrorChanged += ReportArchiveError;
            stream.Delta += archive.Append;
            // File initialization runs asynchronously and may fail before subscription.
            if (archive.Error is { } error) ReportArchiveError(error);
        }
        catch (Exception) { ReportArchiveError("字幕归档不可用；本地音频仍会保存。"); }
        // A failed archive must not leave a deferred live stream waiting forever.
        return stream.Start();
    }
    private void StartCaptions(CloudAccount? resumedAccount = null, bool reset = true)
    {
        if (reset) recordingCaptionPartition = null;
        foreach (var key in stoppingCaptions.Where(x => x.Value.IsCompleted).Select(x => x.Key).ToArray()) stoppingCaptions.Remove(key);
        recordingCaptions = null;
        var previous = captions;
        captions = null;
        if (previous is not null) _ = StopCaptionsAsync(previous);
        if (recorder?.CaptionsEnabled != true) return;
        ShowCaptions(); var window = captionWindow!;
        if (reset) window.Reset();
        var account = resumedAccount ?? recordingAccount;
        if (account is null)
        {
            window.UpdateStatus(new("failed", "登录后可使用实时字幕；本地录音仍会继续。")); return;
        }
        recordingCaptionPartition ??= account.Partition;
        var options = new CaptionOptions(recorder.CaptionLanguage, recorder.TranslationLanguage);
        var stream = new LiveCaptions(options, async cancellation =>
        {
            using var client = accountSession!.Client(account);
            var claim = await client.CaptionSessionAsync(options, cancellation);
            return await CaptionConnection.ConnectAsync(claim, account.Origin, cancellation);
        }, autoStart: false);
        captions = stream;
        recordingCaptions = stream;
        stream.Delta += value => { if (ReferenceEquals(Volatile.Read(ref captions), stream)) window.Update(value); };
        stream.Changed += value => { if (ReferenceEquals(Volatile.Read(ref captions), stream)) window.UpdateStatus(value); };
        window.UpdateStatus(stream.Status);
    }
    private Task StopCaptionsAsync(LiveCaptions? stream, bool abort = false)
    {
        if (stream is null) return Task.CompletedTask;
        if (abort)
        {
            if (ReferenceEquals(captions, stream)) { captions = null; captionWindow?.UpdateStatus(new("stopped", "实时字幕已停止。")); }
            _ = stream.AbortAsync();
        }
        if (stoppingCaptions.TryGetValue(stream, out var existing)) return existing;
        var task = FinishCaptionsAsync(stream); stoppingCaptions[stream] = task; return task;
    }
    private async Task FinishCaptionsAsync(LiveCaptions stream)
    {
        // Every stop caller waits for both final transcript drain and archive closure.
        await stream.StopAsync();
        await stream.DisposeAsync();
        if (captionArchives.TryRemove(stream, out var archive))
        {
            stream.Delta -= archive.Append;
            await archive.DisposeAsync();
            if (archive.Error is { } error && ReferenceEquals(captions, stream)) captionWindow?.UpdateArchiveError(error);
        }
        if (ReferenceEquals(captions, stream)) { captions = null; captionWindow?.UpdateStatus(stream.Status with { State = "stopped" }); }
    }

    private void HideOnClose(object? sender, CancelEventArgs e)
    {
        if (quitting) return;
        e.Cancel = true;
        suggestions.SuppressActive(); pendingSuggestion = null;
        recorderWindow?.Hide();
        if (recorder?.IsActive == true) tray?.ShowBalloonTip(3000, "录音继续进行", "可从系统托盘恢复录音面板。", Forms.ToolTipIcon.Info);
    }

    private void RecordingChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName != nameof(RecorderViewModel.StateLabel) || recorder is null || tray is null) return;
        tray.Text = "Recappi Mini · " + recorder.StateLabel;
        cloudLibraryWindow?.SetCurrentMeeting(recorder.Engine.Snapshot, ShowRecorder);
        tray.Icon = recorder.IsActive ? recordingTrayIcon : idleTrayIcon;
        if (recorder.IsActive) attentionTimer?.Start(); else attentionTimer?.Stop();
        if (!recorder.IsActive) cloudLibraryWindow?.RefreshLocalRecordings();
    }

    private async Task CheckAttentionAsync()
    {
        if (checkingAttention || recorder?.Engine.Snapshot is not { State: RecordingState.Recording, Recording: { } recording }) return;
        checkingAttention = true;
        try
        {
            IReadOnlySet<int> active = new HashSet<int>(); var known = true;
            try { active = await Task.Run(() => AudioActivity.ActiveProcessIds()); } catch (Exception) { known = false; }
            if (recorder.Engine.Snapshot.State != RecordingState.Recording || recorder.Engine.Snapshot.Recording?.Id != recording.Id) return;
            var visible = recorderWindow?.IsVisible == true && recorderWindow.WindowState != WindowState.Minimized;
            var rms = Math.Max(Volatile.Read(ref systemRms), recorder.Engine.MicrophoneEnabled ? Volatile.Read(ref microphoneRms) : 0);
            var snapshot = new AttentionSnapshot((int)(recorder.Engine.Snapshot.Recording.DurationMs / 1000), visible, active, recordingSourceProcessId, rms, known);
            foreach (var action in attention.Evaluate(snapshot, recordingPreferences.Attention))
            {
                if (action == AttentionAction.LongHiddenRecording) tray?.ShowBalloonTip(4000, "录音仍在继续", $"已录制 {snapshot.ElapsedSeconds / 60} 分钟，可从托盘恢复面板。", Forms.ToolTipIcon.Info);
                else
                {
                    recorder.RequestAttention(action);
                    if (!visible) tray?.ShowBalloonTip(4000, action == AttentionAction.DurationLimit ? "已达到录音时长提醒" : "声音来源似乎已停止", "打开录音面板，选择停止保存或继续录音。", Forms.ToolTipIcon.Info);
                }
            }
        }
        finally { checkingAttention = false; }
    }
    private async Task CheckSuggestionsAsync()
    {
        if (checkingSuggestions || quitting || recorder is null) return;
        if (!preferences.RecordingSuggestions || recorder.IsActive) { suggestions.SuppressActive(); pendingSuggestion = null; suppressNextSuggestionObservation = true; return; }
        checkingSuggestions = true;
        try
        {
            var sources = await Task.Run(() =>
            {
                var active = AudioActivity.ActiveProcessIds(requireSignal: true, sameApplicationOnly: true, excludedProcessId: Environment.ProcessId);
                return AudioDevices.ListSources().Where(x => x.ProcessId is { } pid && pid != Environment.ProcessId && active.Contains(pid)).ToArray();
            });
            if (quitting) return;
            var suggestion = suggestions.Observe(DateTimeOffset.UtcNow, sources, preferences.RecordingSuggestions && !suppressNextSuggestionObservation, recorder.IsActive, recorderWindow?.IsVisible == true && recorderWindow.WindowState != WindowState.Minimized);
            suppressNextSuggestionObservation = false;
            if (suggestion is not null)
            {
                pendingSuggestion = suggestion;
                tray?.ShowBalloonTip(6000, "是否录制应用声音？", suggestion.Label + " 正在播放声音。点击选择此来源，再确认开始录音。", Forms.ToolTipIcon.Info);
            }
        }
        catch (Exception) { /* Missing activity information must not create a suggestion. */ }
        finally { checkingSuggestions = false; }
    }

    private async Task QuitAsync()
    {
        if (quitPending) return;
        // Modal confirmation runs a nested dispatcher loop: guard before showing it.
        quitPending = true;
        try
        {
            if (recorder?.IsActive == true)
            {
                ShowRecorder();
                if (MessageBox.Show(recorderWindow!, "录音正在进行。停止并保存后退出？", "退出 Recappi Mini", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) != MessageBoxResult.Yes) return;
            }
            if (recorder is not null) await recorder.Engine.DisposeAsync();
            await StopCaptionsAsync(captions);
            await Task.WhenAll(stoppingCaptions.Values.ToArray());
            if (processing is not null) await processing.DisposeAsync();
            quitting = true;
            attentionTimer?.Stop(); suggestionTimer?.Stop();
            accountSession?.CancelLogin();
            lifetime.Cancel();
            tray?.Dispose();
            Shutdown();
        }
        catch (Exception error)
        {
            MessageBox.Show("未能完成退出：" + error.Message);
        }
        finally
        {
            if (!quitting) quitPending = false;
        }
    }

    private static System.Drawing.Icon LoadTrayIcon(string name)
    {
        using var stream = GetResourceStream(new Uri($"pack://application:,,,/Recappi Mini;component/Assets/{name}"))!.Stream;
        using var icon = new System.Drawing.Icon(stream);
        return (System.Drawing.Icon)icon.Clone();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        lifetime.Cancel();
        attentionTimer?.Stop(); suggestionTimer?.Stop();
        tray?.Dispose();
        idleTrayIcon?.Dispose(); recordingTrayIcon?.Dispose();
        if (ownsMutex) instanceMutex?.ReleaseMutex();
        instanceMutex?.Dispose();
        installationGuard?.Dispose();
        lifetime.Dispose();
        base.OnExit(e);
    }
}
