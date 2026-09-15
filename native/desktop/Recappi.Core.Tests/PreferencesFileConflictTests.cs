using Recappi.Core;

internal static class PreferencesFileConflictTests
{
    public static Task RunAsync(string root)
    {
        var directory = Path.Combine(root, "settings-file-conflict");
        var store = new PreferencesStore(directory);
        store.Save(new() { Theme = "light" });
        var path = Path.Combine(directory, "settings.json");
        using (var held = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var release = new Thread(() => { Thread.Sleep(50); held.Dispose(); });
            release.Start();
            try { store.Save(store.Load() with { Theme = "dark" }); }
            finally { release.Join(); }
        }
        if (store.Load().Theme != "dark") throw new Exception("Short replacement conflict lost settings.");
        var previous = File.ReadAllBytes(path);
        using (var held = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var rejected = false;
            try { store.Save(store.Load() with { Theme = "light" }); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { rejected = true; }
            if (!rejected) throw new Exception("Persistent replacement conflict was reported as saved.");
        }
        if (!previous.SequenceEqual(File.ReadAllBytes(path)) || Directory.GetFiles(directory, "*.tmp").Length != 0)
            throw new Exception("Failed save changed the original or left temporary files.");
        store.Save(store.Load() with { Theme = "light" });
        if (store.Load().Theme != "light") throw new Exception("Explicit save after conflict did not recover.");
        var recordings = new LocalRecordingStore(Path.Combine(directory, "Recordings"));
        var recording = recordings.Create("Original metadata");
        var metadataPath = Path.Combine(recording.Directory, "desktop-session.json");
        using (var held = new FileStream(metadataPath, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var release = new Thread(() => { Thread.Sleep(50); held.Dispose(); });
            release.Start();
            try { recordings.Save(recording with { Title = "Updated metadata" }); }
            finally { release.Join(); }
        }
        var metadata = File.ReadAllBytes(metadataPath);
        if (recordings.List().Single().Title != "Updated metadata") throw new Exception("Brief metadata conflict lost update.");
        using (var held = new FileStream(metadataPath, FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var rejected = false;
            try { recordings.Save(recording); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { rejected = true; }
            if (!rejected) throw new Exception("Persistent metadata conflict reported success.");
        }
        if (!metadata.SequenceEqual(File.ReadAllBytes(metadataPath)) || Directory.EnumerateFiles(recording.Directory, "*.tmp").Any())
            throw new Exception("Persistent metadata conflict destroyed prior data or leaked temporary files.");
        return Task.CompletedTask;
    }
}
