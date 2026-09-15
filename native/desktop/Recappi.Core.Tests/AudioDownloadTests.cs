using System.Net;
using Recappi.Core;

internal static class AudioDownloadTests
{
    public static async Task RunAsync(string root)
    {
        var directory = Path.Combine(root, "downloads"); Directory.CreateDirectory(directory);
        var target = Path.Combine(directory, "recording.audio");
        byte[] payload = [82, 73, 70, 70, 1, 2, 3];
        using (var client = new CloudClient("https://example.test", "test", new Handler(request =>
        {
            if (request.Headers.Authorization?.Parameter != "test" || !request.RequestUri!.AbsolutePath.EndsWith("/r1/audio")) throw new Exception("Audio authentication/route missing.");
            var content = new ByteArrayContent(payload); content.Headers.ContentType = new("audio/wav");
            return new(HttpStatusCode.OK) { Content = content };
        })))
        {
            var path = await client.DownloadAudioAsync("r1", target);
            if (Path.GetExtension(path) != ".wav" || !File.ReadAllBytes(path).SequenceEqual(payload)) throw new Exception("Audio type/bytes changed.");
        }
        using (var client = new CloudClient("https://example.test", handler: new Handler(_ =>
        {
            var content = new ByteArrayContent([9]); content.Headers.ContentLength = 100; content.Headers.ContentType = new("audio/wav");
            return new(HttpStatusCode.OK) { Content = content };
        })))
        {
            var failed = false;
            try { await client.DownloadAudioAsync("r1", target); } catch (EndOfStreamException) { failed = true; }
            if (!failed || !File.ReadAllBytes(Path.ChangeExtension(target, ".wav")).SequenceEqual(payload) || Directory.EnumerateFiles(directory, "*.partial").Any()) throw new Exception("Incomplete download replaced valid audio or left a partial file.");
        }
    }
    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => Task.FromResult(send(request));
    }
}
