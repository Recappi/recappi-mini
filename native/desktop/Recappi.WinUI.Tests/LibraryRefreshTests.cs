using System.Text.Json;
using System.Net;
using System.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Recappi.Core;
using Windows.Media.Playback;

namespace Recappi.WinUI.Tests;

public partial class TestApp
{
    private static async Task LibraryRefresh(string root)
    {
        var available = false;
        await using var host = new TestHost(Path.Combine(root, "library-refresh"), (request, token) =>
            request.RequestUri!.AbsolutePath == "/api/recordings"
                ? Task.FromResult(TestHost.Json(available ? """{"items":[{"id":"uploaded","title":"Native Windows caption test and design review","status":"completed","durationMs":3000}]}""" : """{"items":[]}"""))
                : request.RequestUri.AbsolutePath.EndsWith("/transcript")
                ? Task.FromResult(TestHost.Json("""{"text":"Short recording","summaryStatus":"skipped","summaryJson":null}"""))
                : request.RequestUri.AbsolutePath.EndsWith("/ask-thread/messages")
                ? Task.FromResult(PhasedAnswerResponse())
                : request.RequestUri.AbsolutePath.EndsWith("/ask-thread")
                ? Task.FromResult(TestHost.Json("""{"messages":[{"role":"user","content":"When is the design review scheduled?"},{"role":"assistant","content":"The design review is scheduled for tomorrow."}]}"""))
                : TestHost.DefaultResponse(request, token));
        await host.SignIn();
        var recording = host.Store.Create("Local fixture") with { State = RecordingState.Done, DurationMs = 3000 };
        host.Store.Save(recording);
        using (var writer = new BinaryWriter(File.Create(recording.AudioPath)))
        {
            const int bytes = 48000 * 2 * 3;
            writer.Write("RIFF"u8); writer.Write(36 + bytes); writer.Write("WAVEfmt "u8);
            writer.Write(16); writer.Write((short)1); writer.Write((short)1); writer.Write(48000);
            writer.Write(96000); writer.Write((short)2); writer.Write((short)16);
            writer.Write("data"u8); writer.Write(bytes); writer.Write(new byte[bytes]);
        }
        var window = new LibraryWindow(host); window.Show();
        try
        {
            await window.SelectRecording(recording.Id); await Call(window, "LoadAudio");
            await Call(window, "SeekAudio", TimeSpan.FromSeconds(1));
            var player = Field<MediaPlayer>(window, "player");
            await Until(() => Field<bool>(window, "mediaOpened") && Math.Abs(player.PlaybackSession.Position.TotalSeconds - 1) < .15, "Local audio did not seek.");
            var account = host.Account.Snapshot.Account!;
            var folder = Path.Combine(host.ApplicationRoot, "Processing", account.Partition); Directory.CreateDirectory(folder);
            var link = new ProcessingEntry(recording.Id, account.Partition, recording.Title, ProcessingStage.Completed, new("uploaded", 1, 1), UploadCompleted: true);
            await File.WriteAllTextAsync(Path.Combine(folder, recording.Id + ".json"), JsonSerializer.Serialize(link, new JsonSerializerOptions(JsonSerializerDefaults.Web)));
            available = true; await window.Refresh();
            Check(Field<Button>(window, "cloudCopy").Visibility == Visibility.Visible, "New cloud copy is inaccessible after refresh.");
            Check(Field<bool>(window, "localView") && ReferenceEquals(player, Field<MediaPlayer>(window, "player")) && Math.Abs(player.PlaybackSession.Position.TotalSeconds - 1) < .15,
                "Background copy discovery interrupted local playback.");
            await Call(window, "Select", false);
            Check(Field<SummaryDocument>(window, "summary").Text.Contains("未生成摘要"), "Skipped summary left an unexplained blank pane.");
            var ask = Field<AskPanel>(window, "ask");
            var draft = Field<TextBox>(ask, "question"); draft.Text = "Keep this draft";
            await window.Refresh();
            Check(ReferenceEquals(ask, Field<AskPanel>(window, "ask")) && draft.Text == "Keep this draft", "Routine list refresh discarded an active cloud draft.");
            var sections = Field<SelectorBar>(window, "tabs"); sections.SelectedItem = sections.Items[2];
            var scale = window.Content.XamlRoot.RasterizationScale;
            window.AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(820 * scale), (int)(560 * scale)));
            var conversation = Field<ScrollViewer>(ask, "conversation");
            await Until(() => ask.Root.IsLoaded && conversation.ViewportHeight > 0, "Minimum-size cloud panel did not load.");
            Check(conversation.ViewportHeight >= 80, "Long title and both recording copies squeezed the answer viewport below readable height.");
            draft.Text = "What should be sent after the review?";
            await Call(ask, "Send");
            var citation = (Button)Field<StackPanel>(ask, "citations").Children.Single();
            await Until(() =>
            {
                var top = citation.TransformToVisual(conversation).TransformPoint(new Windows.Foundation.Point()).Y;
                var response = Field<TextBlock>(ask, "answer");
                var answerTop = response.TransformToVisual(conversation).TransformPoint(new Windows.Foundation.Point()).Y;
                return citation.ActualHeight > 0 && top >= 0 && top + citation.ActualHeight <= conversation.ViewportHeight
                    && answerTop >= 0 && answerTop + response.ActualHeight <= conversation.ViewportHeight;
            }, "The answer citation was clipped in the minimum window with both recording copies.");
        }
        finally { window.Close(); }
    }

    private static HttpResponseMessage PhasedAnswerResponse()
    {
        var content = new StreamContent(new PhasedAnswerStream());
        content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("text/event-stream");
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = content };
    }

    private sealed class PhasedAnswerStream : MemoryStream
    {
        private static readonly byte[] Delta = Encoding.UTF8.GetBytes("event: answer_delta\ndata: {\"delta\":\"The meeting notes should be sent after the review.\"}\n\n");
        public PhasedAnswerStream() : base(Delta.Concat(Encoding.UTF8.GetBytes("event: done\ndata: {\"content\":\"The meeting notes should be sent after the review.\",\"citations\":[{\"startMs\":0,\"endMs\":19000,\"snippet\":\"In test, the team will review the design tomorrow. Please send the meeting notes after the review. This is a recappy native windows caption test. The team will review the design tomorrow. Please send the meeting notes after the review.\"}]}\n\n")).ToArray()) { }
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            if (Position == Delta.Length) await Task.Delay(350, cancellationToken);
            if (Position < Delta.Length) buffer = buffer[..Math.Min(buffer.Length, Delta.Length - (int)Position)];
            return await base.ReadAsync(buffer, cancellationToken);
        }
    }
}
