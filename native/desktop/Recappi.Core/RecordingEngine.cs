using System.Diagnostics;
using System.Threading.Channels;
using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace Recappi.Core;

public interface IAudioInput : IDisposable
{
    string Input { get; }
    Exception? Error { get; }
    void Start();
    void Read(float[] destination);
    void Stop();
}

internal sealed class NativeAudioInput(IWaveIn capture, string label) : IAudioInput
{
    private readonly CaptureInput input = new(capture, label);
    public string Input => input.Input;
    public Exception? Error => input.Error;
    public void Start() => input.Start();
    public void Read(float[] destination) => input.Read(destination);
    public void Stop() => input.Stop();
    public void Dispose() => input.Dispose();
}

/// <summary>Owns the recording independently of UI windows. Device/file work runs on one pump.</summary>
public sealed class RecordingEngine : IAsyncDisposable
{
    private sealed record MicrophoneChange(bool Enabled, TaskCompletionSource Completion);
    private readonly LocalRecordingStore store;
    private readonly Func<RecordingOptions, IReadOnlyList<IAudioInput>> createInputs;
    private readonly Func<string?, IAudioInput> createMicrophone;
    private readonly SemaphoreSlim gate = new(1, 1);
    private Channel<MicrophoneChange> changes = Channel.CreateBounded<MicrophoneChange>(4);
    private CancellationTokenSource? stop;
    private Task? pump;
    private volatile RecordingSnapshot snapshot = new(RecordingState.Idle, null);
    private bool microphoneEnabled;
    private bool disposed;
    public RecordingSnapshot Snapshot => snapshot;
    public bool MicrophoneEnabled => Volatile.Read(ref microphoneEnabled);
    public event Action<RecordingSnapshot>? Changed;
    public event Action<AudioLevel>? Level;
    // Subscribers must enqueue bounded work; they cannot own or stop this pump.
    public event Action<float[]>? Audio;

    public RecordingEngine(LocalRecordingStore store,
        Func<RecordingOptions, IReadOnlyList<IAudioInput>>? createInputs = null,
        Func<string?, IAudioInput>? createMicrophone = null)
    {
        this.store = store;
        this.createInputs = createInputs ?? CreateNativeInputs;
        this.createMicrophone = createMicrophone ?? CreateMicrophone;
    }

    public async Task StartAsync(RecordingOptions options)
    {
        await gate.WaitAsync();
        try
        {
            ObjectDisposedException.ThrowIf(disposed, this);
            if (pump is { IsCompleted: false }) throw new InvalidOperationException("A recording is already active.");
            if (!options.IncludeSystem && !options.IncludeMicrophone) throw new ArgumentException("Select at least one audio input.");
            if (options.ProcessId.HasValue && !options.IncludeSystem) throw new ArgumentException("Application capture requires system audio.");
            stop?.Dispose();
            stop = new CancellationTokenSource();
            changes = Channel.CreateBounded<MicrophoneChange>(4);
            var recording = store.Create(options.Title, options.Processing);
            Publish(new(RecordingState.Starting, recording));
            var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            pump = Task.Run(() => RunAsync(options, recording, ready, stop.Token));
            await ready.Task;
        }
        finally { gate.Release(); }
    }

    public async Task<LocalRecording?> StopAsync()
    {
        await gate.WaitAsync();
        try
        {
            if (pump is { IsCompleted: false })
            {
                Publish(snapshot with { State = RecordingState.Stopping });
                stop!.Cancel();
                await pump;
            }
            return snapshot.Recording;
        }
        finally { gate.Release(); }
    }

    public async Task SetMicrophoneEnabledAsync(bool enabled)
    {
        await gate.WaitAsync();
        try
        {
            if (snapshot.State != RecordingState.Recording) throw new InvalidOperationException("No active recording.");
            var completion = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            if (!changes.Writer.TryWrite(new(enabled, completion))) throw new InvalidOperationException("Microphone change is already pending.");
            await Task.WhenAny(completion.Task, pump!);
            if (!completion.Task.IsCompleted) throw new InvalidOperationException("Recording stopped before the microphone could change.");
            await completion.Task;
        }
        finally { gate.Release(); }
    }

    public async Task DiscardAsync()
    {
        await gate.WaitAsync();
        try
        {
            if (pump is { IsCompleted: false }) { stop!.Cancel(); await pump; }
            if (snapshot.State == RecordingState.Error) throw new InvalidOperationException("Partial audio is retained after a recording failure.");
            if (snapshot.Recording is { } recording) store.Discard(recording);
            Publish(new(RecordingState.Idle, null));
        }
        finally { gate.Release(); }
    }

