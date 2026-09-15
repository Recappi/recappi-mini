using System.Net;
using System.Text;
using System.Text.Json;
using Recappi.Core;

internal static class AskTests
{
    public static async Task RunAsync()
    {
        var posts = 0;
        var body = ": heartbeat\r\nevent: answer_delta\r\ndata: {\"delta\":\"你好\"}\r\n\r\nevent: citation\ndata: {\"citation\":{\"segmentId\":\"seg-1\",\"startMs\":1200,\"snippet\":\"原文\"}}\n\nevent: done\rdata: {\"content\":\"你好，会议\",\rdata: \"citations\":[]}\r\r";
        using var client = new CloudClient("https://example.test", "test-token", new Handler(async request =>
        {
            posts++;
            if (request.Method != HttpMethod.Post || !request.RequestUri!.AbsolutePath.EndsWith("/r1/ask-thread/messages") || request.Headers.Accept.Single().MediaType != "text/event-stream") throw new Exception("Ask route/headers incorrect.");
            using var payload = JsonDocument.Parse(await request.Content!.ReadAsStringAsync());
            if (payload.RootElement.GetProperty("question").GetString() != "问题" || !payload.RootElement.GetProperty("webSearch").GetBoolean()) throw new Exception("Ask request lost options.");
            if (payload.RootElement.TryGetProperty("model", out _)) throw new Exception("Unspecified optional model must be omitted, not null.");
            return Response(body);
        }));
        var events = new List<AskEvent>();
        await foreach (var item in client.AskAsync("r1", "问题", true)) events.Add(item);
        if (posts != 1 || events.Count != 3 || events[0].Text != "你好" || events[1].Citations[0].StartMs != 1200 || events[2].Text != "你好，会议") throw new Exception("Split UTF8/SSE frames were not decoded.");
        foreach (var broken in new[] { "event: answer_delta\ndata: {\"delta\":\"partial\"}\n\n", "event: error\ndata: {\"message\":\"private server detail\"}\n\n" })
        {
            using var failureClient = new CloudClient("https://example.test", handler: new Handler(_ => Task.FromResult(Response(broken))));
            var failed = false;
            try { await foreach (var item in failureClient.AskAsync("r1", "question")) { } }
            catch (Exception error) when (error is EndOfStreamException or InvalidDataException) { failed = true; }
            if (!failed) throw new Exception("Truncated/error stream appeared successful.");
        }
        using var oversized = new MemoryStream(Encoding.UTF8.GetBytes("data: " + new string('x', 1024 * 1024 + 1)));
        var bounded = false;
        try { await foreach (var item in AskEventReader.ReadAsync(oversized)) { } } catch (InvalidDataException) { bounded = true; }
        if (!bounded) throw new Exception("SSE line limit not enforced.");
    }
    private static HttpResponseMessage Response(string body)
    {
        var content = new StreamContent(new FragmentStream(Encoding.UTF8.GetBytes(body)));
        content.Headers.ContentType = new("text/event-stream");
        return new(HttpStatusCode.OK) { Content = content };
    }
    private sealed class FragmentStream(byte[] bytes) : MemoryStream(bytes)
    {
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default) => base.ReadAsync(buffer[..Math.Min(1, buffer.Length)], cancellationToken);
    }
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => send(request);
    }
}
