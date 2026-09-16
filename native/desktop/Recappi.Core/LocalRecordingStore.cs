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
        AtomicJsonFile.Write(path, JsonSerializer.Serialize(recording, Json));
    }

    public IReadOnlyList<LocalRecording> List()
    {
        if (!Directory.Exists(Root)) return [];
        var result = new List<LocalRecording>();
        foreach (var directory in Directory.EnumerateDirectories(Root))
        {
            if (File.Exists(Path.Combine(directory, "library-removed.json"))) continue;
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

    public void RemoveFromLibrary(LocalRecording recording)
    {
        Validate(recording);
        // Read persisted state instead of trusting a selection captured before a dialog.
        var current = JsonSerializer.Deserialize<LocalRecording>(File.ReadAllText(Path.Combine(recording.Directory, "desktop-session.json")), Json)
            ?? throw new InvalidDataException("录音记录无法读取。");
        Validate(current);
        if (current.Id != recording.Id || current.State is not (RecordingState.Done or RecordingState.Error))
            throw new InvalidOperationException("录音尚未结束，无法从库中移除。");
        // A separate marker survives later metadata saves. Audio, captions and upload
        // journals remain intact; removing a library entry does not cancel remote work.
        AtomicJsonFile.Write(Path.Combine(recording.Directory, "library-removed.json"), "{}");
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

    /// <summary>Run once before creating an engine, after obtaining application single-instance ownership.</summary>
    public int RecoverInterruptedRecordings()
    {
        var recovered = 0;
        foreach (var recording in List().Where(x => x.State is RecordingState.Starting or RecordingState.Recording or RecordingState.Stopping))
        {
            FileStream? audio = null;
            try
            {
                long duration = 0;
                var message = "上次录音意外中断；已保留可恢复的音频，请播放检查。";
                try
                {
                    if ((File.GetAttributes(recording.AudioPath) & FileAttributes.ReparsePoint) != 0) continue;
                    audio = new FileStream(recording.AudioPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
                    duration = PcmWaveWriter.RecoverInterrupted(audio);
                    if (duration == 0) message = "上次录音意外中断，未找到完整音频样本。已有文件已保留。";
                }
                catch (FileNotFoundException) { message = "上次录音意外中断，未找到音频文件。"; }
                catch (InvalidDataException) { message = "上次录音意外中断，音频格式不完整。原文件已保留，请打开文件位置检查。"; }
                // Keep the exclusive audio handle until metadata commits. Busy or inaccessible
                // files remain untouched and can be retried on a later launch.
                Save(recording with { State = RecordingState.Error, DurationMs = duration, Error = message });
                recovered++;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            finally { audio?.Dispose(); }
        }
        return recovered;
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