    private async Task RunAsync(RecordingOptions options, LocalRecording recording, TaskCompletionSource ready, CancellationToken token)
    {
        var inputs = new List<IAudioInput>();
        PcmWaveWriter? writer = null;
        Exception? failure = null;
        try
        {
            writer = new PcmWaveWriter(recording.AudioPath);
            inputs.AddRange(createInputs(options));
            foreach (var input in inputs) input.Start();
            Volatile.Write(ref microphoneEnabled, options.IncludeMicrophone);
            var clock = Stopwatch.StartNew();
            var stopSignal = Task.Delay(Timeout.Infinite, token);
            long written = 0;
            long publishedSecond = -1;
            Publish(new(RecordingState.Recording, recording with { State = RecordingState.Recording }));
            store.Save(snapshot.Recording!);
            ready.TrySetResult();
            while (true)
            {
                await Task.WhenAny(stopSignal, Task.Delay(50));
                while (changes.Reader.TryRead(out var change))
                {
                    try
                    {
                        if (change.Enabled != MicrophoneEnabled)
                        {
                            if (change.Enabled)
                            {
                                var microphone = createMicrophone(options.MicrophoneId);
                                try { microphone.Start(); inputs.Add(microphone); }
                                catch { microphone.Dispose(); throw; }
                            }
                            else
                            {
                                var microphone = inputs.FirstOrDefault(x => x.Input == "microphone");
                                if (microphone is not null)
                                {
                                    inputs.Remove(microphone);
                                    Volatile.Write(ref microphoneEnabled, false);
                                    Notify(Level, new AudioLevel("microphone", -120));
                                    microphone.Dispose();
                                }
                            }
                            Volatile.Write(ref microphoneEnabled, change.Enabled);
                        }
                        change.Completion.TrySetResult();
                    }
                    catch (Exception error) { change.Completion.TrySetException(error); }
                }
                var finishing = token.IsCancellationRequested;
                var elapsed = clock.Elapsed.TotalSeconds;
                if (finishing) foreach (var input in inputs) input.Stop();
                var target = (long)(Math.Max(0, elapsed - (finishing ? 0 : 0.15)) * PcmWaveWriter.SampleRate);
                while (written < target)
                {
                    var count = (int)Math.Min(4800, target - written);
                    var mixed = new float[count];
                    foreach (var input in inputs)
                    {
                        if (input.Error is { } error) throw error;
                        var samples = new float[count];
                        input.Read(samples);
                        double squares = 0;
                        for (var i = 0; i < count; i++) { mixed[i] += samples[i]; squares += (double)samples[i] * samples[i]; }
                        Notify(Level, new AudioLevel(input.Input, squares > 0 ? Math.Max(-120, 10 * Math.Log10(squares / count)) : -120));
                    }
                    for (var i = 0; i < count; i++) mixed[i] = Math.Clamp(mixed[i] / Math.Max(1, inputs.Count), -1f, 1f);
                    writer.Append(mixed);
                    Notify(Audio, mixed);
                    written += count;
                }
                if (writer.DurationMs / 1000 != publishedSecond)
                {
                    publishedSecond = writer.DurationMs / 1000;
                    recording = recording with { DurationMs = writer.DurationMs, State = finishing ? RecordingState.Stopping : RecordingState.Recording };
                    Publish(new(recording.State, recording));
                    store.Save(recording);
                }
                if (finishing) break;
            }
        }
        catch (Exception error) { failure = error; }
        finally
        {
            Volatile.Write(ref microphoneEnabled, false);
            Notify(Level, new AudioLevel("microphone", -120));
            Notify(Level, new AudioLevel("system", -120));
            foreach (var input in inputs)
            {
                try { input.Dispose(); }
                catch (Exception error) { failure ??= error; }
            }
            try { writer?.Dispose(); }
            catch (Exception error) { failure ??= error; }
            if (writer is { AudioBytes: 0 }) failure ??= new IOException("No audio samples received.");
            recording = recording with { DurationMs = writer?.DurationMs ?? 0, State = failure is null ? RecordingState.Done : RecordingState.Error, Error = failure?.Message };
            try { store.Save(recording); }
            catch (Exception error) { failure ??= error; recording = recording with { State = RecordingState.Error, Error = failure.Message }; }
            Publish(new(recording.State, recording, recording.Error));
            if (failure is not null) ready.TrySetException(failure);
            else ready.TrySetResult();
            while (changes.Reader.TryRead(out var change)) change.Completion.TrySetException(new InvalidOperationException("Recording stopped."));
        }
    }

    private void Publish(RecordingSnapshot value) { snapshot = value; Notify(Changed, value); }
    private static void Notify<T>(Action<T>? handlers, T value)
    {
        if (handlers is null) return;
        foreach (Action<T> handler in handlers.GetInvocationList())
            try { handler(value); } catch { /* UI or caption observers cannot lose local audio. */ }
    }

    private static IReadOnlyList<IAudioInput> CreateNativeInputs(RecordingOptions options)
    {
        var inputs = new List<IAudioInput>();
        try
        {
            if (options.IncludeSystem) inputs.Add(new NativeAudioInput(options.ProcessId is { } pid ? new ProcessLoopbackCapture(pid, TimeSpan.FromSeconds(15)) : new WasapiLoopbackCapture(), "system"));
            if (options.IncludeMicrophone) inputs.Add(CreateMicrophone(options.MicrophoneId));
            return inputs;
        }
        catch { foreach (var input in inputs) input.Dispose(); throw; }
    }

    private static IAudioInput CreateMicrophone(string? id)
    {
        using var enumerator = new MMDeviceEnumerator();
        using var device = id is null or "default" ? enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console) : enumerator.GetDevice(id);
        if (device.State != DeviceState.Active || device.DataFlow != DataFlow.Capture) throw new IOException("Selected microphone is unavailable.");
        return new NativeAudioInput(new WasapiCapture(device), "microphone");
    }

    public async ValueTask DisposeAsync()
    {
        await gate.WaitAsync();
        try
        {
            if (disposed) return;
            disposed = true;
            stop?.Cancel();
            if (pump is not null) await pump;
            stop?.Dispose();
        }
        finally { gate.Release(); }
    }
}
