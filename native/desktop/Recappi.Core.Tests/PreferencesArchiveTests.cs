using Recappi.Core;

internal static class PreferencesArchiveTests
{
    public static async Task RunAsync(string root)
    {
        var store = new PreferencesStore(Path.Combine(root, "preferences"));
        var preferences = new DesktopPreferences { RecordingsRoot = Path.Combine(root, "library"), AutoUpload = false, AutoTranscribe = false, CaptionsEnabled = true, CaptionLanguage = "zh-CN", TranslationLanguage = "en", TranscriptionLanguage = "zh", Scene = "lecture", ExtraContext = "Recappi terminology" };
        store.Save(preferences);
        if (new PreferencesStore(Path.Combine(root, "preferences")).Load() != preferences) throw new Exception("Preferences did not survive restart.");
        var failed = false;
        try { store.Save(preferences with { ExtraContext = new string('x', 4001) }); } catch (ArgumentException) { failed = true; }
        if (!failed || store.Load() != preferences) throw new Exception("Invalid preferences replaced valid settings.");
        var recordings = new LocalRecordingStore(preferences.RecordingsRoot);
        var recording = recordings.Create("Archive", preferences.Processing);
        store.Save(preferences with { TranscriptionLanguage = "en", ExtraContext = "Different" });
        var snapshot = recordings.List().Single().Processing;
        if (snapshot?.Language != "zh" || snapshot.Transcribe || !snapshot.Prompt!.Contains("Recappi terminology")) throw new Exception("Recording processing settings changed with global settings.");
        var path = recordings.CaptionPath(recording);
        await using (var archive = new CaptionArchive(path))
        {
            archive.Append(new("partial", "source", "unfinished", false));
            for (var batch = 0; batch < 7; batch++)
            {
                for (var i = 0; i < 32; i++) archive.Append(new((batch * 32 + i).ToString(), i % 2 == 0 ? "source" : "translation", "完整字幕 " + i, true));
                using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(5));
                while (CaptionArchive.Read(path).Count() < (batch + 1) * 32) await Task.Delay(10, deadline.Token);
            }
            if (archive.Error is not null) throw new Exception("Archive unexpectedly failed.");
        }
        File.AppendAllText(path, "{incomplete");
        if (CaptionArchive.Read(path).Count() != 224 || CaptionArchive.Read(path).Any(x => x.Text == "unfinished")) throw new Exception("Archive lost full history or could not recover partial final line.");
        recordings.Discard(recording);
        if (File.Exists(path) || Directory.Exists(recording.Directory)) throw new Exception("Discard retained caption archive.");
    }
}
