using System.Net;
using System.Text;
using Recappi.Core;

internal static class ProcessingTests
{
    public static async Task RunAsync(string root, bool holdJournal = false)
    {
        var store = new LocalRecordingStore(Path.Combine(root, "processing-audio"));
        var recording = store.Create("Upload retry") with { State = RecordingState.Done, DurationMs = 1000 };
        await File.WriteAllBytesAsync(recording.AudioPath, new byte[] { 1, 2, 3, 4, 5, 6 });
        store.Save(recording);
        var account = new CloudAccount("https://recappi.test", "processing-user", null, "processing-secret-fixture");
        var creates = 0;
        var failPart = true;
        var transcribes = 0;
        CloudClient Client(CloudAccount user) => new(user.Origin, user.Token, new Handler(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path == "/api/recordings") { creates++; return Json("{\"id\":\"upload-1\",\"partSize\":4,\"maxPartBytes\":8}"); }
            if (path == "/api/recordings/upload-1") return Json("{\"id\":\"upload-1\",\"status\":\"uploading\"}");
            if (path.Contains("/parts/"))
            {
                if (failPart) { failPart = false; return new(HttpStatusCode.ServiceUnavailable); }
                return Json($"{{\"partNumber\":{path.Split('/').Last()},\"etag\":\"ack\"}}");
            }
            if (path.EndsWith("/complete")) return Json("{\"status\":\"ready\"}");
            if (path.EndsWith("/transcribe")) { transcribes++; return Json("{\"jobId\":\"job-1\",\"status\":\"queued\"}"); }
            if (path == "/api/jobs/job-1") return Json("{\"id\":\"job-1\",\"status\":\"succeeded\"}");
            throw new Exception("Unexpected cloud request " + path);
        }));
        var stateRoot = Path.Combine(root, "processing-state");
        await using (var first = new CloudProcessing(stateRoot, Client))
        {
            var failed = await first.StartAsync(recording, account, new());
            if (failed.Stage != ProcessingStage.Failed || failed.Ticket?.Id != "upload-1") throw new Exception("Upload failure lost its ticket.");
        }
        await using (var resumed = new CloudProcessing(stateRoot, Client))
        {
            var completed = await resumed.StartAsync(recording, account, new());
            if (completed.Stage != ProcessingStage.Completed || creates != 1 || transcribes != 1) throw new Exception("Retry duplicated creation or failed to resume.");
            await resumed.StartAsync(recording, account, new());
            if (creates != 1 || transcribes != 1) throw new Exception("Completed task ran again.");
            if (resumed.List((account with { UserId = "another-user" }).Partition).Count != 0) throw new Exception("Processing state crossed accounts.");
        }
        var persisted = File.ReadAllText(Directory.GetFiles(stateRoot, "*.json", SearchOption.AllDirectories).Single());
        if (persisted.Contains(account.Token)) throw new Exception("Processing journal contains credentials.");
        if (!File.Exists(recording.AudioPath)) throw new Exception("Cloud retry removed local audio.");
        var uploadOnlyRoot = Path.Combine(root, "upload-only-state");
        await using (var uploadOnly = new CloudProcessing(uploadOnlyRoot, Client))
        {
            Thread? release = null;
            if (holdJournal) uploadOnly.Changed += entry =>
            {
                if (entry.Stage != ProcessingStage.CompletingUpload || !entry.UploadCompleted || release is not null) return;
                var path = Path.Combine(uploadOnlyRoot, account.Partition, recording.Id + ".json");
                var held = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
                release = new Thread(() => { Thread.Sleep(50); held.Dispose(); });
                release.Start();
            };
            try
            {
                var synced = await uploadOnly.StartAsync(recording, account, new(Transcribe: false));
                if (synced.Stage != ProcessingStage.Synced || transcribes != 1) throw new Exception($"Upload-only result: stage={synced.Stage}, transcribe requests={transcribes - 1}, uploaded={synced.UploadCompleted}.");
            }
            finally { release?.Join(); }
        }
        await using (var resumed = new CloudProcessing(uploadOnlyRoot, Client))
        {
            var completed = await resumed.StartAsync(recording, account, new(Transcribe: true));
            if (completed.Stage != ProcessingStage.Completed || transcribes != 2 || creates != 2) throw new Exception("Later transcription duplicated upload or was skipped.");
            await resumed.ForgetRemoteAsync(account.Partition, "upload-1");
            if (resumed.List(account.Partition).Count != 0 || !File.Exists(recording.AudioPath)) throw new Exception("Remote deletion failed to detach journal or removed local audio.");
        }
        if (holdJournal)
        {
            var deniedRoot = Path.Combine(root, "processing-denied");
            await using var denied = new CloudProcessing(deniedRoot, Client);
            FileStream? held = null;
            byte[]? original = null;
            var path = Path.Combine(deniedRoot, account.Partition, recording.Id + ".json");
            void Hold(ProcessingEntry entry)
            {
                if (entry.Stage != ProcessingStage.CompletingUpload || !entry.UploadCompleted || held is not null) return;
                original = File.ReadAllBytes(path);
                held = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            }
            denied.Changed += Hold;
            try
            {
                await denied.StartAsync(recording, account, new(Transcribe: false));
                throw new Exception("Persistent journal denial was reported as saved.");
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
            finally { held?.Dispose(); denied.Changed -= Hold; }
            if (original is null || !original.SequenceEqual(File.ReadAllBytes(path)) || Directory.EnumerateFiles(deniedRoot, "*.tmp", SearchOption.AllDirectories).Any())
                throw new Exception("Denied journal replacement changed the original or leaked temporary files.");
            var retried = await denied.StartAsync(recording, account, new(Transcribe: false));
            if (retried.Stage != ProcessingStage.Synced || creates != 3 || transcribes != 2)
                throw new Exception("Retry after persistent journal denial duplicated cloud work.");
        }
    }
    private static HttpResponseMessage Json(string value) => new(HttpStatusCode.OK) { Content = new StringContent(value, Encoding.UTF8, "application/json") };
    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => Task.FromResult(send(request));
    }
}
