using System.Net;
using System.Text.Json;
using Microsoft.UI.Xaml.Controls;
using Recappi.Core;
using static Recappi.WinUI.Tests.TestApp;

namespace Recappi.WinUI.Tests;

internal static class ReviewTests
{
    public static async Task Run(string root)
    {
        var posts = new List<string>(); var active = false; var current = true; var failPost = false; var failFetch = false;
        await using var host = new TestHost(Path.Combine(root, "review"), async (request, token) =>
        {
            if (request.Method == HttpMethod.Post && request.RequestUri!.AbsolutePath.EndsWith("transcribe"))
            {
                posts.Add(await request.Content!.ReadAsStringAsync(token)); active = true;
                return failPost ? new HttpResponseMessage(HttpStatusCode.InternalServerError) : TestHost.Json("""{"jobId":"j2"}""");
            }
            if (request.RequestUri!.AbsolutePath.EndsWith("jobs"))
                return failFetch ? new HttpResponseMessage(HttpStatusCode.InternalServerError) : TestHost.Json(active
                    ? """{"items":[{"id":"j2","status":"queued"}]}""" : """{"items":[{"id":"j1","status":"succeeded","transcriptId":"t1"}]}""");
            return await TestHost.DefaultResponse(request, token);
        });
        await host.SignIn(); var owner = new LibraryWindow(host);
        var panel = new ReviewPanel(owner, host, host.Account.Snapshot.Account!, new("r", "Fixture", "completed", 1000), () => current, _ => Task.CompletedTask);
        owner.Content = panel.Root; owner.Show();
        try
        {
            await panel.Load(); panel.UpdateTranscript(new("text", "summary", "completed"));
            owner.ConfirmAction = (_, _, _) => { current = false; return Task.FromResult(true); };
            await Call(panel, "Submit", "title", "message", 0);
            Check(posts.Count == 0, "Reprocessing posted after confirmation context changed.");
            current = true; await panel.Load(); owner.ConfirmAction = (_, _, _) => Task.FromResult(true);
            await Call(panel, "Submit", "title", "message", 0);
            Check(posts.Count == 1, "Expected one retranscription request.");
            using var body = JsonDocument.Parse(posts[0]);
            Check(body.RootElement.GetProperty("provider").GetString() == "gemini" && body.RootElement.GetProperty("force").GetBoolean(), "Retranscription lost Gemini/force contract.");
            Check(!Field<Button>(panel, "transcribe").IsEnabled, "Active task left retranscription enabled.");
            await Call(panel, "Submit", "title", "message", 0); Check(posts.Count == 1, "Repeated processing submission escaped guard.");
            active = false; await panel.Load(); failPost = true;
            await Call(panel, "Submit", "title", "message", 0);
            Check(Field<bool>(panel, "uncertain"), "Uncertain submission was treated as confirmed failure.");
            failFetch = true; await panel.Load();
            Check(!Field<Button>(panel, "transcribe").IsEnabled, "Failed reconciliation allowed duplicate submission.");
        }
        finally { panel.Dispose(); owner.Close(); }
    }
}
