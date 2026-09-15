using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using System.Windows.Threading;
using Recappi.Core;

namespace Recappi.Desktop;

public sealed class AsyncCommand(Func<Task> action, Func<bool>? canExecute = null) : ICommand
{
    private bool busy;
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => !busy && (canExecute?.Invoke() ?? true);
    public async void Execute(object? parameter)
    {
        if (!CanExecute(parameter)) return;
        busy = true; Refresh();
        try { await action(); }
        finally { busy = false; Refresh(); }
    }
    public void Refresh() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

public sealed class RecorderViewModel : INotifyPropertyChanged
{
    public RecordingEngine Engine { get; }
    public LocalRecordingStore Store { get; }
    private readonly Dispatcher dispatcher;
    private readonly Func<(IReadOnlyList<AudioSource> Sources, IReadOnlyList<MicrophoneDevice> Microphones)> discoverDevices;
    private bool devicesLoaded;
    private AudioSource? selectedSource;
    private MicrophoneDevice? selectedMicrophone;
    private RecordingSnapshot snapshot = new(RecordingState.Idle, null);
    private string? error;
    private bool busy;
    private string title = "";
    private bool microphone = true;
    private double systemLevel;
    private double microphoneLevel;
    private long lastSystemLevel;
    private long lastMicrophoneLevel;
    private DesktopPreferences preferences = new();
    private string? attentionMessage;
    public string? AttentionMessage => attentionMessage;
    public bool HasAttention => attentionMessage is not null;
    public AsyncCommand KeepRecording { get; }
    public void RequestAttention(AttentionAction action)
    {
        if (!IsActive || HasAttention) return;
        attentionMessage = action == AttentionAction.DurationLimit ? "已达到设定时长。停止并保存，还是继续录音？" : "声音来源似乎已不活跃。停止并保存，还是继续录音？";
        Notify(nameof(AttentionMessage)); Notify(nameof(HasAttention));
    }
    public ObservableCollection<AudioSource> Sources { get; } = [];
    public ObservableCollection<MicrophoneDevice> Microphones { get; } = [];
    public AudioSource? SelectedSource { get => selectedSource; set { selectedSource = value; Notify(); Notify(nameof(Error)); Start?.Refresh(); } }
    public void SelectSuggestedSource(AudioSource source) { if (CanConfigure && Sources.Contains(source)) { SelectedSource = source; Notify(nameof(SelectedSource)); } }
    public MicrophoneDevice? SelectedMicrophone { get => selectedMicrophone; set { selectedMicrophone = value; Notify(); Notify(nameof(Error)); Start?.Refresh(); } }
    public string Title { get => title; set { title = value; Notify(); } }
    public bool Microphone { get => microphone; set { microphone = value; Notify(); Notify(nameof(Error)); Start?.Refresh(); } }
    public bool CaptionsEnabled { get; set; }
    public string CaptionLanguage { get; set; } = "en";
    public string TranslationLanguage { get; set; } = "";
    public bool IsActive => snapshot.State is RecordingState.Starting or RecordingState.Recording or RecordingState.Stopping;
    public bool IsDone => snapshot.State == RecordingState.Done;
    public bool ShowSetup => !IsActive && !IsDone;
    public string? SavedRecordingId => snapshot.Recording?.Id;
    public string SourceLabel => SelectedSource?.Label ?? "声音来源不可用";
    public AsyncCommand NewRecording { get; }
    public bool CanConfigure => !IsActive && !busy;
    public string StateLabel => snapshot.State switch { RecordingState.Starting => "正在启动", RecordingState.Recording => "录音中", RecordingState.Stopping => "正在保存", RecordingState.Done => "已保存到本地", RecordingState.Error => "录音失败", _ => "准备录音" };
    public string Elapsed => TimeSpan.FromMilliseconds(snapshot.Recording?.DurationMs ?? 0).ToString(@"hh\:mm\:ss");
    private string? SelectionIssue => !devicesLoaded ? null : SelectedSource is null
        ? "原声音来源不可用，请重新选择应用或系统声音。"
        : SelectedSource.Id == "microphone-only" && !Microphone ? "仅麦克风模式需要开启麦克风。"
        : Microphone && SelectedMicrophone is null ? "原麦克风不可用，请重新选择设备，或关闭麦克风仅录系统声音。" : null;
    public string? Error => error ?? snapshot.Error ?? SelectionIssue;
    public double SystemLevel => systemLevel;
    public double MicrophoneLevel => microphoneLevel;
    public string MicrophoneAction => Engine.MicrophoneEnabled ? "关闭麦克风" : "开启麦克风";
    public AsyncCommand Start { get; }
    public AsyncCommand Stop { get; }
    public AsyncCommand Discard { get; }
    public AsyncCommand ToggleMicrophone { get; }
    public AsyncCommand RefreshDevices { get; }
    public AsyncCommand OpenFolder { get; }
    public event PropertyChangedEventHandler? PropertyChanged;
    public event Action? Starting;
    public event Action<LocalRecording>? Saved;
    public Func<Task>? BeforeDiscard { get; set; }
    public DesktopPreferences Preferences => preferences with { CaptionsEnabled = CaptionsEnabled, CaptionLanguage = CaptionLanguage, TranslationLanguage = TranslationLanguage, IncludeMicrophone = Microphone, SourceId = SelectedSource?.Id ?? preferences.SourceId, MicrophoneId = SelectedMicrophone?.Id ?? preferences.MicrophoneId };
    public void ApplyPreferences(DesktopPreferences value)
    {
        preferences = value; CaptionsEnabled = value.CaptionsEnabled; CaptionLanguage = value.CaptionLanguage; TranslationLanguage = value.TranslationLanguage;
        Microphone = value.IncludeMicrophone;
        foreach (var name in new[] { nameof(CaptionsEnabled), nameof(CaptionLanguage), nameof(TranslationLanguage) }) Notify(name);
    }

