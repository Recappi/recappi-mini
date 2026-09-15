using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Recappi.Core;

public enum ProcessingStage { Creating, Uploading, CompletingUpload, Synced, SubmittingTranscription, Queued, Transcribing, Completed, Failed, Paused, NeedsReconciliation }
public sealed record ProcessingOptions(string Language = "auto", string? Prompt = null, bool Transcribe = true);
public sealed record ProcessingEntry(string LocalId, string Partition, string Title, ProcessingStage Stage,
    UploadTicket? Ticket = null, bool UploadCompleted = false, bool TranscriptionAttempted = false, string? JobId = null,
    double Progress = 0, string? Error = null);

public sealed class ProcessingJournalException(string message, Exception inner) : IOException(message, inner);

/// <summary>Account-scoped, resumable uploads. Recording does not wait for this worker.</summary>
public sealed class CloudProcessing : IAsyncDisposable
{
    private sealed record Work(CancellationTokenSource Cancellation, Task<ProcessingEntry> Task);
    private readonly string root;
    private readonly Func<CloudAccount, CloudClient> createClient;
    private readonly Func<TimeSpan, CancellationToken, Task> delay;
    private readonly SemaphoreSlim slots = new(2, 2);
    private readonly object sync = new();
    private readonly Dictionary<string, Work> active = [];
    private readonly HashSet<string> detaching = [];
    private bool disposed;
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { WriteIndented = true, Converters = { new JsonStringEnumConverter() } };
    public event Action<ProcessingEntry>? Changed;

    public CloudProcessing(string root, Func<CloudAccount, CloudClient>? createClient = null, Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        this.root = Path.GetFullPath(root);
        this.createClient = createClient ?? (account => new CloudClient(account.Origin, account.Token));
        this.delay = delay ?? Task.Delay;
    }

    public Task<ProcessingEntry> StartAsync(LocalRecording recording, CloudAccount account, ProcessingOptions options)
    {
        if (recording.State != RecordingState.Done) throw new InvalidOperationException("Only completed local recordings can be uploaded.");
        _ = EntryPath(account.Partition, recording.Id);
        var key = account.Partition + "/" + recording.Id;
        lock (sync)
        {
            if (detaching.Contains(key)) throw new InvalidOperationException("录音关联正在更新，请稍后重试。");
            ObjectDisposedException.ThrowIf(disposed, this);
            if (active.TryGetValue(key, out var existing)) return existing.Task;
            var cancellation = new CancellationTokenSource();
            var task = Task.Run(async () =>
            {
                try { return await ProcessAsync(recording, account, options, cancellation.Token); }
                finally { lock (sync) active.Remove(key); cancellation.Dispose(); }
            });
            active.Add(key, new(cancellation, task));
            return task;
        }
    }

    public IReadOnlyList<ProcessingEntry> List(string partition)
    {
        ValidatePartition(partition);
        var directory = Path.Combine(root, partition);
        if (!Directory.Exists(directory)) return [];
        var entries = new List<ProcessingEntry>();
        foreach (var file in Directory.EnumerateFiles(directory, "*.json"))
        {
            try
            {
                var value = ReadJournal(file);
                if (value is not null && value.Partition == partition && EntryPath(partition, value.LocalId) == file) entries.Add(value);
            }
            catch (Exception error) when (error is JsonException or IOException or ArgumentException or UnauthorizedAccessException) { }
        }
        return entries;
    }

    public void CancelAll()
    {
        lock (sync) foreach (var work in active.Values) work.Cancellation.Cancel();
    }
    public async Task ForgetRemoteAsync(string partition, string remoteId)
    {
        var entries = List(partition).Where(x => x.Ticket?.Id == remoteId).ToArray();
        foreach (var entry in entries)
        {
            var key = partition + "/" + entry.LocalId;
            Task? pending = null;
            lock (sync)
            {
                detaching.Add(key);
                if (active.TryGetValue(key, out var work)) { work.Cancellation.Cancel(); pending = work.Task; }
            }
            try { if (pending is not null) await pending; File.Delete(EntryPath(partition, entry.LocalId)); }
            finally { lock (sync) detaching.Remove(key); }
        }
    }

