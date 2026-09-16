using System.Net;
using System.Text;
using Recappi.Core;

internal static class ProcessingConcurrencyTests
{
    public static async Task RunAsync(string root)
    {
        await RunScenarioAsync(Path.Combine(root, "normal-upload-queue"), false);
        await RunScenarioAsync(Path.Combine(root, "cancel-upload-queue"), true);
    }

    private static async Task RunScenarioAsync(string root, bool cancelAndResume)
    {
        var store = new LocalRecordingStore(Path.Combine(root, "concurrent-audio"));
        var first = store.Create("First") with { State = RecordingState.Done, DurationMs = 1000 };
        var second = store.Create("Second") with { State = RecordingState.Done, DurationMs = 1000 };
        foreach (var recording in new[] { first, second })
        {
            await File.WriteAllBytesAsync(recording.AudioPath, new byte[] { 1, 2, 3, 4 });
            store.Save(recording);
        }
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releasePart = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var releaseJob = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var conflict = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var jobStarted = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var creating = 0;
        var uploads = 0;
        var account = new CloudAccount("https://recappi.test", "parallel", null, "fixture");
        CloudClient Client(CloudAccount user) => new(user.Origin, user.Token, new Handler(async (request, cancellation) =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path == "/api/recordings")
            {
                if (Interlocked.CompareExchange(ref uploads, 1, 0) != 0)
                {
                    conflict.TrySetResult();
                    return new(HttpStatusCode.Conflict);
                }
                var id = Interlocked.Increment(ref creating);
                return Json($"{{\"id\":\"r{id}\",\"partSize\":4,\"maxPartBytes\":8}}");
            }
            if (path.Contains("/parts/"))
            {
                if (path.Contains("/r1/")) { entered.TrySetResult(); await releasePart.Task.WaitAsync(cancellation); }
                return Json("""{"partNumber":1,"etag":"ack"}""");
            }
            if (path == "/api/recordings/r1") return Json("""{"status":"uploading"}""");
            if (path.EndsWith("/complete")) { Interlocked.Exchange(ref uploads, 0); return Json("""{"status":"ready"}"""); }
            if (path.EndsWith("/transcribe")) return Json("""{"jobId":"job1","status":"queued"}""");
            if (path == "/api/jobs/job1")
            {
                jobStarted.TrySetResult();
                await releaseJob.Task.WaitAsync(cancellation);
                return Json("""{"status":"succeeded"}""");
            }
            throw new Exception("Unexpected concurrency fixture request: " + path);
        }));
        await using var processing = new CloudProcessing(Path.Combine(root, "concurrent-state"), Client);
        try
        {
            var firstWork = processing.StartAsync(first, account, new());
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var secondWork = processing.StartAsync(second, account, new(Transcribe: false));
            // Keep the first upload outstanding while a conflicting request can arrive.
            await Task.WhenAny(conflict.Task, Task.Delay(500));
            if (cancelAndResume)
            {
                processing.CancelAll();
                var paused = await Task.WhenAll(firstWork, secondWork).WaitAsync(TimeSpan.FromSeconds(5));
                if (paused.Any(entry => entry.Stage != ProcessingStage.Paused) || creating != 1)
                    throw new Exception($"Cancelling active/queued uploads: stages={string.Join(',', paused.Select(entry => entry.Stage))}, creates={creating}.");
                entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
                firstWork = processing.StartAsync(first, account, new());
                await entered.Task.WaitAsync(TimeSpan.FromSeconds(5));
                secondWork = processing.StartAsync(second, account, new(Transcribe: false));
            }
            releasePart.TrySetResult();
            await jobStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
            var secondResult = await secondWork.WaitAsync(TimeSpan.FromSeconds(5));
            if (conflict.Task.IsCompleted || secondResult.Stage != ProcessingStage.Synced || creating != 2)
                throw new Exception("Concurrent local uploads collided with the backend's one-upload-per-account limit.");
            if (firstWork.IsCompleted) throw new Exception("Fixture did not retain active transcription while second upload completed.");
            releaseJob.TrySetResult();
            if ((await firstWork.WaitAsync(TimeSpan.FromSeconds(5))).Stage != ProcessingStage.Completed)
                throw new Exception("Queued uploads interrupted the first transcription.");
            if (!File.Exists(first.AudioPath) || !File.Exists(second.AudioPath)) throw new Exception("Concurrent processing removed local audio.");
        }
        finally { releasePart.TrySetResult(); releaseJob.TrySetResult(); processing.CancelAll(); }
    }

    private static HttpResponseMessage Json(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    private sealed class Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellation) => send(request, cancellation);
    }
}