    public RecorderViewModel(RecordingEngine engine, LocalRecordingStore store, Dispatcher dispatcher,
        Func<(IReadOnlyList<AudioSource> Sources, IReadOnlyList<MicrophoneDevice> Microphones)>? discoverDevices = null)
    {
        Engine = engine; Store = store; this.dispatcher = dispatcher;
        NewRecording = new(() =>
        {
            snapshot = new(RecordingState.Idle, null); error = null; Title = ""; Refresh();
            return Task.CompletedTask;
        }, () => !IsActive);
        this.discoverDevices = discoverDevices ?? (() => (AudioDevices.ListSources(), AudioDevices.ListMicrophones()));
        KeepRecording = new(() => { attentionMessage = null; Notify(nameof(AttentionMessage)); Notify(nameof(HasAttention)); return Task.CompletedTask; });
        Start = new(() => Guard(async () =>
        {
            if (!devicesLoaded || SelectedSource is null || SelectionIssue is not null) throw new InvalidOperationException(SelectionIssue ?? "请先选择声音来源。");
            Starting?.Invoke();
            await Engine.StartAsync(new RecordingOptions(Title, SelectedSource?.Id != "microphone-only", Microphone,
                SelectedSource?.ProcessId is { } pid ? (uint)pid : null, SelectedMicrophone?.Id, Preferences.Processing));
        }), () => CanConfigure && devicesLoaded && SelectionIssue is null);
        Stop = new(() => Guard(async () =>
        {
            var recording = await Engine.StopAsync();
            if (recording is { State: RecordingState.Done }) Saved?.Invoke(recording);
        }), () => snapshot.State == RecordingState.Recording);
        Discard = new(() => Guard(async () =>
        {
            if (MessageBox.Show("丢弃当前录音？本地音频将被删除。", "丢弃录音", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No) == MessageBoxResult.Yes)
            {
                if (BeforeDiscard is not null) await BeforeDiscard();
                await Engine.DiscardAsync();
            }
        }), () => snapshot.State == RecordingState.Recording);
        ToggleMicrophone = new(() => Guard(async () => { await Engine.SetMicrophoneEnabledAsync(!Engine.MicrophoneEnabled); Notify(nameof(MicrophoneAction)); }), () => snapshot.State == RecordingState.Recording);
        RefreshDevices = new(RefreshDevicesAsync, () => CanConfigure);
        OpenFolder = new(() => Guard(() =>
        {
            System.IO.Directory.CreateDirectory(Store.Root);
            Process.Start(new ProcessStartInfo(snapshot.Recording?.Directory ?? Store.Root) { UseShellExecute = true });
            return Task.CompletedTask;
        }));
        Engine.Changed += value => dispatcher.BeginInvoke(() => { snapshot = value; Refresh(); });
        Engine.Level += value =>
        {
            var now = Environment.TickCount64;
            ref var last = ref (value.Input == "system" ? ref lastSystemLevel : ref lastMicrophoneLevel);
            // Clearing a released input is a state change, not a meter animation.
            var releasedMicrophone = value.Input == "microphone" && !Engine.MicrophoneEnabled;
            if (!releasedMicrophone && now - last < 100) return;
            last = now;
            dispatcher.BeginInvoke(() =>
            {
                if (!IsActive) return;
                var level = value.Input == "microphone" && !Engine.MicrophoneEnabled
                    ? 0 : Math.Clamp((value.RmsDb + 60) / 60 * 100, 0, 100);
                if (value.Input == "system") { systemLevel = level; Notify(nameof(SystemLevel)); }
                else { microphoneLevel = level; Notify(nameof(MicrophoneLevel)); }
            });
        };
    }

