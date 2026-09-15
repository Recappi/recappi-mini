using System.Net.Http.Json;
using System.Net.WebSockets;
using System.Text.Json;

namespace Recappi.Core;

public sealed record CaptionOptions(string Language = "en", string? TranslationLanguage = null)
{
    public bool Translate => !string.IsNullOrWhiteSpace(TranslationLanguage);
    public static string Normalize(string? value) => string.IsNullOrWhiteSpace(value) || value.Trim().Equals("auto", StringComparison.OrdinalIgnoreCase) ? "en" : value.Trim().ToLowerInvariant().Split('-', '_')[0];
}
public sealed record CaptionClaim(string WebsocketUrl, string TokenType, string Token)
{
    public override string ToString() => "Realtime session (credentials redacted)";
    public Uri Validate()
    {
        if (!Uri.TryCreate(WebsocketUrl, UriKind.Absolute, out var uri) || !string.IsNullOrEmpty(uri.UserInfo) ||
            (uri.Scheme != "wss" && !(uri.Scheme == "ws" && uri.IsLoopback)) ||
            string.IsNullOrWhiteSpace(Token) || Token.Contains('\r') || Token.Contains('\n') ||
            string.IsNullOrEmpty(TokenType) || !TokenType.All(char.IsAsciiLetter)) throw new InvalidDataException("字幕连接信息无效。");
        return uri;
    }
}

public sealed partial class CloudClient
{
    public async Task<CaptionClaim> CaptionSessionAsync(CaptionOptions options, CancellationToken cancellation = default)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation); timeout.CancelAfter(TimeSpan.FromSeconds(10));
        object body = options.Translate
            ? new { mode = "translation", language = CaptionOptions.Normalize(options.Language), targetLanguage = CaptionOptions.Normalize(options.TranslationLanguage), delay = "low", expiresAfterSeconds = 60, includeSourceTranscript = true }
            : new { mode = "transcription", language = CaptionOptions.Normalize(options.Language), delay = "low", expiresAfterSeconds = 60, turnDetection = new { type = "none" } };
        using var content = JsonContent.Create(body, options: Json);
        using var response = await SendAsync(HttpMethod.Post, "/api/openai/realtime/sessions", content, timeout.Token, includeOrigin: true);
        var claim = await response.Content.ReadFromJsonAsync<CaptionClaim>(Json, timeout.Token) ?? throw new InvalidDataException("字幕会话缺失。");
        claim.Validate(); return claim;
    }
}

public interface ICaptionConnection : IAsyncDisposable
{
    Task SendAsync(object message, CancellationToken cancellation);
    Task<JsonElement?> ReceiveAsync(CancellationToken cancellation);
}

public sealed class CaptionConnection : ICaptionConnection
{
    private readonly ClientWebSocket socket = new();
    public static async Task<ICaptionConnection> ConnectAsync(CaptionClaim claim, string origin, CancellationToken cancellation)
    {
        var connection = new CaptionConnection();
        connection.socket.Options.SetRequestHeader("Authorization", claim.TokenType + " " + claim.Token);
        connection.socket.Options.SetRequestHeader("Origin", CloudClient.ValidateOrigin(origin).GetLeftPart(UriPartial.Authority));
        connection.socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(20);
        connection.socket.Options.CollectHttpResponseDetails = true;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation); timeout.CancelAfter(TimeSpan.FromSeconds(10));
        try { await connection.socket.ConnectAsync(claim.Validate(), timeout.Token); return connection; }
        catch (WebSocketException) when ((int)connection.socket.HttpStatusCode >= 400)
        {
            var status = connection.socket.HttpStatusCode;
            connection.socket.Dispose();
            throw new CloudException(status);
        }
        catch { connection.socket.Dispose(); throw; }
    }
    public async Task SendAsync(object message, CancellationToken cancellation)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation); timeout.CancelAfter(TimeSpan.FromSeconds(5));
        await socket.SendAsync(JsonSerializer.SerializeToUtf8Bytes(message).AsMemory(), WebSocketMessageType.Text, true, timeout.Token);
    }
    public async Task<JsonElement?> ReceiveAsync(CancellationToken cancellation)
    {
        using var message = new MemoryStream(); var buffer = new byte[8192];
        while (true)
        {
            var result = await socket.ReceiveAsync(buffer.AsMemory(), cancellation);
            if (result.MessageType == WebSocketMessageType.Close) return null;
            if (result.MessageType != WebSocketMessageType.Text || message.Length + result.Count > 1024 * 1024) throw new InvalidDataException("字幕消息无效或过大。");
            message.Write(buffer, 0, result.Count);
            if (result.EndOfMessage) break;
        }
        using var document = JsonDocument.Parse(message.ToArray()); return document.RootElement.Clone();
    }
    public ValueTask DisposeAsync() { socket.Abort(); socket.Dispose(); return ValueTask.CompletedTask; }
}
