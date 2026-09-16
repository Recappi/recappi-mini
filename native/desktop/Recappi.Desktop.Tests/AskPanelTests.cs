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
    public static async Task PreviewAsync(string root, bool slowSuggestions = false)
    {
        var store = new AccountStore(Path.Combine(root, "ask-preview"));
        var account = new CloudAccount("https://example.test", "a", null, "test"); store.Save(account);
        TaskCompletionSource<HttpResponseMessage>? pending = null;
        var suggestions = new TaskCompletionSource<HttpResponseMessage>();
        var session = new AccountSession(store, (origin, token) => new CloudClient(origin, token, new Handler(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path.EndsWith("get-session")) return Task.FromResult(Json("""{"session":{},"user":{"id":"a"}}"""));
            if (path.EndsWith("messages")) { pending = new(); return pending.Task; }
            if (path.EndsWith("ask-suggestions")) return slowSuggestions ? suggestions.Task : Task.FromResult(Json("""{"suggestions":[]}"""));
            return Task.FromResult(Json("""{"messages":[]}"""));
        })));
        await session.RestoreAsync();
        var panel = new AskPanel();
        var content = new DockPanel();
        var controls = new StackPanel { Orientation = Orientation.Horizontal };
        controls.Children.Add(new TextBlock { Text = slowSuggestions ? "推荐请求挂起；受控响应，不连接云端" : "受控响应测试，不连接云端", Margin = new Thickness(8) });
        var complete = new Button { Content = "返回成功", Margin = new Thickness(8) };
        complete.Click += (_, _) => pending?.TrySetResult(new(HttpStatusCode.OK) { Content = new StringContent("event: done\ndata: {\"content\":\"Controlled answer completed.\"}\n\n", Encoding.UTF8, "text/event-stream") });
        controls.Children.Add(complete);
        var fail = new Button { Content = "返回失败", Margin = new Thickness(8) };
        fail.Click += (_, _) => pending?.TrySetResult(new(HttpStatusCode.InternalServerError));
        controls.Children.Add(fail);
        DockPanel.SetDock(controls, Dock.Top); content.Children.Add(controls); content.Children.Add(panel);
        var closed = new TaskCompletionSource();
        var window = new Window { Title = "Recappi Ask draft validation", Width = 800, Height = 650, Content = content };
        window.Closed += (_, _) => { panel.Clear(); pending?.TrySetCanceled(); suggestions.TrySetCanceled(); closed.TrySetResult(); };
        window.Show(); await panel.SelectAsync(session, account, "preview"); await closed.Task;
    }
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
            if (path.EndsWith("ask-suggestions")) return Task.FromResult(Json("""{"suggestions":[{"question":"What next?","reason":"Next steps"}]}"""));
            return Task.FromResult(Json("""{"messages":[{"id":"m1","role":"assistant","content":"History","citations":[]}]}"""));
        })));
        await session.RestoreAsync();
        var panel = new AskPanel(); var window = new Window { Content = panel, ShowActivated = false }; window.Show();
        await panel.SelectAsync(session, account, "r1");
        if (((TextBox)panel.FindName("Conversation")).Text != "Recappi：\nHistory") throw new Exception("Ask history not rendered.");
        var suggestions = (ComboBox)panel.FindName("Suggestions");
        if (suggestions.Items.Count != 1 || (string)suggestions.Items[0] != "What next?") throw new Exception("Backend object suggestion was not displayed.");
        suggestions.SelectedIndex = 0;
        if (((TextBox)panel.FindName("Question")).Text != "What next?") throw new Exception("Selecting a backend suggestion did not fill the question.");
        ((TextBox)panel.FindName("Question")).Text = "Question for r1";
        ((Button)panel.FindName("SendButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        await started.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await panel.SelectAsync(session, account, "r2");
        response.SetResult(new(HttpStatusCode.OK) { Content = new StringContent("event: done\ndata: {\"content\":\"OLD ANSWER\"}\n\n", Encoding.UTF8, "text/event-stream") });
        await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
        if (((TextBox)panel.FindName("Conversation")).Text.Contains("OLD ANSWER") || ((TextBox)panel.FindName("Question")).Text.Length != 0) throw new Exception("Ask response leaked across recording selection.");
        panel.Clear(); window.Close();
        await DraftAsync(root, dispatcher);
        await SlowSuggestionsAsync(root, dispatcher);
        Console.WriteLine("PASS native Ask history, send and switching recording rejects delayed answer.");
    }
    private static async Task SlowSuggestionsAsync(string root, Dispatcher dispatcher)
    {
        var store = new AccountStore(Path.Combine(root, "ask-slow-suggestions"));
        var account = new CloudAccount("https://example.test", "a", null, "test"); store.Save(account);
        var oldSuggestions = new TaskCompletionSource<HttpResponseMessage>();
        var reply = new TaskCompletionSource<HttpResponseMessage>();
        var session = new AccountSession(store, (origin, token) => new CloudClient(origin, token, new Handler(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path.EndsWith("get-session")) return Task.FromResult(Json("""{"session":{},"user":{"id":"a"}}"""));
            if (path.EndsWith("messages")) return reply.Task;
            if (path.EndsWith("ask-suggestions")) return path.Contains("/r1/") ? oldSuggestions.Task : Task.FromResult(Json("""{"suggestions":["Current suggestion"]}"""));
            return Task.FromResult(Json("""{"messages":[]}"""));
        })));
        await session.RestoreAsync();
        var panel = new AskPanel(); var window = new Window { Content = panel, ShowActivated = false }; window.Show();
        try
        {
            var selection = panel.SelectAsync(session, account, "r1");
            await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            var send = (Button)panel.FindName("SendButton");
            if (!selection.IsCompletedSuccessfully || !send.IsEnabled) throw new Exception("Optional Ask suggestions blocked the loaded conversation.");
            ((TextBox)panel.FindName("Question")).Text = "Send while suggestions are pending";
            send.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            await panel.SelectAsync(session, account, "r2");
            oldSuggestions.SetResult(Json("""{"suggestions":["Stale suggestion"]}"""));
            reply.SetResult(new(HttpStatusCode.OK) { Content = new StringContent("event: done\ndata: {\"content\":\"Stale answer\"}\n\n", Encoding.UTF8, "text/event-stream") });
            await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            var suggestions = (ComboBox)panel.FindName("Suggestions");
            if (suggestions.Items.Count != 1 || (string)suggestions.Items[0] != "Current suggestion" || ((TextBox)panel.FindName("Conversation")).Text.Contains("Stale answer"))
                throw new Exception("Delayed Ask work leaked across recording selection.");
        }
        finally { panel.Clear(); oldSuggestions.TrySetCanceled(); reply.TrySetCanceled(); window.Close(); }
        Console.WriteLine("PASS slow optional Ask suggestions do not block sending and cannot leak across recordings.");
    }
    private static async Task DraftAsync(string root, Dispatcher dispatcher)
    {
        var store = new AccountStore(Path.Combine(root, "ask-draft-account"));
        var account = new CloudAccount("https://example.test", "a", null, "test"); store.Save(account);
        TaskCompletionSource<HttpResponseMessage>? response = null;
        var session = new AccountSession(store, (origin, token) => new CloudClient(origin, token, new Handler(request =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path.EndsWith("get-session")) return Task.FromResult(Json("""{"session":{},"user":{"id":"a"}}"""));
            if (path.EndsWith("messages")) return response!.Task;
            if (path.EndsWith("ask-suggestions")) return Task.FromResult(Json("""{"suggestions":[]}"""));
            return Task.FromResult(Json("""{"messages":[]}"""));
        })));
        await session.RestoreAsync();
        var panel = new AskPanel(); var window = new Window { Content = panel, ShowActivated = false }; window.Show();
        try
        {
            await panel.SelectAsync(session, account, "r1");
            var question = (TextBox)panel.FindName("Question");
            var send = (Button)panel.FindName("SendButton");
            foreach (var outcome in new[] { "success", "failure", "cancel" })
            foreach (var edit in new[] { "untouched", "next draft", "cleared" })
            {
                response = new();
                question.Text = "  Original question  ";
                send.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                if (question.Text.Length != 0) throw new Exception("Submitted Ask draft was not cleared at send time.");
                if (edit != "untouched") question.Text = "Next question";
                if (edit == "cleared") question.Clear();
                if (outcome == "cancel") ((Button)panel.FindName("CancelButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                response.SetResult(outcome == "failure" ? new(HttpStatusCode.InternalServerError) :
                    new(HttpStatusCode.OK) { Content = new StringContent("event: done\ndata: {\"content\":\"Answer\"}\n\n", Encoding.UTF8, "text/event-stream") });
                var deadline = DateTime.UtcNow.AddSeconds(5);
                while (!send.IsEnabled && DateTime.UtcNow < deadline) await Task.Delay(10);
                await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                var expected = edit == "next draft" ? "Next question" : edit == "untouched" && outcome != "success" ? "  Original question  " : "";
                if (!send.IsEnabled || question.Text != expected) throw new Exception($"Ask {outcome}/{edit} lost or overwrote the draft.");
            }
        }
        finally { panel.Clear(); window.Close(); }
        Console.WriteLine("PASS Ask draft preservation and retry after success, failure and cancellation.");
    }
    private static HttpResponseMessage Json(string text) => new(HttpStatusCode.OK) { Content = new StringContent(text, Encoding.UTF8, "application/json") };
    private sealed class Handler(Func<HttpRequestMessage, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => send(request);
    }
}
