using System.Text.Json;
using System.Text.Json.Serialization;

namespace Recappi.Core;

public sealed class LocalRecordingStore(string root)
{
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true, Converters = { new JsonStringEnumConverter() } };
    public string Root { get; } = Path.GetFullPath(root);
    public static string DefaultRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Recappi Mini", "Recordings");

    public LocalRecording Create(string title, ProcessingOptions? processing = null)
    {
        var id = Guid.NewGuid().ToString("N");
        var directory = Path.Combine(Root, id);
        Directory.CreateDirectory(directory);
        var recording = new LocalRecording(id, string.IsNullOrWhiteSpace(title) ? "Untitled recording" : title.Trim(), directory, DateTimeOffset.Now, 0, RecordingState.Starting, Processing: processing);
        Save(recording);
        return recording;
    }

    public void Save(LocalRecording recording)
    {
        Validate(recording);
        var path = Path.Combine(recording.Directory, "desktop-session.json");
        var temporary = path + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(recording, Json));
        File.Move(temporary, path, true);
    }

    public IReadOnlyList<LocalRecording> List()
    {
        if (!Directory.Exists(Root)) return [];
        var result = new List<LocalRecording>();
        foreach (var directory in Directory.EnumerateDirectories(Root))
        {
            var path = Path.Combine(directory, "desktop-session.json");
            if (!File.Exists(path)) continue;
            try
            {
                var recording = JsonSerializer.Deserialize<LocalRecording>(File.ReadAllText(path), Json);
                if (recording is null) continue;
                Validate(recording);
                if (!string.Equals(Path.GetFullPath(directory), Path.GetFullPath(recording.Directory), StringComparison.OrdinalIgnoreCase)) continue;
                result.Add(recording);
            }
            catch (Exception error) when (error is IOException or JsonException or ArgumentException or UnauthorizedAccessException) { /* A damaged entry must not hide intact recordings. */ }
        }
        return result.OrderByDescending(x => x.StartedAt).ToArray();
    }

    public void Discard(LocalRecording recording)
    {
        Validate(recording);
        // Only files created by this store are removed. Never recursively delete a user-supplied directory.
        File.Delete(recording.AudioPath);
        File.Delete(Path.Combine(recording.Directory, "desktop-session.json"));
        File.Delete(CaptionPath(recording));
        if (!Directory.EnumerateFileSystemEntries(recording.Directory).Any()) Directory.Delete(recording.Directory);
    }

    private void Validate(LocalRecording recording)
    {
        if (!Guid.TryParseExact(recording.Id, "N", out _)) throw new ArgumentException("Invalid local recording ID.");
        var expected = Path.Combine(Root, recording.Id);
        if (!string.Equals(expected, Path.GetFullPath(recording.Directory), StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("Recording path is outside the local library.");
        if ((File.GetAttributes(recording.Directory) & FileAttributes.ReparsePoint) != 0) throw new IOException("Recording directories cannot be links.");
    }
    public string CaptionPath(LocalRecording recording) { Validate(recording); return Path.Combine(recording.Directory, "live-captions.jsonl"); }
}
