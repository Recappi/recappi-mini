using System.Diagnostics;
using System.Text.Json;
using NAudio.Wave;
using Recappi.Core;

internal static class DesktopCloudFixture
{
    private sealed record Fixture(string LocalId, string Title);
    private static string Root(string requested)
    {
        var root = Path.GetFullPath(requested);
        var parent = Path.GetFullPath("build/native-desktop-validation") + Path.DirectorySeparatorChar;
        if (!root.StartsWith(parent, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Use an isolated validation directory.");
        return root;
    }

    public static async Task PrepareAsync(string requested, string audioPath)
    {
        var root = Root(requested);
        if (Directory.Exists(root) || File.Exists(root)) throw new InvalidOperationException("Use a new fixture directory.");
        using var audio = new WaveFileReader(audioPath);
        using var config = JsonDocument.Parse(File.ReadAllText(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config", "recappi", "config.json")));
        var origin = config.RootElement.GetProperty("origin").GetString()!;
        var token = config.RootElement.GetProperty("authToken").GetString()!;
        using var client = new CloudClient(origin, token);
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var session = await client.SessionAsync(timeout.Token);
        var id = session.GetProperty("user").GetProperty("id").GetString()!;
        Directory.CreateDirectory(root);
        var store = new LocalRecordingStore(Path.Combine(root, "Recordings"));
        var recording = store.Create("Native desktop cloud validation " + Guid.NewGuid().ToString("N"), new("en", "Synthetic speech for native desktop validation."))
            with { State = RecordingState.Done, DurationMs = (long)audio.TotalTime.TotalMilliseconds };
        File.Copy(audioPath, recording.AudioPath);
        store.Save(recording);
        // Publish the cleanup marker before creating the temporary credential copy.
        File.WriteAllText(Path.Combine(root, "desktop-cloud-fixture.json"), JsonSerializer.Serialize(new Fixture(recording.Id, recording.Title)));
        new PreferencesStore(root).Save(new DesktopPreferences
        {
            OnboardingCompleted = true, Theme = "light", AutoUpload = false, AutoTranscribe = false,
            IncludeMicrophone = false, CaptionsEnabled = false, RecordingSuggestions = false,
            InactivityReminders = false, SourceId = "system", RecordingsRoot = store.Root
        });
        new AccountStore(Path.Combine(root, "Account")).Save(new(origin, id, null, token));
        Console.WriteLine("Prepared isolated local speech and protected test account. No upload has started.");
    }

    public static async Task ClearAsync(string requested)
    {
        if (Process.GetProcessesByName("Recappi Mini").Length != 0) throw new InvalidOperationException("Close the test application before cleanup.");
        var root = Root(requested);
        var fixture = JsonSerializer.Deserialize<Fixture>(File.ReadAllText(Path.Combine(root, "desktop-cloud-fixture.json")))
            ?? throw new InvalidDataException("Missing fixture marker.");
        var accountStore = new AccountStore(Path.Combine(root, "Account"));
        var account = accountStore.Load() ?? throw new InvalidOperationException("Fixture account is unavailable.");
        await using var processing = new CloudProcessing(Path.Combine(root, "Processing"));
        var entries = processing.List(account.Partition);
        if (entries.Any(x => x.LocalId != fixture.LocalId || x.Title != fixture.Title)) throw new InvalidOperationException("Unexpected processing entry; cleanup refused.");
        var entry = entries.SingleOrDefault();
        string? remoteId = entry?.Ticket?.Id;
        if (remoteId is not null)
        {
            using var client = new CloudClient(account.Origin, account.Token);
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(30));
            await client.DeleteAsync(remoteId, timeout.Token);
            new CloudContentCache(Path.Combine(root, "CloudContent")).Delete(account.Partition, remoteId);
            // Earlier desktop builds used the shared cache even with a data-dir override.
            var legacyCache = new CloudContentCache(CloudContentCache.DefaultRoot);
            if (legacyCache.Load(account.Partition, remoteId)?.Recording.Title == fixture.Title)
                legacyCache.Delete(account.Partition, remoteId);
            await processing.ForgetRemoteAsync(account.Partition, remoteId);
        }
        accountStore.Clear();
        File.WriteAllText(Path.Combine(root, "cleanup.json"), JsonSerializer.Serialize(new
        {
            clearedAt = DateTimeOffset.UtcNow, remoteId, remoteDeleted = remoteId is not null,
            isolatedCredentialCleared = true, localAudioRetained = true
        }));
        Console.WriteLine("Cleaned only the fixture's associated cloud recording and protected account copy; local audio retained.");
    }
}
