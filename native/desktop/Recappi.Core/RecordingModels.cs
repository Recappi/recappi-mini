using System.Text.Json;

namespace Recappi.Core;

public enum RecordingState { Idle, Starting, Recording, Stopping, Done, Error }
public sealed record AudioSource(string Id, string Label, int? ProcessId = null);
public sealed record MicrophoneDevice(string Id, string Label, bool IsDefault = false);
public sealed record RecordingOptions(string Title, bool IncludeSystem = true, bool IncludeMicrophone = true,
    uint? ProcessId = null, string? MicrophoneId = null, ProcessingOptions? Processing = null);
public sealed record LocalRecording(string Id, string Title, string Directory, DateTimeOffset StartedAt,
    long DurationMs, RecordingState State, string? Error = null, ProcessingOptions? Processing = null)
{
    public string AudioPath => Path.Combine(Directory, "audio.wav");
}
public sealed record RecordingSnapshot(RecordingState State, LocalRecording? Recording, string? Error = null);
public sealed record AudioLevel(string Input, double RmsDb);

public static class AudioDevices
{
    public static IReadOnlyList<AudioSource> ListSources()
    {
        var data = JsonSerializer.SerializeToElement(InputCatalog.Sources());
        return data.GetProperty("sources").EnumerateArray().Select(s => new AudioSource(
            s.GetProperty("id").GetString()!, s.GetProperty("label").GetString()!,
            s.TryGetProperty("processId", out var pid) ? pid.GetInt32() : null)).ToArray();
    }
    public static IReadOnlyList<MicrophoneDevice> ListMicrophones()
    {
        var data = JsonSerializer.SerializeToElement(InputCatalog.Microphones());
        return data.GetProperty("microphones").EnumerateArray().Select(s => new MicrophoneDevice(
            s.GetProperty("id").GetString()!, s.GetProperty("label").GetString()!, s.GetProperty("isDefault").GetBoolean())).ToArray();
    }
}
