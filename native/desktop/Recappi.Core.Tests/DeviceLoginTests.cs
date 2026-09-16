using System.Net;
using System.Text;
using System.Text.Json;
using Recappi.Core;

internal static class DeviceLoginTests
{
    private const string Authorized = "{\"status\":\"authorized\",\"token\":\"fixture-token\",\"user\":{\"id\":\"fixture-user\"}}";

    public static async Task RunAsync()
    {
        // The poll was timely, but its authorized response crossed the deadline.
        var lateClock = new Clock();
        using (var client = Client(() => { lateClock.Advance(120); return Authorized; }))
            await ExpectAsync<TimeoutException>(() => Login(client, lateClock).SignInAsync(_ => { }), "Accepted authorization after the code expired.");

        var clock = new Clock();
        var waits = new List<double>();
        var replies = new Queue<string>([
            "{\"status\":\"pending\",\"interval\":2}",
            "{\"status\":\"slow_down\"}",
            "{\"status\":\"slow_down\",\"interval\":9}", Authorized]);
        using (var client = Client(() => replies.Dequeue()))
        {
            LoginPrompt? prompt = null;
            var account = await new DeviceLogin(client, (wait, token) =>
            {
                token.ThrowIfCancellationRequested(); waits.Add(wait.TotalSeconds); clock.Advance(wait.TotalSeconds); return Task.CompletedTask;
            }, clock).SignInAsync(value => prompt = value);
            if (!waits.SequenceEqual(new double[] { 1, 2, 7, 9 }) || replies.Count != 0 || account.UserId != "fixture-user" || prompt?.Code != "TEST")
                throw new Exception("Device login lost pending/backoff intervals or authorization.");
        }

        foreach (var status in new[] { "denied", "expired", "unknown" })
        {
            var count = 0;
            using var client = Client(() => { count++; return JsonSerializer.Serialize(new { status }); });
            var login = Login(client, new Clock());
            if (status == "denied") await ExpectAsync<InvalidOperationException>(() => login.SignInAsync(_ => { }), "Accepted denied login.");
            else if (status == "expired") await ExpectAsync<TimeoutException>(() => login.SignInAsync(_ => { }), "Accepted expired login.");
            else await ExpectAsync<InvalidDataException>(() => login.SignInAsync(_ => { }), "Accepted unknown login state.");
            if (count != 1) throw new Exception("Terminal device status was polled again.");
        }

        var expiryClock = new Clock();
        var expiryPolls = 0;
        using (var client = Client(() => { expiryPolls++; return "{\"status\":\"pending\"}"; }, expires: 3))
            await ExpectAsync<TimeoutException>(() => Login(client, expiryClock).SignInAsync(_ => { }), "Pending code did not expire locally.");
        if (expiryPolls != 2) throw new Exception("Device login polled at or after its local deadline.");

        var cappedWaits = new List<double>();
        var cappedClock = new Clock();
        var cappedPolls = 0;
        using (var client = Client(() => ++cappedPolls == 1 ? "{\"status\":\"slow_down\"}" : Authorized, expires: 3600, interval: 58))
            await new DeviceLogin(client, (wait, _) =>
            { cappedWaits.Add(wait.TotalSeconds); cappedClock.Advance(wait.TotalSeconds); return Task.CompletedTask; }, cappedClock).SignInAsync(_ => { });
        if (!cappedWaits.SequenceEqual(new double[] { 58, 60 })) throw new Exception("Slow-down fallback exceeded its interval limit.");

        using (var cancelled = new CancellationTokenSource())
        using (var client = Client(() => throw new Exception("Cancelled login still polled.")))
            await ExpectAsync<OperationCanceledException>(() => Login(client, new Clock()).SignInAsync(_ => cancelled.Cancel(), cancelled.Token), "Cancelled prompt continued polling.");

        foreach (var response in new[] { "{\"status\":\"pending\",\"interval\":0}", "{\"status\":\"slow_down\",\"interval\":61}", "{\"status\":\"authorized\",\"token\":\"\",\"user\":{\"id\":\"fixture-user\"}}" })
        {
            var polls = 0;
            using var client = Client(() => { if (++polls > 1) throw new Exception("Invalid poll response was retried."); return response; });
            await ExpectAsync<InvalidDataException>(() => Login(client, new Clock()).SignInAsync(_ => { }), "Accepted invalid poll response.");
        }

        foreach (var verify in new[] { "https://untrusted.test/verify", "https://user@recappi.test/verify" })
        {
            using var client = Client(() => throw new Exception("Invalid verification URL was polled."), verify: verify);
            await ExpectAsync<InvalidDataException>(() => Login(client, new Clock()).SignInAsync(_ => throw new Exception("Invalid verification URL was displayed.")), "Accepted an unsafe verification URL.");
        }
        foreach (var interval in new[] { 0d, -1d, 61d })
        {
            using var client = Client(() => Authorized, interval: interval);
            await ExpectAsync<InvalidDataException>(() => Login(client, new Clock()).SignInAsync(_ => throw new Exception("Invalid timing was displayed.")), "Accepted invalid polling timing.");
        }
        Console.WriteLine("PASS device login pending/backoff, denial, expiry, unknown state, cancellation and verification/timing validation.");
    }

    private static DeviceLogin Login(CloudClient client, Clock clock) => new(client, (wait, token) =>
    { token.ThrowIfCancellationRequested(); clock.Advance(wait.TotalSeconds); return Task.CompletedTask; }, clock);

    private static CloudClient Client(Func<string> poll, double expires = 120, double interval = 1, string verify = "https://recappi.test/verify?code=TEST") =>
        new("https://recappi.test", handler: new Handler(poll, JsonSerializer.Serialize(new
        { device_code = "fixture-device", user_code = "TEST", verification_uri_complete = verify, expires_in = expires, interval })));

    private static async Task ExpectAsync<T>(Func<Task> action, string failure) where T : Exception
    {
        try { await action(); }
        catch (T) { return; }
        throw new Exception(failure);
    }

    private sealed class Clock : TimeProvider
    {
        private DateTimeOffset now = new(2026, 1, 1, 0, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => now;
        public void Advance(double seconds) => now = now.AddSeconds(seconds);
    }

    private sealed class Handler(Func<string> poll, string start) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            { Content = new StringContent(request.RequestUri!.AbsolutePath.EndsWith("/start") ? start : poll(), Encoding.UTF8, "application/json") });
        }
    }
}
