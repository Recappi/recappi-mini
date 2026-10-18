using Microsoft.UI.Xaml.Controls;
using Recappi.Core;
using Windows.Media.Playback;

namespace Recappi.WinUI.Tests;

public partial class TestApp
{
    private static async Task Playback(string root)
    {
        await PlaybackAtRoot(root);
        await PlaybackAtRoot(Path.Combine(root, new string('p', 100), new string('q', 100)));
        var arguments = Environment.GetCommandLineArgs();
        var fixtures = Array.IndexOf(arguments, "--playback-fixtures");
        if (fixtures >= 0)
        {
            var directory = Path.GetFullPath(arguments[fixtures + 1]);
            foreach (var format in new[] { ("mp3", "audio/mpeg"), ("m4a", "audio/mp4"), ("aac", "audio/aac"), ("flac", "audio/flac"), ("wma", "audio/x-ms-wma") })
                await CloudPlaybackFormat(root, Path.Combine(directory, "sample." + format.Item1), format.Item2);
        }
    }
    private static async Task CloudPlaybackFormat(string root, string fixture, string contentType)
    {
        Check(File.Exists(fixture), "Missing playback fixture: " + fixture);
        var extension = Path.GetExtension(fixture);
        await using var host = new TestHost(Path.Combine(root, "formats", extension[1..]), (request, token) =>
        {
            if (request.RequestUri!.AbsolutePath.EndsWith("/audio"))
            {
                var content = new StreamContent(File.OpenRead(fixture));
                content.Headers.ContentType = new System.Net.Http.Headers.MediaTypeHeaderValue(contentType);
                return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = content });
            }
            if (request.RequestUri.AbsolutePath == "/api/recordings")
                return Task.FromResult(TestHost.Json("""{"items":[{"id":"format","title":"Format fixture","status":"completed","durationMs":3000,"createdAt":"2026-09-16T02:00:00Z"}],"nextCursor":null}"""));
            return TestHost.DefaultResponse(request, token);
        });
        await host.SignIn();
        var window = new LibraryWindow(host); window.Show();
        string? downloaded = null;
        try
        {
            await window.Refresh(); Field<ListView>(window, "list").SelectedIndex = 0;
            await Until(() => Field<CloudTranscript?>(window, "content") is not null, "Format transcript did not load.");
            await Call(window, "LoadAudio");
            await Call(window, "SeekAudio", TimeSpan.FromSeconds(1));
            await Until(() => Field<bool>(window, "mediaOpened"), extension + " decoder did not open.");
            var player = Field<MediaPlayer>(window, "player");
            await Until(() => Math.Abs(player.PlaybackSession.Position.TotalSeconds - 1) < .2, extension + " did not seek.");
            Check(player.PlaybackSession.PlaybackState != MediaPlaybackState.Playing, extension + " started playing during seek.");
            Check(Field<Slider>(window, "seek").IsEnabled, extension + " seek remained disabled.");
            downloaded = Field<string>(window, "audioPath");
        }
        finally { window.Close(); }
        using var released = File.Open(downloaded!, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        Console.WriteLine("PASS playback format " + extension);
    }
    private static async Task PlaybackAtRoot(string root)
    {
        await using var host = new TestHost(Path.Combine(root, "playback"));
        var recording = host.Store.Create("Seek fixture") with { State = RecordingState.Done, DurationMs = 3000 };
        host.Store.Save(recording);
        // Valid silent PCM: exercise the Windows decoder without playing sound or recording a device.
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
            await window.SelectRecording(recording.Id);
            await Call(window, "LoadAudio");
            await Call(window, "SeekAudio", TimeSpan.FromSeconds(1));
            await Until(() => Field<bool>(window, "mediaOpened"), "Audio decoder did not open valid PCM.");
            var previous = Field<MediaPlayer>(window, "player");
            await Until(() => Math.Abs(previous.PlaybackSession.Position.TotalSeconds - 1) < 0.15, "First seek was lost while opening audio.");
            Check(previous.PlaybackSession.PlaybackState != MediaPlaybackState.Playing, "Selecting a timestamp unexpectedly started playback.");
            Check(Field<Slider>(window, "seek").IsEnabled, "Seek control remained disabled after opening seekable audio.");
            var tabs = Field<SelectorBar>(window, "tabs"); tabs.SelectedItem = tabs.Items[1];
            var transcript = Field<ListView>(window, "transcript");
            transcript.ItemsSource = new[] { new CloudTranscriptSegment("Selectable source text", "Speaker", 2000, 3000) };
            Button? timestamp = null;
            await Until(() =>
            {
                timestamp = (transcript.ContainerFromIndex(0) as ListViewItem)?.ContentTemplateRoot is Microsoft.UI.Xaml.FrameworkElement row
                    ? row.FindName("Timestamp") as Button : null;
                return timestamp is { IsLoaded: true, IsEnabled: true };
            }, "Transcript timestamp button did not become available.");
            Click(timestamp!);
            await Until(() => Math.Abs(previous.PlaybackSession.Position.TotalSeconds - 2) < .15, "Timestamp button did not seek audio.");
            await Call(window, "SeekAudio", TimeSpan.FromSeconds(1));
            Click(timestamp!);
            await Until(() => Math.Abs(previous.PlaybackSession.Position.TotalSeconds - 2) < .15, "Repeated timestamp click did not seek again.");
            await Call(window, "ResetPlayback");
            await Call(window, "LoadAudio");
            var current = Field<MediaPlayer>(window, "player");
            Check(!ReferenceEquals(previous, current), "Source reused the previous player.");
            // Deliver an old open callback after replacing the source: it must not consume the new seek.
            await Call(window, "SeekAudio", TimeSpan.FromSeconds(2));
            await Call(window, "PlaybackOpened", previous, new object());
            await Until(() => Field<bool>(window, "mediaOpened"), "Replacement audio did not open.");
            await Until(() => Math.Abs(current.PlaybackSession.Position.TotalSeconds - 2) < 0.15, "Replacement audio lost its requested position.");
            Check(current.PlaybackSession.PlaybackState != MediaPlaybackState.Playing, "Reloading audio unexpectedly started playback.");
        }
        finally { window.Close(); }
        using var releasedFile = File.Open(recording.AudioPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        Check(releasedFile.Length > 44, "Closing playback did not preserve or release the audio file.");
    }
}
