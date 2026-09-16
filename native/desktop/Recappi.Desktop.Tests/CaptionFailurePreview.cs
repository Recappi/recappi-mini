using System.IO;
using System.Text.Json;
using System.Threading.Channels;
using System.Windows;
using System.Windows.Controls;
using Recappi.Core;
using Recappi.Desktop;

internal static class CaptionFailurePreview
{
    public static async Task RunAsync(string root)
    {
        Directory.CreateDirectory(root);
        var store = new LocalRecordingStore(Path.Combine(root, "recordings"));
        var recording = store.Create("Controlled caption failure");
        var provider = new Connection();
        var window = new CaptionWindow { Left = 460, Top = 40 };
        window.ConfigureTranslation(false);
        var content = new StackPanel { Margin = new Thickness(16) };
        content.Children.Add(new TextBlock { Text = "受控协议输入；不连接云端、不录制音频。\n右侧为生产字幕窗口。", Margin = new Thickness(0, 0, 0, 12) });
        var fixture = new Window { Title = "Recappi caption failure fixture", Left = 20, Top = 40, Width = 420, Height = 340, Content = content };
        var finished = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        fixture.Closed += (_, _) => finished.TrySetResult();
        window.Closed += (_, _) => finished.TrySetResult();
        var steps = new List<object>();
        var buttons = new List<Button>();
        Action[] actions =
        [
            () => provider.Push(new { type = "conversation.item.input_audio_transcription.failed", item_id = "first", content_index = 0 }),
            () =>
            {
                provider.Push(new { type = "input_audio_buffer.committed", item_id = "second" });
                provider.Push(new { type = "conversation.item.input_audio_transcription.delta", item_id = "second", delta = "下一句正在继续" });
            },
            () => provider.Push(new { type = "conversation.item.input_audio_transcription.completed", item_id = "second", transcript = "下一句已正常识别。" }),
            () =>
            {
                provider.Push(new { type = "input_audio_buffer.committed", item_id = "third" });
                provider.Push(new { type = "conversation.item.input_audio_transcription.failed", item_id = "third", content_index = 0 });
            }
        ];
        var names = new[] { "1 · 标记本句失败", "2 · 输入下一句", "3 · 完成下一句", "4 · 空结果失败" };
        for (var index = 0; index < actions.Length; index++)
        {
            var step = index;
            var button = new Button { Content = names[index], IsEnabled = index == 0, Margin = new Thickness(0, 0, 0, 8) };
            button.Click += (_, _) =>
            {
                actions[step]();
                steps.Add(new { step = step + 1, at = DateTimeOffset.UtcNow });
                button.IsEnabled = false;
                if (step + 1 < buttons.Count) buttons[step + 1].IsEnabled = true;
            };
            buttons.Add(button); content.Children.Add(button);
        }
        var close = new Button { Content = "结束并保存验证文件", Margin = new Thickness(0, 4, 0, 0) };
        close.Click += (_, _) => fixture.Close(); content.Children.Add(close);
        var startedAt = DateTimeOffset.UtcNow;
        await using var captions = new LiveCaptions(new(), _ => Task.FromResult<ICaptionConnection>(provider), autoStart: false);
        var archive = new CaptionArchive(store.CaptionPath(recording));
        captions.Delta += window.Update;
        captions.Delta += archive.Append;
        captions.Changed += window.UpdateStatus;
        try
        {
            fixture.Show(); window.Show(); captions.Start();
            provider.Push(new { type = "input_audio_buffer.committed", item_id = "first" });
            provider.Push(new { type = "conversation.item.input_audio_transcription.delta", item_id = "first", delta = "这一句只识别了一半" });
            Console.WriteLine("Caption failure preview: " + root);
            await finished.Task;
        }
        finally
        {
            window.Close(); fixture.Close();
            await captions.AbortAsync(); await archive.DisposeAsync();
        }
        var exportPath = Path.Combine(root, "captions.txt");
        CaptionExport.Save(store, recording, exportPath, false);
        var archived = CaptionArchiveOrder.Read(store.CaptionPath(recording)).ToArray();
        File.WriteAllText(Path.Combine(root, "caption-failure-preview.json"), JsonSerializer.Serialize(new
        {
            startedAt, endedAt = DateTimeOffset.UtcNow, steps,
            expectedArchive = archived.Length == 3 && archived.Count(x => x.IsFailed) == 2,
            archiveError = archive.Error, exportPath,
            scope = "Production LiveCaptions, CaptionWindow, archive and export; injected provider messages, no network/account/audio recording. Visual acceptance is separate."
        }, new JsonSerializerOptions { WriteIndented = true }));
    }

    private sealed class Connection : ICaptionConnection
    {
        private readonly Channel<JsonElement> incoming = Channel.CreateUnbounded<JsonElement>();
        public void Push(object value) => incoming.Writer.TryWrite(JsonSerializer.SerializeToElement(value));
        public Task SendAsync(object value, CancellationToken cancellation) => Task.CompletedTask;
        public async Task<JsonElement?> ReceiveAsync(CancellationToken cancellation)
        {
            try { return await incoming.Reader.ReadAsync(cancellation); }
            catch (ChannelClosedException) { return null; }
        }
        public ValueTask DisposeAsync() { incoming.Writer.TryComplete(); return ValueTask.CompletedTask; }
    }
}
