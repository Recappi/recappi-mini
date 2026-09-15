using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text.Json;

namespace Recappi.Core;

public sealed class CloudException(HttpStatusCode status) : Exception(status == HttpStatusCode.Unauthorized
    ? "Your Recappi session has expired. Sign in again."
    : $"Recappi request failed ({(int)status}).")
{
    public HttpStatusCode Status { get; } = status;
}

public sealed record UploadPart(int PartNumber, string Etag);
public sealed record UploadTicket(string Id, int PartSize, int MaxPartBytes);

/// <summary>One immutable origin/account client. Credentials never follow redirects.</summary>
public sealed partial class CloudClient : IDisposable
{
    private readonly HttpClient http;
    private readonly string? token;
    public Uri Origin { get; }
    internal event Action? AuthenticationRejected;
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { DefaultIgnoreCondition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull };

    public CloudClient(string origin, string? token = null, HttpMessageHandler? handler = null, TimeSpan? requestTimeout = null)
    {
        Origin = ValidateOrigin(origin);
        this.token = token;
        http = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false }, true)
        { Timeout = requestTimeout ?? TimeSpan.FromMinutes(2) };
    }

    public static Uri ValidateOrigin(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || !string.IsNullOrEmpty(uri.UserInfo) ||
            uri.AbsolutePath != "/" || !string.IsNullOrEmpty(uri.Query) || !string.IsNullOrEmpty(uri.Fragment) ||
            (uri.Scheme != "https" && !(uri.Scheme == "http" && uri.IsLoopback)))
            throw new ArgumentException("Use an HTTPS Recappi origin without a path or credentials.");
        return uri;
    }

    public Task<JsonElement> SessionAsync(CancellationToken cancellation = default) => SendJsonAsync(HttpMethod.Get, "/api/auth/get-session", null, cancellation);
    public Task<JsonElement> SignOutAsync(CancellationToken cancellation = default) => SendJsonAsync(HttpMethod.Post, "/api/auth/sign-out", null, cancellation);
    public Task<JsonElement> ListAsync(string? cursor = null, CancellationToken cancellation = default) => SendJsonAsync(HttpMethod.Get, "/api/recordings?limit=50" + (cursor is null ? "" : "&cursor=" + Uri.EscapeDataString(cursor)), null, cancellation);
    public Task<JsonElement> RecordingAsync(string id, CancellationToken cancellation = default) => SendJsonAsync(HttpMethod.Get, RecordingPath(id), null, cancellation);
    public Task<JsonElement> TranscriptAsync(string id, string? jobId = null, CancellationToken cancellation = default) => SendJsonAsync(HttpMethod.Get, RecordingPath(id) + "/transcript" + (jobId is null ? "" : "?jobId=" + Uri.EscapeDataString(jobId)), null, cancellation);
    public Task<JsonElement> JobsAsync(string id, CancellationToken cancellation = default) => SendJsonAsync(HttpMethod.Get, RecordingPath(id) + "/jobs?limit=10", null, cancellation);
    public Task<JsonElement> JobAsync(string id, CancellationToken cancellation = default) => SendJsonAsync(HttpMethod.Get, "/api/jobs/" + Segment(id), null, cancellation);
    public Task<JsonElement> DeleteAsync(string id, CancellationToken cancellation = default) => SendJsonAsync(HttpMethod.Delete, RecordingPath(id), null, cancellation);
    public Task<JsonElement> RetryChunksAsync(string jobId, CancellationToken cancellation = default) => SendJsonAsync(HttpMethod.Post, "/api/jobs/" + Segment(jobId) + "/retry-failed-chunks", null, cancellation);
    public Task<JsonElement> TranscribeAsync(string id, string language, bool force = false, string? prompt = null, CancellationToken cancellation = default) => SendJsonAsync(HttpMethod.Post, RecordingPath(id) + "/transcribe", new { language, force, prompt }, cancellation);
    public Task<JsonElement> BillingAsync(CancellationToken cancellation = default) => SendJsonAsync(HttpMethod.Get, "/api/billing/status", null, cancellation);
    public Task<JsonElement> SummarizeAsync(string id, string? prompt = null, CancellationToken cancellation = default) => SendJsonAsync(HttpMethod.Post, RecordingPath(id) + "/summarize", new { prompt }, cancellation);
    public Task<JsonElement> BeginDeviceLoginAsync(CancellationToken cancellation = default) => SendJsonAsync(HttpMethod.Post, "/api/device-auth/start", null, cancellation);
    public Task<JsonElement> PollDeviceLoginAsync(string deviceCode, CancellationToken cancellation = default) => SendJsonAsync(HttpMethod.Post, "/api/device-auth/poll", new { device_code = deviceCode }, cancellation);

    public async Task<CloudAccount> ValidateAccountAsync(CloudAccount account, CancellationToken cancellation = default)
    {
        using var timeout = CreateRequestTimeout(cancellation);
        cancellation = timeout.Token;
        using var response = await SendAsync(HttpMethod.Get, "/api/auth/get-session", null, cancellation);
        var data = await response.Content.ReadFromJsonAsync<JsonElement>(Json, cancellation);
        if (data.ValueKind != JsonValueKind.Object || !data.TryGetProperty("session", out var session) || session.ValueKind != JsonValueKind.Object ||
            !data.TryGetProperty("user", out var user) || user.ValueKind != JsonValueKind.Object ||
            !user.TryGetProperty("id", out var id) || id.GetString() != account.UserId)
            throw new CloudException(HttpStatusCode.Unauthorized);
        var renewed = response.Headers.TryGetValues("set-auth-token", out var values) ? values.FirstOrDefault()?.Trim() : null;
        return account with { Token = string.IsNullOrWhiteSpace(renewed) ? account.Token : renewed,
            Email = user.TryGetProperty("email", out var email) && email.ValueKind == JsonValueKind.String ? email.GetString() : account.Email };
    }

    public async Task<UploadTicket> CreateUploadAsync(string title, long durationMs, string contentType = "audio/wav", CancellationToken cancellation = default)
    {
        var response = await SendJsonAsync(HttpMethod.Post, "/api/recordings", new { title, contentType, durationMs }, cancellation);
        var ticket = response.Deserialize<UploadTicket>(Json) ?? throw new InvalidDataException("Missing upload ticket.");
        _ = Segment(ticket.Id);
        if (ticket.PartSize <= 0 || ticket.PartSize > 64 * 1024 * 1024 || ticket.MaxPartBytes < ticket.PartSize)
            throw new InvalidDataException("Invalid upload part size.");
        return ticket;
    }

    public async Task<IReadOnlyList<UploadPart>> UploadAsync(UploadTicket ticket, string path, IProgress<double>? progress = null, CancellationToken cancellation = default)
    {
        if (ticket.PartSize <= 0 || ticket.PartSize > 64 * 1024 * 1024 || ticket.PartSize > ticket.MaxPartBytes) throw new ArgumentException("Invalid upload part size.");
        await using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, true);
        if (file.Length == 0) throw new InvalidDataException("Audio file is empty.");
        var buffer = new byte[ticket.PartSize];
        var parts = new List<UploadPart>();
        long uploaded = 0;
        while (uploaded < file.Length)
        {
            var count = (int)Math.Min(buffer.Length, file.Length - uploaded);
            await file.ReadExactlyAsync(buffer.AsMemory(0, count), cancellation);
            var number = parts.Count + 1;
            using var content = new ByteArrayContent(buffer, 0, count);
            content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
            using var timeout = CreateRequestTimeout(cancellation);
            using var response = await SendAsync(HttpMethod.Put, RecordingPath(ticket.Id) + "/parts/" + number, content, timeout.Token);
            var part = await response.Content.ReadFromJsonAsync<UploadPart>(Json, timeout.Token) ?? throw new InvalidDataException("Missing uploaded part.");
            if (part.PartNumber != number || string.IsNullOrWhiteSpace(part.Etag)) throw new InvalidDataException("Invalid uploaded part acknowledgement.");
            parts.Add(part);
            uploaded += count;
            progress?.Report((double)uploaded / file.Length);
        }
        return parts;
    }

    public Task<JsonElement> CompleteUploadAsync(string id, IReadOnlyList<UploadPart> parts, CancellationToken cancellation = default) => SendJsonAsync(HttpMethod.Post, RecordingPath(id) + "/complete", new { parts }, cancellation);

    public async Task<string> DownloadAudioAsync(string id, string destination, CancellationToken cancellation = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromMinutes(30));
        var temporary = Path.GetFullPath(destination) + "." + Guid.NewGuid().ToString("N") + ".partial";
        try
        {
            using var response = await SendAsync(HttpMethod.Get, RecordingPath(id) + "/audio", null, timeout.Token, "audio/*");
            const long limit = 4L * 1024 * 1024 * 1024;
            if (response.Content.Headers.ContentLength > limit) throw new InvalidDataException("音频超过下载大小限制。");
            var media = response.Content.Headers.ContentType?.MediaType;
            if (media is not null && !media.StartsWith("audio/", StringComparison.OrdinalIgnoreCase) && media != "application/octet-stream") throw new InvalidDataException("服务器未返回音频文件。");
            destination = Path.ChangeExtension(destination, media switch { "audio/wav" or "audio/wave" or "audio/x-wav" => ".wav", "audio/mpeg" or "audio/mp3" => ".mp3", "audio/mp4" or "audio/x-m4a" => ".m4a", "audio/aac" => ".aac", "audio/ogg" => ".ogg", "audio/webm" => ".webm", _ => ".wav" });
            Directory.CreateDirectory(Path.GetDirectoryName(temporary)!);
            using (var input = await response.Content.ReadAsStreamAsync(timeout.Token))
            await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
            {
                var buffer = new byte[65536]; long written = 0;
                while (true)
                {
                    var count = await input.ReadAsync(buffer, timeout.Token);
                    if (count == 0) break;
                    written += count;
                    if (written > limit) throw new InvalidDataException("音频超过下载大小限制。");
                    await output.WriteAsync(buffer.AsMemory(0, count), timeout.Token);
                }
                if (written == 0 || response.Content.Headers.ContentLength is { } expected && expected != written) throw new EndOfStreamException("音频下载不完整。");
            }
            timeout.Token.ThrowIfCancellationRequested();
            File.Move(temporary, destination, true);
            return destination;
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private async Task<JsonElement> SendJsonAsync(HttpMethod method, string path, object? body, CancellationToken cancellation)
    {
        using var timeout = CreateRequestTimeout(cancellation);
        cancellation = timeout.Token;
        using var content = body is null ? null : JsonContent.Create(body, options: Json);
        using var response = await SendAsync(method, path, content, cancellation);
        if (response.StatusCode == HttpStatusCode.NoContent || response.Content.Headers.ContentLength == 0) return JsonSerializer.SerializeToElement(new { });
        using var stream = await response.Content.ReadAsStreamAsync(cancellation);
        using var document = await JsonDocument.ParseAsync(stream, cancellationToken: cancellation);
        return document.RootElement.Clone();
    }

    private CancellationTokenSource CreateRequestTimeout(CancellationToken cancellation)
    {
        var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        // ResponseHeadersRead ends HttpClient's timer at the headers; keep a deadline
        // alive until the JSON body has also been consumed.
        timeout.CancelAfter(http.Timeout);
        return timeout;
    }

    private async Task<HttpResponseMessage> SendAsync(HttpMethod method, string path, HttpContent? content, CancellationToken cancellation, string accept = "application/json", bool includeOrigin = false)
    {
        var target = new Uri(Origin, path);
        if (target.GetLeftPart(UriPartial.Authority) != Origin.GetLeftPart(UriPartial.Authority)) throw new ArgumentException("Cross-origin API request rejected.");
        using var request = new HttpRequestMessage(method, target) { Content = content };
        if (!string.IsNullOrWhiteSpace(token)) request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
        if (includeOrigin) request.Headers.TryAddWithoutValidation("Origin", Origin.GetLeftPart(UriPartial.Authority));
        request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue(accept));
        var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cancellation);
        if (!response.IsSuccessStatusCode)
        {
            var status = response.StatusCode;
            response.Dispose();
            if (status == HttpStatusCode.Unauthorized) AuthenticationRejected?.Invoke();
            // Do not surface raw server bodies, which can contain account or credential data.
            throw new CloudException(status);
        }
        return response;
    }

    private static string RecordingPath(string id) => "/api/recordings/" + Segment(id);
    private static string Segment(string value)
    {
        if (string.IsNullOrWhiteSpace(value) || value is "." or ".." || value.Contains('/') || value.Contains('\\')) throw new ArgumentException("Invalid resource ID.");
        return Uri.EscapeDataString(value);
    }
    public void Dispose() => http.Dispose();
}
