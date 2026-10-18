using System.Net;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Recappi.Core;

namespace Recappi.WinUI.Tests;

public partial class TestApp
{
    private static async Task RecorderProcessing(string root)
    {
        var releasePart = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        await using var host = new TestHost(Path.Combine(root, "recorder-processing"), async (request, cancellation) =>
        {
            var path = request.RequestUri!.AbsolutePath;
            if (path == "/api/recordings" && request.Method == HttpMethod.Post)
                return TestHost.Json("""{"id":"recorder-upload","partSize":1048576,"maxPartBytes":1048576}""");
            if (path.Contains("/parts/"))
            {
                await releasePart.Task.WaitAsync(cancellation);
                return new HttpResponseMessage(HttpStatusCode.ServiceUnavailable);
            }
            return await TestHost.DefaultResponse(request, cancellation);
        });
        await host.SignIn();
        var window = new RecorderWindow(host, () => ([new AudioSource("system", "Controlled audio")], []));
        var capture = Environment.GetCommandLineArgs().Contains("--capture-recorder-flow");
        async Task Capture(string name)
        {
            if (!capture) return;
            window.ApplyTheme("light"); await NativePreviewCapture.Stage(root, "recorder-" + name + "-light", window);
            window.ApplyTheme("dark"); await NativePreviewCapture.Stage(root, "recorder-" + name + "-dark", window);
            window.ApplyTheme("light");
        }
        Task<ProcessingEntry>? processing = null;
        try
        {
            window.Show(); await window.RefreshDevices();
            await Until(() => window.IsUserVisible, "Recorder did not appear.");
            await Capture("idle");
            await host.Engine.StartAsync(new("Saved flow", true, false));
            await Task.Delay(200);
            var recording = (await host.Engine.StopAsync())!;
            await Until(() => Field<TextBlock>(window, "savedStatus").Text == "已保存到本机", "Local save status missing.");
            await Capture("saved");
            processing = host.Processing.StartAsync(recording, host.Account.Snapshot.Account!, new());
            await Until(() => Field<TextBlock>(window, "savedStatus").Text == "正在上传", "Background upload is invisible on recorder.");
            Check(Field<TextBlock>(window, "savedDetail").Visibility == Visibility.Visible, "Background processing guidance missing.");
            await Capture("uploading");
            releasePart.TrySetResult();
            await processing;
            await Until(() => Field<TextBlock>(window, "savedStatus").Text == "云端处理失败", "Cloud failure still appears as successful local-only completion.");
            Check(File.Exists(recording.AudioPath), "Cloud failure lost local audio.");
            await Capture("cloud-failure");
            await host.Account.SignOutAsync();
            await Until(() => Field<TextBlock>(window, "savedStatus").Text == "已保存到本机", "Signed-out recorder leaked previous account processing state.");
            await host.SignIn();
            await Until(() => Field<TextBlock>(window, "savedStatus").Text == "云端处理失败", "Reconnecting lost persisted processing status.");
            Click(Field<Button>(window, "newRecording"));
            await Until(() => Field<Grid>(window, "donePanel").Visibility == Visibility.Collapsed, "New recording did not dismiss completion.");
            Click(Field<Button>(window, "start"));
            await Until(() => host.Engine.Snapshot.State == RecordingState.Recording, "Could not start next recording while old cloud processing had failed.");
            await Task.Delay(100);
            Click(Field<Button>(window, "stop"));
            await Until(() => host.Engine.Snapshot.State == RecordingState.Done && Field<Grid>(window, "donePanel").Visibility == Visibility.Visible,
                "Next recording did not reach completion.");
            Check(Field<TextBlock>(window, "savedStatus").Text == "已保存到本机", "Old recording's cloud failure leaked into the next recording.");
            if (capture) await File.WriteAllTextAsync(Path.Combine(root, "capture-complete.json"), "{\"controlledData\":true,\"completed\":true}");
        }
        finally { releasePart.TrySetResult(); if (processing is not null) await processing; window.Close(); }
    }
}
