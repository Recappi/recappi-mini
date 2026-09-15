using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Recappi.Core;
using Recappi.Desktop;

internal static class AskPanelTests
{
    public static async Task RunAsync(string root, Dispatcher dispatcher)
    {
        var store = new AccountStore(Path.Combine(root, "ask-account"));
        var account = new CloudAccount("https://example.test", "a", null, "test"); store.Save(account);
        var started = new TaskCompletionSource(); var response = new TaskCompletionSource<HttpResponseMessage>();
        var session = new AccountSession(store, (origin, token) => new CloudClient(origin, token, new Handler(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path.EndsWith("get-session")) return Task.FromResult(Json("""{"session":{},"user":{"id":"a"}}"""));
            if (path.EndsWith("messages")) { started.TrySetResult(); return response.Task; }
            if (path.EndsWith("ask-suggestions")) return Task.FromResult(Json("""{"suggestions":["What next?"]}"""));
            return Task.FromResult(Json("""{"messages":[{"id":"m1","role":"assistant","content":"History","citations":[]}]}"""));
        })));
        await session.RestoreAsync();
        var panel = new AskPanel(); var window = new Window { Content = panel, ShowActivated = false }; window.Show();
        await panel.SelectAsync(session, account, "r1");
        if (((TextBox)panel.FindName("Conversation")).Text != "Recappi：\nHistory") throw new Exception("Ask history not rendered.");
        ((TextBox)panel.FindName("Question")).Text = "Question for r1";
        ((Button)panel.FindName("SendButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await panel.SelectAsync(session, account, "r2");
        response.SetResult(new(HttpStatusCode.OK) { Content = new StringContent("event: done\ndata: {\"content\":\"OLD ANSWER\"}\n\n", Encoding.UTF8, "text/event-stream") });
        await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        if (((TextBox)panel.FindName("Conversation")).Text.Contains("OLD ANSWER") || ((TextBox)panel.FindName("Question")).Text.Length != 0) throw new Exception("Ask response leaked across recording selection.");
        panel.Clear(); window.Close();
        Console.WriteLine("PASS native Ask history, send and switching recording rejects delayed answer.");
    }
    private static HttpResponseMessage Json(string text) => new(HttpStatusCode.OK) { Content = new StringContent(text, Encoding.UTF8, "application/json") };
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => send(request);
    }
}
