using System.Text.Json;
using Recappi.Core;

internal static class PreferencesRecoveryTests
{
    public static Task RunAsync(string root)
    {
        var directory = Path.Combine(root, "preferences-recovery");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "settings.json");
        var store = new PreferencesStore(directory);
        var missing = store.LoadForStartup();
        if (missing.RecoveryRequired || missing.Preferences != new DesktopPreferences() || File.Exists(path))
            throw new Exception("Missing settings did not retain first-run defaults without creating a file.");
        File.WriteAllText(path, "null");
        var rejected = false;
        try { store.Load(); }
        catch (JsonException) { rejected = true; }
        if (!rejected) throw new Exception("A null settings document silently enabled fresh-install defaults.");
        foreach (var contents in new[] { "null", "{broken", "[]", "{\"theme\":\"unsupported\"}", "{\"recordingsRoot\":\"relative\"}" })
        {
            File.WriteAllText(path, contents);
            var original = File.ReadAllBytes(path);
            RequireRecovery(store.LoadForStartup());
            if (!original.SequenceEqual(File.ReadAllBytes(path))) throw new Exception("Loading damaged settings rewrote the original file.");
        }
        var chosen = new DesktopPreferences { AutoUpload = true, AutoTranscribe = true, CaptionsEnabled = true, IncludeMicrophone = true, RecordingSuggestions = true, Theme = "dark" };
        store.Save(chosen);
        var valid = File.ReadAllBytes(path);
        using (var held = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
            RequireRecovery(store.LoadForStartup());
        if (!valid.SequenceEqual(File.ReadAllBytes(path))) throw new Exception("Read conflict changed existing settings.");
        var restored = store.LoadForStartup();
        if (restored.RecoveryRequired || restored.Preferences != chosen) throw new Exception("Releasing the settings lock did not recover the user's settings.");
        File.WriteAllText(path, "{broken");
        var recovered = store.LoadForStartup().Preferences;
        store.Save(recovered with { Theme = "light" });
        var edited = store.LoadForStartup();
        if (edited.RecoveryRequired || edited.Preferences.Theme != "light" || edited.Preferences.AutoUpload || edited.Preferences.IncludeMicrophone)
            throw new Exception("An unrelated explicit edit re-enabled capture or upload after recovery.");
        store.Save(edited.Preferences with { AutoUpload = true, IncludeMicrophone = true });
        if (!store.Load().AutoUpload || !store.Load().IncludeMicrophone) throw new Exception("Recovery prevented explicit opt-in after saving.");
        var blockedDirectory = Path.Combine(root, "settings-is-directory");
        Directory.CreateDirectory(Path.Combine(blockedDirectory, "settings.json"));
        RequireRecovery(new PreferencesStore(blockedDirectory).LoadForStartup());
        if (!Directory.Exists(Path.Combine(blockedDirectory, "settings.json"))) throw new Exception("Recovery replaced a conflicting directory.");
        return Task.CompletedTask;
    }

    private static void RequireRecovery((DesktopPreferences Preferences, bool RecoveryRequired) result)
    {
        var value = result.Preferences;
        if (!result.RecoveryRequired || value.AutoUpload || value.AutoTranscribe || value.CaptionsEnabled || value.IncludeMicrophone || value.RecordingSuggestions)
            throw new Exception("Unreadable settings enabled microphone, cloud processing, captions or recording suggestions.");
        value.Validate();
    }
}
