using System.Net;
using System.Text;
using Recappi.Core;

internal static class AccountExpiryTests
{
    public static async Task RunAsync(string root)
    {
        var store = new AccountStore(Path.Combine(root, "expiry-account"));
        var old = new CloudAccount("https://example.test", "same-user", null, "old-fixture");
        store.Save(old);
        var delayed = new TaskCompletionSource<HttpResponseMessage>(TaskCreationOptions.RunContinuationsAsynchronously);
        var session = new AccountSession(store, (origin, token) => new CloudClient(origin, token, new Handler(request =>
        {
            if (request.RequestUri!.AbsolutePath.EndsWith("get-session")) return Task.FromResult(Json("""{"session":{},"user":{"id":"same-user"}}"""));
            if (token == "old-fixture") return delayed.Task;
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.Unauthorized));
        })));
        await session.RestoreAsync();
        using var oldClient = session.Client(session.Snapshot.Account!);
        var oldRequest = oldClient.ListAsync();
        if (oldRequest.IsCompleted) throw new Exception("Delayed rejection fixture did not remain in flight.");
        store.Save(old with { Token = "new-fixture" });
        await session.RestoreAsync();
        delayed.SetResult(new(HttpStatusCode.Unauthorized));
        await Rejected(oldRequest);
        if (session.Snapshot.State != AccountState.SignedIn || session.Snapshot.Account?.Token != "new-fixture") throw new Exception("Old token rejection expired a renewed login.");
        using var current = session.Client(session.Snapshot.Account!);
        await Rejected(current.ListAsync());
        if (session.Snapshot.State != AccountState.Expired) throw new Exception("Current API rejection did not expire the account.");
        await session.RefreshAsync();
        if (session.Snapshot.State != AccountState.SignedIn) throw new Exception("Explicit validation could not restore an expired account.");
        await session.SignOutAsync();
        await Rejected(current.ListAsync());
        if (session.Snapshot.State != AccountState.SignedOut || session.Snapshot.Account is not null) throw new Exception("Late rejection restored a signed-out identity.");
    }
    private static async Task Rejected(Task request)
    {
        try { await request; } catch (CloudException error) when (error.Status == HttpStatusCode.Unauthorized) { return; }
        throw new Exception("Expected unauthorized response.");
    }
    private static HttpResponseMessage Json(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => send(request);
    }
}
