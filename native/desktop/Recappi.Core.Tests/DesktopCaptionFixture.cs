using System.Buffers.Binary;
using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;
using NAudio.Wave;
using Recappi.Core;

internal static class DesktopCaptionFixture
{
    private static string Root(string requested)
    {
        var root = Path.GetFullPath(requested);
        var parent = Path.GetFullPath("build/native-desktop-validation") + Path.DirectorySeparatorChar;
        if (!root.StartsWith(parent, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Use an isolated native validation directory.");
        return root;
    }
    public static async Task PrepareAsync(string requested, int playerId)
    {
        var root = Root(requested);
        if (Directory.Exists(root) || File.Exists(root)) throw new InvalidOperationException("Use a new fixture directory.");
        using var player = Process.GetProcessById(playerId);
        if (player.HasExited || !player.ProcessName.Equals("powershell", StringComparison.OrdinalIgnoreCase) || !AudioDevices.ListSources().Any(source => source.ProcessId == playerId))
            throw new InvalidOperationException("The controlled PowerShell audio player is not active.");
        using var config = JsonDocument.Parse(File.ReadAllText(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config", "recappi", "config.json")));
        var origin = config.RootElement.GetProperty("origin").GetString()!;
        var token = config.RootElement.GetProperty("authToken").GetString()!;
        using var client = new CloudClient(origin, token);
        using var limit = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var session = await client.SessionAsync(limit.Token);
        var id = session.GetProperty("user").GetProperty("id").GetString()!;
        Directory.CreateDirectory(root);
        new PreferencesStore(root).Save(new DesktopPreferences
        {
            OnboardingCompleted = true, Theme = "light", AutoUpload = false, AutoTranscribe = false,
            IncludeMicrophone = false, CaptionsEnabled = true, CaptionLanguage = "en", TranslationLanguage = "zh",
            RecordingSuggestions = false, InactivityReminders = false, SourceId = "process:" + playerId,
            RecordingsRoot = Path.Combine(root, "Recordings")
        });
        new AccountStore(Path.Combine(root, "Account")).Save(new(origin, id, null, token));
        File.WriteAllText(Path.Combine(root, "desktop-caption-fixture.json"), JsonSerializer.Serialize(new
        {
            preparedAt = DateTimeOffset.UtcNow, controlledPlayerId = playerId,
            microphoneEnabled = false, uploadEnabled = false, captionLanguages = new[] { "en", "zh" },
            accountStoredWithDpapi = true
        }));
        Console.WriteLine("Prepared isolated desktop caption fixture with protected existing test account; identity and credentials omitted.");
    }
    private static string ExistingRoot(string requested)
    {
        var root = Root(requested);
        if (!File.Exists(Path.Combine(root, "desktop-caption-fixture.json"))) throw new InvalidOperationException("Not a prepared desktop caption fixture.");
        return root;
    }
    public static void Verify(string requested)
    {
        var root = ExistingRoot(requested);
        var store = new LocalRecordingStore(Path.Combine(root, "Recordings"));
        var recording = store.List().Single();
        var captions = CaptionArchive.Read(store.CaptionPath(recording)).ToArray();
        using var reader = new WaveFileReader(recording.AudioPath);
        var pcm = reader.WaveFormat.Encoding == WaveFormatEncoding.Pcm && reader.WaveFormat.BitsPerSample == 16 && reader.WaveFormat.SampleRate == 48000 && reader.WaveFormat.Channels == 1;
        var buffer = new byte[8192]; var peak = 0; int count;
        while ((count = reader.Read(buffer, 0, buffer.Length)) > 0)
            for (var offset = 0; offset + 1 < count; offset += 2) peak = Math.Max(peak, Math.Abs((int)BinaryPrimitives.ReadInt16LittleEndian(buffer.AsSpan(offset))));
        var source = string.Join(" ", captions.Where(c => c.Stream == "source").Select(c => c.Text));
        var translation = string.Join(" ", captions.Where(c => c.Stream == "translation").Select(c => c.Text));
        var sourceMatchesFixture = source.Contains("review", StringComparison.OrdinalIgnoreCase) && source.Contains("design", StringComparison.OrdinalIgnoreCase);
        var translationContainsChinese = translation.Any(c => c is >= '\u4e00' and <= '\u9fff');
        var passed = recording.State == RecordingState.Done && recording.Error is null && pcm && peak > 100 && recording.DurationMs > 10000 &&
            Math.Abs(reader.TotalTime.TotalMilliseconds - recording.DurationMs) < 1000 && sourceMatchesFixture && translationContainsChinese;
        var report = new
        {
            checkedAt = DateTimeOffset.UtcNow, passed, recordingId = recording.Id, state = recording.State.ToString(),
            durationMs = recording.DurationMs, audioDurationMs = reader.TotalTime.TotalMilliseconds, pcm48kMono16 = pcm, peak,
            audioBytes = new FileInfo(recording.AudioPath).Length,
            audioSha256 = Convert.ToHexString(SHA256.HashData(File.ReadAllBytes(recording.AudioPath))).ToLowerInvariant(),
            sourceFinalCount = captions.Count(c => c.Stream == "source"), translationFinalCount = captions.Count(c => c.Stream == "translation"),
            sourceMatchesFixture, translationContainsChinese, transcriptContentOmitted = true
        };
        File.WriteAllText(Path.Combine(root, "verification.json"), JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
        if (!passed) throw new InvalidOperationException("Desktop audio/caption verification failed; inspect the sanitized report.");
        Console.WriteLine("PASS complete desktop audio file and final source/translation archive contain the controlled speech fixture.");
    }
    public static void ClearAccount(string requested)
    {
        var root = ExistingRoot(requested);
        if (Process.GetProcessesByName("Recappi Mini").Length != 0) throw new InvalidOperationException("Close the test application before clearing the temporary account copy.");
        new AccountStore(Path.Combine(root, "Account")).Clear();
        var preferences = new PreferencesStore(root);
        preferences.Save(preferences.Load() with { CaptionsEnabled = false });
        File.WriteAllText(Path.Combine(root, "credential-cleanup.json"), JsonSerializer.Serialize(new { clearedAt = DateTimeOffset.UtcNow, isolatedCopyCleared = true, originalCliAccountUnchanged = true }));
        Console.WriteLine("Cleared only the fixture's protected account copy; original CLI account retained.");
    }
}
