using System.Net;
using System.Text;
using System.Text.Json;
using Recappi.Core;

internal static class CloudClientTests
{
    public static async Task RunAsync(string root)
    {
        foreach (var origin in new[] { "http://example.com", "https://user:password@example.com", "https://example.com/path", "https://example.com?token=x" })
        {
            try { CloudClient.ValidateOrigin(origin); throw new Exception("Accepted unsafe origin."); }
            catch (ArgumentException) { }
        }
        var payloads = new List<byte[]>();
        var paths = new List<string>();
        using var client = new CloudClient("https://recappi.test", "fixture-token", new Handler(async request =>
        {
            if (request.Headers.Authorization?.ToString() != "Bearer fixture-token") throw new Exception("Missing account authentication.");
            var path = request.RequestUri!.PathAndQuery;
            paths.Add(path);
            if (path == "/api/recordings") return Json("{\"id\":\"recording-1\",\"partSize\":4,\"maxPartBytes\":8}");
            if (path.Contains("/parts/"))
            {
                payloads.Add(await request.Content!.ReadAsByteArrayAsync());
                return Json($"{{\"partNumber\":{payloads.Count},\"etag\":\"part-{payloads.Count}\"}}");
            }
            if (path.EndsWith("/complete"))
            {
                using var json = JsonDocument.Parse(await request.Content!.ReadAsStringAsync());
                if (json.RootElement.GetProperty("parts").GetArrayLength() != 3) throw new Exception("Missing completed part descriptors.");
                return Json("{\"id\":\"recording-1\",\"status\":\"ready\"}");
            }
            return Json("{\"items\":[]}");
        }));
        var file = Path.Combine(root, "upload-fixture.wav");
        await File.WriteAllBytesAsync(file, Enumerable.Range(0, 10).Select(x => (byte)x).ToArray());
        var ticket = await client.CreateUploadAsync("Fixture", 100);
        var parts = await client.UploadAsync(ticket, file);
        await client.CompleteUploadAsync(ticket.Id, parts);
        if (!payloads.SelectMany(x => x).SequenceEqual(await File.ReadAllBytesAsync(file))) throw new Exception("Multipart upload changed audio bytes.");
        await client.ListAsync("cursor&escape=1");
        if (!paths.Last().Contains("cursor=cursor%26escape%3D1")) throw new Exception("Cursor was not escaped.");
        try { await client.RecordingAsync("../other"); throw new Exception("Accepted unsafe resource path."); } catch (ArgumentException) { }

        var attempts = 0;
        using var failed = new CloudClient("https://recappi.test", "fixture-token", new Handler(request =>
        {
            attempts++;
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.Unauthorized) { Content = new StringContent("private account information") });
        }));
        try { await failed.CreateUploadAsync("No retry", 100); throw new Exception("Accepted unauthorized upload."); }
        catch (CloudException error)
        {
            if (error.Status != HttpStatusCode.Unauthorized || error.Message.Contains("private account")) throw new Exception("Unsafe error handling.");
        }
        if (attempts != 1) throw new Exception("Non-idempotent creation was retried.");

        foreach (var operation in new[] { "json", "account", "upload" })
        {
            var stalled = new StalledStream();
            using var timedClient = new CloudClient("https://recappi.test", handler: new Handler(_ =>
                Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(stalled) })),
                requestTimeout: TimeSpan.FromMilliseconds(100));
            var pending = operation switch
            {
                "account" => (Task)timedClient.ValidateAccountAsync(account: new CloudAccount("https://recappi.test", "user-1", null, "fixture")),
                "upload" => timedClient.UploadAsync(ticket, file),
                _ => timedClient.ListAsync()
            };
            try { await pending.WaitAsync(TimeSpan.FromSeconds(5)); throw new Exception("Stalled response body did not time out: " + operation); }
            catch (OperationCanceledException) { }
            if (!stalled.Disposed) throw new Exception("Timed-out response stream was not disposed: " + operation);
        }

        var polls = 0;
        using var loginClient = new CloudClient("https://recappi.test", handler: new Handler(request => Task.FromResult(
            request.RequestUri!.AbsolutePath.EndsWith("/start")
                ? Json("{\"device_code\":\"device-fixture\",\"user_code\":\"ABCD\",\"verification_uri_complete\":\"https://recappi.test/verify?code=ABCD\",\"expires_in\":120,\"interval\":1}")
                : ++polls == 1 ? Json("{\"status\":\"pending\"}") : Json("{\"status\":\"authorized\",\"token\":\"fixture-secret-not-real\",\"user\":{\"id\":\"user-1\",\"email\":\"test@example.com\"}}"))));
        LoginPrompt? prompt = null;
        var account = await new DeviceLogin(loginClient, (_, _) => Task.CompletedTask).SignInAsync(value => prompt = value);
        if (prompt?.Code != "ABCD" || polls != 2 || account.UserId != "user-1") throw new Exception("Device login state flow failed.");
        var accountDirectory = Path.Combine(root, "account");
        var accounts = new AccountStore(accountDirectory);
        accounts.Save(account);
        if (accounts.Load() != account) throw new Exception("Protected account did not round trip.");
        if (Encoding.UTF8.GetString(File.ReadAllBytes(Path.Combine(accountDirectory, "account.dpapi"))).Contains(account.Token)) throw new Exception("Credential was stored unprotected.");
        if (account.ToString().Contains(account.Token)) throw new Exception("Account diagnostic leaks credential.");
        accounts.Clear();
        if (accounts.Load() is not null) throw new Exception("Sign-out did not clear local account.");
    }

    private static HttpResponseMessage Json(string text) => new(HttpStatusCode.OK) { Content = new StringContent(text, Encoding.UTF8, "application/json") };
    private sealed class StalledStream : MemoryStream
    {
        public override bool CanSeek => false;
        public bool Disposed { get; private set; }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        { await Task.Delay(Timeout.Infinite, cancellationToken); return 0; }
        protected override void Dispose(bool disposing) { Disposed = true; base.Dispose(disposing); }
    }
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        { token.ThrowIfCancellationRequested(); return send(request); }
    }
}
