using Microsoft.UI.Xaml.Controls;

namespace Recappi.WinUI.Tests;

// Controlled data in the production window. This verifies native layout, not cloud connectivity.
internal static class LibraryPreview
{
    public static async Task Run(string root)
    {
        void Stage(string value) => File.WriteAllText(Path.Combine(root, "stage.txt"), value);
        Stage("preview: creating controlled host");
        // A short silent WAV exercises the real Windows decoder and citation seeking.
        // Displayed meeting durations remain layout samples, not this fixture's duration.
        var previewAudio = Path.Combine(root, "preview-audio.wav");
        using (var writer = new Recappi.Core.PcmWaveWriter(previewAudio))
        {
            var silence = new float[Recappi.Core.PcmWaveWriter.SampleRate];
            for (var second = 0; second < 30; second++) writer.Append(silence);
        }
        var skippedSummary = false;
        await using var host = new TestHost(Path.Combine(root, "library-preview"), (request, token) =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path is "/api/recordings/hike/audio" or "/api/recordings/design/audio")
            {
                var audio = new StreamContent(File.OpenRead(previewAudio));
                audio.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue("audio/wav");
                return Task.FromResult(new System.Net.Http.HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = audio });
            }
            if (path.EndsWith("/ask-thread/messages"))
            {
                const string citation = """{"segmentId":"meeting","startMs":3000,"endMs":5000,"snippet":"周五晚上确认路线。"}""";
                var stream = "event: citation\ndata: {\"citation\":" + citation + "}\n\n" +
                    "event: done\ndata: {\"content\":\"大家会在周五晚上确认最终路线。\",\"citations\":[" + citation + "]}\n\n";
                return Task.FromResult(new System.Net.Http.HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new StringContent(stream, System.Text.Encoding.UTF8, "text/event-stream") });
            }
            if (path.EndsWith("/transcript") && skippedSummary)
                return Task.FromResult(TestHost.Json("""{"text":"周五晚上确认路线。","summaryStatus":"skipped","summaryJson":null}"""));
            if (path == "/api/recordings") return Task.FromResult(TestHost.Json("""
                {"items":[{"id":"hike","title":"周末徒步计划","status":"completed","durationMs":1240000,"createdAt":"2026-09-16T02:00:00Z"},{"id":"design","title":"设计讨论 · 录音回顾体验","status":"completed","durationMs":840000,"createdAt":"2026-09-15T02:00:00Z"}],"nextCursor":null}
                """));
            if (path.EndsWith("/transcript")) return Task.FromResult(TestHost.Json("""
                {"text":"周六八点在地铁站集合。先确认天气，再决定路线。记得带水和雨衣。","summary":"这次讨论确定了集合时间、路线选择和出发前的准备。大家倾向于选择强度适中的路线，留出充足的休息时间。","summaryInsights":{"keyPoints":["周六上午八点在地铁站集合。","出发前一天确认天气，遇到降雨则改走距离更短的路线。"],"decisions":["选择强度适中的路线，预留休息和返程时间。"],"actionItems":[{"who":"小林","what":"确认交通和返程时间"},{"who":"所有人","what":"准备饮水、雨衣和少量食物"},{"who":"阿青","what":"周五晚确认最终路线"}]},"summaryStatus":"completed","segments":[{"text":"周六八点在地铁站集合，可以吗？这样路上也不会太热。","speaker":"小林","startMs":0,"endMs":6000},{"text":"可以。我们先确认天气，再决定路线。如果下雨就走短一点的那条。","speaker":"阿青","startMs":6200,"endMs":14000},{"text":"记得带水和雨衣。周五晚上再确认一下交通和返程时间。","speaker":"小林","startMs":14500,"endMs":22000}]}
                """));
            return TestHost.DefaultResponse(request, token);
        });
        Stage("preview: signing in controlled host");
        await host.SignIn();
        Stage("preview: constructing library");
        var window = new LibraryWindow(host);
        var done = new TaskCompletionSource(); window.Closed += (_, _) => done.TrySetResult();
        Stage("preview: showing library");
        window.Show();
        Stage("preview: refreshing library");
        await window.Refresh(); TestApp.Field<ListView>(window, "list").SelectedIndex = 0;
        Stage("preview: waiting for content and layout");
        if (Environment.GetCommandLineArgs().Contains("--dark")) window.ApplyTheme("dark"); else window.ApplyTheme("light");
        if (Environment.GetCommandLineArgs().Contains("--small")) window.AppWindow.Resize(new Windows.Graphics.SizeInt32(1230, 840));
        var sections = TestApp.Field<SelectorBar>(window, "tabs");
        if (Environment.GetCommandLineArgs().Contains("--transcript")) sections.SelectedItem = sections.Items[1];
        if (Environment.GetCommandLineArgs().Contains("--ask")) sections.SelectedItem = sections.Items[2];
        await TestApp.Until(() => TestApp.Field<Recappi.Core.CloudTranscript?>(window, "content") is not null, "Preview content did not load.");
        await TestApp.Until(() => ((Microsoft.UI.Xaml.FrameworkElement)window.Content).ActualWidth > 0, "Preview layout did not load.");
        Stage("preview: rendering initial bitmap");
        var bitmap = new Microsoft.UI.Xaml.Media.Imaging.RenderTargetBitmap();
        await bitmap.RenderAsync(window.Content);
        var pixels = await bitmap.GetPixelsAsync();
        using (var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream())
        {
            var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream);
            encoder.SetPixelData(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied,
                (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.ToArray(pixels));
            await encoder.FlushAsync(); stream.Seek(0);
            using var reader = new Windows.Storage.Streams.DataReader(stream); await reader.LoadAsync((uint)stream.Size);
            var bytes = new byte[(int)stream.Size]; reader.ReadBytes(bytes); await File.WriteAllBytesAsync(Path.Combine(root, "library-native-render.png"), bytes);
        }
        File.WriteAllText(Path.Combine(root, "preview-window.json"), System.Text.Json.JsonSerializer.Serialize(new { window.AppWindow.Position, window.AppWindow.Size, processId = Environment.ProcessId }, new System.Text.Json.JsonSerializerOptions { IncludeFields = true }));
        if (Environment.GetCommandLineArgs().Contains("--capture-native-previews"))
        {
            Stage("preview: capturing native windows");
            try
            {
                await NativePreviewCapture.Library(root, window);
                skippedSummary = true;
                await TestApp.Call(window, "Select", false);
                sections.SelectedItem = sections.Items[0]; window.ApplyTheme("light");
                await NativePreviewCapture.Stage(root, "library-summary-skipped-light", window);
                window.ApplyTheme("dark");
                await NativePreviewCapture.Stage(root, "library-summary-skipped-dark", window);
                sections.SelectedItem = sections.Items[2];
                var ask = TestApp.Field<AskPanel>(window, "ask");
                TestApp.Field<TextBox>(ask, "question").Text = "什么时候确认路线？";
                await TestApp.Call(ask, "Send");
                await NativePreviewCapture.Stage(root, "library-answer-citation-dark", window);
                window.ApplyTheme("light");
                await NativePreviewCapture.Stage(root, "library-answer-citation-light", window);
                await NativePreviewCapture.Floating(root, host);
                await NativePreviewCapture.Auxiliary(root);
                await File.WriteAllTextAsync(Path.Combine(root, "capture-complete.json"), "{\"controlledData\":true,\"activationEvidence\":\"per-state\",\"completed\":true}");
            }
            finally { Stage("preview: closing library"); window.Close(); }
            return;
        }
        if (await Task.WhenAny(done.Task, Task.Delay(TimeSpan.FromMinutes(15))) != done.Task) window.Close();
    }
}