    public Task RefreshDevicesAsync() => Guard(async () =>
    {
        var sourceId = SelectedSource?.Id ?? preferences.SourceId;
        var micId = SelectedMicrophone?.Id ?? preferences.MicrophoneId;
        var inputs = await Task.Run(discoverDevices);
        // Preserve the intended IDs before collection changes clear WPF selections.
        preferences = preferences with { SourceId = sourceId, MicrophoneId = micId };
        Sources.Clear(); foreach (var source in inputs.Item1) Sources.Add(source);
        Sources.Add(new AudioSource("microphone-only", "仅麦克风"));
        Microphones.Clear(); foreach (var device in inputs.Item2) Microphones.Add(device);
        SelectedSource = sourceId is null ? System.Linq.Enumerable.FirstOrDefault(Sources, x => x.Id == "system") : System.Linq.Enumerable.FirstOrDefault(Sources, x => x.Id == sourceId);
        SelectedMicrophone = micId is null ? System.Linq.Enumerable.FirstOrDefault(Microphones, x => x.IsDefault) ?? System.Linq.Enumerable.FirstOrDefault(Microphones) : System.Linq.Enumerable.FirstOrDefault(Microphones, x => x.Id == micId);
        devicesLoaded = true;
        Notify(nameof(SelectedSource)); Notify(nameof(SelectedMicrophone));
    });

    private async Task Guard(Func<Task> action)
    {
        busy = true; error = null; Refresh();
        try { await action(); }
        catch (Exception failure) { error = failure.Message; }
        finally { busy = false; Refresh(); }
    }
    private void Refresh()
    {
        if (!IsActive) { systemLevel = 0; microphoneLevel = 0; attentionMessage = null; Notify(nameof(HasAttention)); Notify(nameof(AttentionMessage)); }
        foreach (var property in new[] { nameof(IsActive), nameof(IsDone), nameof(ShowSetup), nameof(SavedRecordingId), nameof(SourceLabel), nameof(CanConfigure), nameof(StateLabel), nameof(Elapsed), nameof(Error), nameof(MicrophoneAction), nameof(SystemLevel), nameof(MicrophoneLevel) }) Notify(property);
        NewRecording.Refresh();
        Start?.Refresh(); Stop?.Refresh(); Discard?.Refresh(); ToggleMicrophone?.Refresh(); RefreshDevices?.Refresh(); OpenFolder?.Refresh();
    }
    private void Notify([CallerMemberName] string? name = null) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}
