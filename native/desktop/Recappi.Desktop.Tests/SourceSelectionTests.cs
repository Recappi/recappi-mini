using System.IO;
using System.Windows.Threading;
using Recappi.Core;
using Recappi.Desktop;

internal static class SourceSelectionTests
{
    public static async Task RunAsync(string root, Dispatcher dispatcher)
    {
        var store = new LocalRecordingStore(Path.Combine(root, "selection"));
        var captures = 0;
        await using var engine = new RecordingEngine(store, _ => { captures++; return []; });
        IReadOnlyList<AudioSource> sources = [new("system", "All apps"), new("process:123", "Chosen app", 123)];
        IReadOnlyList<MicrophoneDevice> microphones = [new("chosen-mic", "Chosen microphone", true)];
        var model = new RecorderViewModel(engine, store, dispatcher, () => (sources, microphones));
        model.ApplyPreferences(new() { SourceId = "process:123", MicrophoneId = "chosen-mic" });
        await model.RefreshDevicesAsync();
        if (!model.Start.CanExecute(null) || model.SelectedSource?.ProcessId != 123) throw new Exception("Available saved source was not restored.");
        sources = [new("system", "All apps")];
        microphones = [new("different-mic", "Different default", true)];
        await model.RefreshDevicesAsync();
        model.Start.Execute(null);
        if (model.SelectedSource is not null || model.SelectedMicrophone is not null || model.Start.CanExecute(null) || captures != 0 || model.Preferences.SourceId != "process:123")
            throw new Exception("Missing selected devices silently fell back or started capture.");
        await model.RefreshDevicesAsync();
        if (model.SelectedSource is not null || model.Preferences.MicrophoneId != "chosen-mic") throw new Exception("Repeated refresh forgot unavailable selections.");
        model.SelectedSource = model.Sources.Single(x => x.Id == "system");
        if (model.Start.CanExecute(null)) throw new Exception("Missing enabled microphone did not block capture.");
        model.Microphone = false;
        if (!model.Start.CanExecute(null)) throw new Exception("Explicit system-only choice remained blocked.");
        model.SelectedSource = model.Sources.Single(x => x.Id == "microphone-only");
        if (model.Start.CanExecute(null)) throw new Exception("Microphone-only with microphone off could start.");
        sources = [new("system", "All apps"), new("process:123", "Chosen app", 123)];
        microphones = [new("chosen-mic", "Chosen microphone", true)];
        model.SelectedSource = null; model.ApplyPreferences(new() { SourceId = "process:123", MicrophoneId = "chosen-mic" });
        await model.RefreshDevicesAsync();
        if (!model.Start.CanExecute(null) || model.SelectedSource?.ProcessId != 123 || model.SelectedMicrophone?.Id != "chosen-mic") throw new Exception("Returning devices could not be restored.");
        Console.WriteLine("PASS missing source/microphone never falls back; repeated refresh, explicit recovery and microphone-only validation.");
        await MutedLevelAsync(root, dispatcher);
    }

    private static async Task MutedLevelAsync(string root, Dispatcher dispatcher)
    {
        var store = new LocalRecordingStore(Path.Combine(root, "muted-level"));
        await using var engine = new RecordingEngine(store, _ => [new MeterInput("system", 0), new MeterInput("microphone", .5f)]);
        var model = new RecorderViewModel(engine, store, dispatcher);
        await engine.StartAsync(new("Mute meter"));
        for (var attempt = 0; attempt < 100 && model.MicrophoneLevel == 0; attempt++) await Task.Delay(20);
        if (model.MicrophoneLevel == 0) throw new Exception("Active microphone did not update its meter.");
        model.ToggleMicrophone.Execute(null);
        for (var attempt = 0; attempt < 100 && (!model.ToggleMicrophone.CanExecute(null) || engine.MicrophoneEnabled); attempt++) await Task.Delay(20);
        if (engine.MicrophoneEnabled || model.MicrophoneLevel != 0 || model.MicrophoneAction != "开启麦克风" || !model.IsActive)
            throw new Exception("Muted microphone retained a nonzero meter or changed recording state.");
        await Task.Delay(150);
        if (model.MicrophoneLevel != 0) throw new Exception("Queued microphone level restored a muted meter.");
        await engine.StopAsync();
        Console.WriteLine("PASS microphone mute immediately clears meter and ignores stale queued level updates.");
    }

    private sealed class MeterInput(string input, float sample) : IAudioInput
    {
        public string Input => input;
        public Exception? Error => null;
        public void Start() { }
        public void Read(float[] destination) => Array.Fill(destination, sample);
        public void Stop() { }
        public void Dispose() { }
    }
}
