using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Recappi.Core;

public sealed record CachedCloudContent(CloudRecordingItem Recording, CloudTranscript Transcript, DateTimeOffset SavedAt);
public sealed record CloudSearchHit(CloudRecordingItem Recording, string Source, string Snippet, long? StartMs, string? Speaker);
public sealed record CloudSearchResult(IReadOnlyList<CloudSearchHit> Hits, int CachedRecordings, int UnreadableRecordings, bool Truncated);

public sealed class CloudContentCache(string root)
{
    public static string DefaultRoot => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Recappi Mini", "CloudContent");
    private static readonly byte[] Entropy = Encoding.UTF8.GetBytes("Recappi Mini cloud content v1");
    private static readonly object[] Gates = Enumerable.Range(0, 64).Select(_ => new object()).ToArray();
    private static object Gate(string path) => Gates[(uint)StringComparer.OrdinalIgnoreCase.GetHashCode(path) % (uint)Gates.Length];
    private string DirectoryPath(string partition)
    {
        if (partition.Length != 64 || !partition.All(Uri.IsHexDigit)) throw new ArgumentException("Invalid cache account.");
        return Path.Combine(Path.GetFullPath(root), partition);
    }
    private string FilePath(string partition, string id) => Path.Combine(DirectoryPath(partition), Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(id))) + ".dpapi");
    public void Save(string partition, CloudRecordingItem recording, CloudTranscript transcript)
    {
        var path = FilePath(partition, recording.Id);
        lock (Gate(path))
        {
            if (File.Exists(path + ".deleted")) return;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
            var plaintext = JsonSerializer.SerializeToUtf8Bytes(new CachedCloudContent(recording, transcript, DateTimeOffset.UtcNow));
            try { File.WriteAllBytes(temporary, ProtectedData.Protect(plaintext, Entropy, DataProtectionScope.CurrentUser)); File.Move(temporary, path, true); }
            finally { CryptographicOperations.ZeroMemory(plaintext); if (File.Exists(temporary)) File.Delete(temporary); }
        }
    }
    public CachedCloudContent? Load(string partition, string id)
    {
        var path = FilePath(partition, id);
        var entry = ReadVisible(path);
        return entry?.Recording.Id == id ? entry : null;
    }
    private static CachedCloudContent Read(string path)
    {
        var bytes = ProtectedData.Unprotect(File.ReadAllBytes(path), Entropy, DataProtectionScope.CurrentUser);
        try { return JsonSerializer.Deserialize<CachedCloudContent>(bytes) ?? throw new InvalidDataException("Invalid cached transcript."); }
        finally { CryptographicOperations.ZeroMemory(bytes); }
    }
    private static CachedCloudContent? ReadVisible(string path)
    {
        lock (Gate(path)) return File.Exists(path + ".deleted") || !File.Exists(path) ? null : Read(path);
    }
    public void Delete(string partition, string id)
    {
        var path = FilePath(partition, id);
        lock (Gate(path))
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            // Remote recording IDs are not reused. Persist invalidation before deleting
            // content so delayed responses and app restarts cannot resurrect it.
            using (var marker = new FileStream(path + ".deleted", FileMode.OpenOrCreate, FileAccess.Write, FileShare.Read)) marker.Flush(true);
            File.Delete(path);
        }
    }
    public Task<IReadOnlyList<CloudRecordingItem>> ListAsync(string partition, CancellationToken cancellation = default) => Task.Run<IReadOnlyList<CloudRecordingItem>>(() =>
    {
        var directory = DirectoryPath(partition);
        var items = new List<CloudRecordingItem>();
        if (!Directory.Exists(directory)) return items;
        foreach (var path in Directory.EnumerateFiles(directory, "*.dpapi"))
        {
            cancellation.ThrowIfCancellationRequested();
            try { if (ReadVisible(path) is { } entry) items.Add(entry.Recording); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException or JsonException) { }
        }
        return items;
    }, cancellation);
    public Task<CloudSearchResult> SearchAsync(string partition, string query, string? speaker = null, CancellationToken cancellation = default) => Task.Run(() =>
    {
        var directory = DirectoryPath(partition); query = query.Trim(); speaker = speaker?.Trim();
        var hits = new List<CloudSearchHit>(); var count = 0; var damaged = 0; var truncated = false;
        if (!Directory.Exists(directory)) return new CloudSearchResult(hits, 0, 0, false);
        foreach (var path in Directory.EnumerateFiles(directory, "*.dpapi"))
        {
            cancellation.ThrowIfCancellationRequested();
            CachedCloudContent? entry;
            try { entry = ReadVisible(path); if (entry is null) continue; count++; }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or CryptographicException or JsonException) { damaged++; continue; }
            if (query.Length == 0 && string.IsNullOrEmpty(speaker)) continue;
            bool Matches(string text) => query.Length == 0 || text.Contains(query, StringComparison.OrdinalIgnoreCase);
            void Add(string source, string text, long? ms = null, string? name = null)
            {
                if (hits.Count >= 100) { truncated = true; return; }
                var index = query.Length == 0 ? 0 : Math.Max(0, text.IndexOf(query, StringComparison.OrdinalIgnoreCase) - 50);
                hits.Add(new(entry.Recording, source, text.Substring(index, Math.Min(220, text.Length - index)), ms, name));
            }
            if (string.IsNullOrEmpty(speaker))
            {
                if (Matches(entry.Recording.Title)) Add("标题", entry.Recording.Title);
                if (Matches(entry.Transcript.Summary)) Add("摘要", entry.Transcript.Summary);
            }
            if (entry.Transcript.Segments.Count > 0)
                foreach (var segment in entry.Transcript.Segments)
                {
                    cancellation.ThrowIfCancellationRequested();
                    if ((string.IsNullOrEmpty(speaker) || string.Equals(segment.Speaker, speaker, StringComparison.OrdinalIgnoreCase)) && Matches(segment.Text)) Add("逐字稿", segment.Text, segment.StartMs, segment.Speaker);
                }
            else if (string.IsNullOrEmpty(speaker) && Matches(entry.Transcript.Text)) Add("逐字稿", entry.Transcript.Text);
        }
        hits.RemoveAll(hit => File.Exists(FilePath(partition, hit.Recording.Id) + ".deleted"));
        return new CloudSearchResult(hits, count, damaged, truncated);
    }, cancellation);
}