    private async Task<ProcessingEntry> ProcessAsync(LocalRecording recording, CloudAccount account, ProcessingOptions options, CancellationToken cancellation)
    {
        // A display list can skip inaccessible rows; resuming work cannot treat them as absent.
        ProcessingEntry? prior;
        try
        {
            prior = ReadJournal(EntryPath(account.Partition, recording.Id));
            if (prior is null || prior.LocalId != recording.Id || prior.Partition != account.Partition || !Enum.IsDefined(prior.Stage))
                throw new InvalidDataException("本地处理记录无效，请先检查云端录音；不会重新上传。");
        }
        catch (FileNotFoundException) { prior = null; }
        catch (DirectoryNotFoundException) { prior = null; }
        catch (Exception error) when (error is JsonException or InvalidDataException)
        {
            throw new ProcessingJournalException("本地处理记录已损坏，请先在云端录音库核对；本地音频已保留，不会重新上传。", error);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
            throw new ProcessingJournalException("暂时无法读取本地处理记录，请稍后重试；本地音频已保留，不会重新上传。", error);
        }
        var entry = prior ?? new ProcessingEntry(recording.Id, account.Partition, recording.Title, ProcessingStage.Creating);
        if (prior is { Ticket: null, Stage: ProcessingStage.Creating }) entry = entry with { Stage = ProcessingStage.NeedsReconciliation };
        var acquired = false;
        try
        {
            await slots.WaitAsync(cancellation); acquired = true;
            using var client = createClient(account);
            if (entry.Stage == ProcessingStage.Completed)
            {
                if (entry.UploadCompleted && entry.JobId is null && !entry.TranscriptionAttempted) entry = entry with { Stage = ProcessingStage.Synced };
                else return entry;
            }
            if (entry.Ticket is null)
            {
                if (entry.Stage == ProcessingStage.NeedsReconciliation) throw new InvalidOperationException("上次创建结果未确认，请先在云端录音库核对。");
                entry = entry with { Stage = ProcessingStage.Creating, Error = null }; Save(entry);
                try
                {
                    var ticket = await client.CreateUploadAsync(recording.Title, recording.DurationMs, cancellation: cancellation);
                    entry = entry with { Ticket = ticket, Stage = ProcessingStage.Uploading }; Save(entry);
                }
                catch (Exception failure) when (failure is HttpRequestException or OperationCanceledException or IOException or InvalidDataException || failure is CloudException cloud && ((int)cloud.Status >= 500 || (int)cloud.Status == 408))
                {
                    entry = entry with { Stage = ProcessingStage.NeedsReconciliation, Error = "创建请求的结果未确认，请先检查云端录音库。" };
                    Save(entry); return entry;
                }
            }
            if (!entry.UploadCompleted)
            {
                if (entry.Stage is ProcessingStage.CompletingUpload or ProcessingStage.Failed or ProcessingStage.Paused)
                {
                    var remote = await client.RecordingAsync(entry.Ticket!.Id, cancellation);
                    if (Text(remote, "status") == "ready") entry = entry with { UploadCompleted = true };
                }
                if (!entry.UploadCompleted)
                {
                    entry = entry with { Stage = ProcessingStage.Uploading, Error = null, Progress = 0 }; Save(entry);
                    var parts = await client.UploadAsync(entry.Ticket!, recording.AudioPath, new InlineProgress(value =>
                    {
                        entry = entry with { Progress = value }; Notify(entry);
                    }), cancellation);
                    entry = entry with { Stage = ProcessingStage.CompletingUpload }; Save(entry);
                    await client.CompleteUploadAsync(entry.Ticket!.Id, parts, cancellation);
                    entry = entry with { UploadCompleted = true, Progress = 1 }; Save(entry);
                }
            }
            if (!options.Transcribe && !entry.TranscriptionAttempted && entry.JobId is null)
            { entry = entry with { Stage = ProcessingStage.Synced, Error = null }; Save(entry); return entry; }
            if (entry.JobId is null)
            {
                if (entry.TranscriptionAttempted)
                {
                    var history = await client.JobsAsync(entry.Ticket!.Id, cancellation);
                    if (history.TryGetProperty("items", out var items) && items.ValueKind == JsonValueKind.Array)
                        entry = entry with { JobId = items.EnumerateArray().Select(x => Text(x, "id")).FirstOrDefault(x => !string.IsNullOrEmpty(x)) };
                    if (entry.JobId is null)
                    {
                        entry = entry with { Stage = ProcessingStage.NeedsReconciliation, Error = "转写请求结果未确认，请刷新云端任务后重试。" };
                        Save(entry); return entry;
                    }
                }
                else
                {
                    entry = entry with { Stage = ProcessingStage.SubmittingTranscription, TranscriptionAttempted = true, Error = null }; Save(entry);
                    var response = await client.TranscribeAsync(entry.Ticket!.Id, options.Language, prompt: options.Prompt, cancellation: cancellation);
                    var jobId = Text(response, "jobId");
                    if (string.IsNullOrWhiteSpace(jobId)) throw new InvalidDataException("Missing transcription job ID.");
                    entry = entry with { JobId = jobId, Stage = ProcessingStage.Queued }; Save(entry);
                }
            }
            var deadline = DateTimeOffset.UtcNow.AddMinutes(30);
            while (DateTimeOffset.UtcNow < deadline)
            {
                var job = await client.JobAsync(entry.JobId!, cancellation);
                var status = Text(job, "status");
                if (status == "succeeded") { entry = entry with { Stage = ProcessingStage.Completed, Progress = 1, Error = null }; Save(entry); return entry; }
                if (status == "failed") { entry = entry with { Stage = ProcessingStage.Failed, Error = "云端转写失败，可在任务详情重试。" }; Save(entry); return entry; }
                if (status is not ("queued" or "running")) throw new InvalidDataException("Unknown transcription status.");
                var percent = job.TryGetProperty("chunkProgress", out var chunks) && chunks.ValueKind == JsonValueKind.Object && chunks.TryGetProperty("percent", out var progress) && progress.TryGetDouble(out var number) ? Math.Clamp(number / 100, 0, 1) : 0;
                entry = entry with { Stage = status == "queued" ? ProcessingStage.Queued : ProcessingStage.Transcribing, Progress = percent, Error = null }; Save(entry);
                await delay(TimeSpan.FromSeconds(2), cancellation);
            }
            entry = entry with { Stage = ProcessingStage.Paused, Error = "云端任务仍在运行，可稍后继续检查。" };
        }
        catch (OperationCanceledException) { entry = entry with { Stage = ProcessingStage.Paused, Error = "已暂停；本地录音保留，可继续上传或检查任务。" }; }
        catch (Exception error)
        {
            if (entry.Stage == ProcessingStage.SubmittingTranscription && error is CloudException rejected && (int)rejected.Status is 400 or 401 or 402 or 403 or 404 or 422)
                entry = entry with { TranscriptionAttempted = false };
            entry = entry with { Stage = ProcessingStage.Failed, Error = error is CloudException ? error.Message : "处理未完成，本地录音已保留。" };
        }
        finally { if (acquired) slots.Release(); }
        Save(entry);
        return entry;
    }

