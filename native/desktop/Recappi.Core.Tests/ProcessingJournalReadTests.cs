using System.Net;
using System.Text;
using System.Text.Json;
using Recappi.Core;

internal static class ProcessingJournalReadTests
{
    public static async Task RunAsync(string root)
    {
        var store = new LocalRecordingStore(Path.Combine(root, "journal-read-audio"));
        var recording = store.Create("Journal recovery") with { State = RecordingState.Done };
        File.WriteAllBytes(recording.AudioPath, [1, 2, 3]);
        var account = new CloudAccount("https://recappi.test", "journal-reader", null, "fixture-token");
        var stateRoot = Path.Combine(root, "journal-read-state");
        var path = Path.Combine(stateRoot, account.Partition, recording.Id + ".json");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var requests = 0;
        await using var processing = new CloudProcessing(stateRoot, user => new(user.Origin, user.Token, new Handler(() => requests++)));
        async Task MustReject()
        {
            var before = File.ReadAllBytes(path);
            var rejected = false;
            try { await processing.StartAsync(recording, account, new()); }
            catch (Exception error) when (error is IOException or InvalidDataException or JsonException or UnauthorizedAccessException) { rejected = true; }
            if (!rejected || requests != 0 || !before.SequenceEqual(File.ReadAllBytes(path)))
                throw new Exception("Unreadable or invalid journal was treated as new cloud work.");
        }
        foreach (var contents in new[] { "{broken", "null", "{}", "{\"localId\":\"wrong\",\"partition\":\"wrong\",\"stage\":\"Completed\"}" })
        {
            File.WriteAllText(path, contents);
            await MustReject();
        }
        // A valid complete journal must also remain authoritative while another handle blocks reading.
        var valid = JsonSerializer.Serialize(new ProcessingEntry(recording.Id, account.Partition, recording.Title,
            ProcessingStage.Completed, UploadCompleted: true, TranscriptionAttempted: true, JobId: "job-done"),
            new JsonSerializerOptions(JsonSerializerDefaults.Web));
        File.WriteAllText(path, valid);
        using (var held = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            var rejected = false;
            try { await processing.StartAsync(recording, account, new()); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { rejected = true; }
            if (!rejected || requests != 0) throw new Exception("Locked journal triggered cloud work.");
        }
        if (File.ReadAllText(path) != valid) throw new Exception("Locked journal changed.");
        var resumed = await processing.StartAsync(recording, account, new());
        if (resumed.Stage != ProcessingStage.Completed || requests != 0) throw new Exception("Unlocked completed journal restarted cloud work.");
    }

    private sealed class Handler(Action observe) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation)
        {
            observe();
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.BadRequest) { Content = new StringContent("{}", Encoding.UTF8, "application/json") });
        }
    }
}
