using System.Net;
using System.Text;
using Microsoft.UI.Xaml.Controls;
using static Recappi.WinUI.Tests.TestApp;

namespace Recappi.WinUI.Tests;

internal static class AskTests
{
    public static async Task Run(string root)
    {
        foreach (var outcome in new[] { "success", "failure", "cancel" })
        foreach (var edit in new[] { "untouched", "draft", "clear" })
        {
            var started = new TaskCompletionSource(); var response = new TaskCompletionSource<HttpResponseMessage>();
            var suggestions = new TaskCompletionSource<HttpResponseMessage>();
            await using var host = new TestHost(Path.Combine(root, "ask-" + outcome + "-" + edit), (request, token) =>
            {
                if (request.RequestUri!.AbsolutePath.EndsWith("messages")) { started.TrySetResult(); return response.Task.WaitAsync(token); }
                if (request.RequestUri.AbsolutePath.EndsWith("ask-suggestions")) return suggestions.Task.WaitAsync(token);
                return TestHost.DefaultResponse(request, token);
            });
            await host.SignIn(); var owner = new LibraryWindow(host);
            var panel = new AskPanel(owner, host, host.Account.Snapshot.Account!, "recording", () => true, _ => Task.CompletedTask);
            owner.Content = panel.Root; owner.Show();
            try
            {
                await panel.Load().WaitAsync(TimeSpan.FromSeconds(3));
                panel.Root.Height = 200;
                panel.Root.Width = 380;
                Field<TextBlock>(panel, "history").Text = string.Join("\n", Enumerable.Repeat("Earlier question and answer", 60));
                var original = outcome == "success" && edit == "untouched"
                    ? string.Join("\n", Enumerable.Repeat("Long original question", 20)) : "Original question";
                var question = Field<TextBox>(panel, "question"); question.Text = original;
                var conversation = Field<ScrollViewer>(panel, "conversation");
                await Until(() => conversation.ScrollableHeight > 100, "Long question history did not scroll.");
                Check(conversation.ViewportHeight >= 80, "Compact question composer left too little room to read an answer.");
                var inputTop = question.TransformToVisual(panel.Root).TransformPoint(new Windows.Foundation.Point()).Y;
                Check(inputTop >= 0 && inputTop + question.ActualHeight <= panel.Root.ActualHeight, "Question input escaped the constrained panel.");
                var sending = Call(panel, "Send"); await started.Task.WaitAsync(TimeSpan.FromSeconds(3));
                await Until(() => conversation.VerticalOffset > 100, "Sending did not reveal the current question below long history.");
                Check(question.Text == "", "Sending did not clear old question.");
                if (edit != "untouched") question.Text = "Next draft";
                if (edit == "clear") question.Text = "";
                if (outcome == "success")
                {
                    const string citation = """{"segmentId":"second","startMs":3000,"endMs":5000,"snippet":"Controlled source"}""";
                    var stream = "event: citation\ndata: {\"citation\":" + citation + "}\n\n" +
                        "event: done\ndata: {\"content\":\"Controlled answer\",\"citations\":[" + citation + "]}\n\n";
                    response.TrySetResult(new(HttpStatusCode.OK) { Content = new StringContent(stream, Encoding.UTF8, "text/event-stream") });
                }
                else if (outcome == "failure") response.TrySetResult(new(HttpStatusCode.InternalServerError));
                else Field<CancellationTokenSource>(panel, "sending").Cancel();
                try { await sending; } catch (Exception) when (outcome != "success") { }
                var expected = edit == "draft" ? "Next draft" : edit == "clear" || outcome == "success" ? "" : original;
                Check(question.Text == expected, $"Ask draft changed after {outcome}/{edit}.");
                if (outcome == "success")
                {
                    var answer = Field<TextBlock>(panel, "answer");
                    Check(answer.Text == "Controlled answer", "Answer not rendered.");
                    Check(Field<StackPanel>(panel, "citations").Children.Count == 1, "Streaming and final citations appeared twice.");
                    await Until(() =>
                    {
                        var top = answer.TransformToVisual(conversation).TransformPoint(new Windows.Foundation.Point()).Y;
                        return answer.ActualHeight > 0 && top >= 0 && top + answer.ActualHeight <= conversation.ViewportHeight;
                    }, "The compact viewport did not reveal the returned answer.");
                }
                panel.Root.Height = 400;
                await Until(() => question.ActualHeight >= 88, "Growing the panel did not restore the multiline composer.");
                Check(question.Text == expected, "Resizing changed the next question draft.");
            }
            finally { panel.Dispose(); suggestions.TrySetCanceled(); response.TrySetCanceled(); owner.Close(); }
        }
    }
}