    private static ProcessingEntry? ReadJournal(string path)
    {
        // Share delete so rendering the list does not block atomic journal replacement.
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete);
        return JsonSerializer.Deserialize<ProcessingEntry>(stream, Json);
    }

    private void Save(ProcessingEntry entry)
    {
        var path = EntryPath(entry.Partition, entry.LocalId);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        AtomicJsonFile.Write(path, JsonSerializer.Serialize(entry, Json));
        Notify(entry);
    }
    private void Notify(ProcessingEntry entry)
    {
        if (Changed is null) return;
        foreach (Action<ProcessingEntry> observer in Changed.GetInvocationList()) try { observer(entry); } catch { }
    }
    private string EntryPath(string partition, string id)
    {
        ValidatePartition(partition);
        if (!Guid.TryParseExact(id, "N", out _)) throw new ArgumentException("Invalid local recording ID.");
        return Path.Combine(root, partition, id + ".json");
    }
    private static void ValidatePartition(string value)
    {
        if (value.Length != 64 || value.Any(c => !char.IsAsciiHexDigit(c))) throw new ArgumentException("Invalid account partition.");
    }
    private static string? Text(JsonElement value, string name) => value.TryGetProperty(name, out var property) && property.ValueKind == JsonValueKind.String ? property.GetString() : null;
    private sealed class InlineProgress(Action<double> action) : IProgress<double> { public void Report(double value) => action(value); }
    public async ValueTask DisposeAsync()
    {
        Task[] tasks;
        lock (sync) { disposed = true; foreach (var work in active.Values) work.Cancellation.Cancel(); tasks = active.Values.Select(x => (Task)x.Task).ToArray(); }
        await Task.WhenAll(tasks);
    }
}
