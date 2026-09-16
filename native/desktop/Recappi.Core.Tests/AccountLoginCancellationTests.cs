using System.Net;
using System.Text;
using Recappi.Core;

internal static class AccountLoginCancellationTests
{
    public static async Task RunAsync(string root)
    {
        foreach (var existing in new[] { false, true })
        foreach (var external in new[] { false, true })
            await RunScenarioAsync(Path.Combine(root, $"login-cancel-{existing}-{external}"), existing, external);
    }

    private static async Task RunScenarioAsync(string root, bool existing, bool external)
    {
        var store = new AccountStore(root);
        var previous = new CloudAccount("https://recappi.test", "previous-user", null, "previous-fixture");
        if (existing) store.Save(previous);
        using var cancellation = new CancellationTokenSource();
        AccountSession? session = null;
        var cancelResponse = true;
        var cancellations = 0;
        var acceptedNewAccount = 0;
        session = new AccountSession(store, (origin, token) => new CloudClient(origin, token, new Handler(request =>
        {
            return request.RequestUri!.AbsolutePath switch
            {
                "/api/auth/get-session" => Json("""{"session":{},"user":{"id":"previous-user"}}"""),
                "/api/device-auth/start" => Json("""{"device_code":"fixture-device","user_code":"TEST","verification_uri_complete":"https://recappi.test/verify?code=TEST","expires_in":120,"interval":0.001}"""),
                "/api/device-auth/poll" => new(HttpStatusCode.OK)
                {
                    // Dispose runs after JSON parsing, before the completed response
                    // reaches AccountSession. This deterministically exercises a late cancel.
                    Content = new StreamContent(new OnDisposeStream(
                        """{"status":"authorized","token":"new-fixture","user":{"id":"new-user"}}""", () =>
                        {
                            if (!cancelResponse) return;
                            cancellations++;
                            if (external) cancellation.Cancel(); else session!.CancelLogin();
                        }))
                },
                _ => throw new Exception("Unexpected login cancellation request.")
            };
        })));
        await session.RestoreAsync();
        var before = session.Snapshot;
        var savedPath = Path.Combine(root, "account.dpapi");
        var savedBytes = existing ? await File.ReadAllBytesAsync(savedPath) : null;
        session.Changed += value =>
        {
            if (value.State == AccountState.SignedIn && value.Account?.UserId == "new-user") acceptedNewAccount++;
        };
        await session.SignInAsync(previous.Origin, _ => { }, cancellation.Token).WaitAsync(TimeSpan.FromSeconds(5));
        if (cancellations != 1) throw new Exception("Late cancellation fixture did not execute exactly once.");
        if (acceptedNewAccount != 0 || session.Snapshot.State != before.State || session.Snapshot.Account != before.Account)
            throw new Exception("A cancelled login accepted a late authorized response.");
        if (store.Load() != (existing ? previous : null)) throw new Exception("Cancelled login replaced the saved account.");
        if (savedBytes is not null)
        {
            var afterBytes = await File.ReadAllBytesAsync(savedPath);
            if (!savedBytes.SequenceEqual(afterBytes)) throw new Exception("Cancelled login rewrote protected credentials.");
        }
        if (!existing && Directory.Exists(root)) throw new Exception("Cancelled first login created account storage.");

        cancelResponse = false;
        await session.SignInAsync(previous.Origin, _ => { }).WaitAsync(TimeSpan.FromSeconds(5));
        if (acceptedNewAccount != 1 || session.Snapshot.State != AccountState.SignedIn || store.Load()?.UserId != "new-user")
            throw new Exception("A fresh login could not succeed after cancellation.");
    }

    private static HttpResponseMessage Json(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => Task.FromResult(send(request));
    }
    private sealed class OnDisposeStream(string body, Action action) : MemoryStream(Encoding.UTF8.GetBytes(body))
    {
        private int completed;
        protected override void Dispose(bool disposing)
        {
            base.Dispose(disposing);
            if (disposing && Interlocked.Exchange(ref completed, 1) == 0) action();
        }
    }
}
