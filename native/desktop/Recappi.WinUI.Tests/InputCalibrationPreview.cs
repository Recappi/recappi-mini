using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Recappi.Core;

namespace Recappi.WinUI.Tests;

// Interactive diagnostic only. No real account, network transport or audio device.
internal static class InputCalibrationPreview
{
    public static async Task Run(string root)
    {
        await using var host = new TestHost(Path.Combine(root, "input-calibration"));
        var recorder = new RecorderWindow(host, () =>
            ([new AudioSource("system", "受控信号 · 不采集设备")], []));
        recorder.Title = "Recappi · 隔离录音条输入检查";
        var caption = new CaptionWindow(() => Task.CompletedTask) { Title = "Recappi · 隔离字幕输入检查" };
        caption.Reset(true);
        caption.SetStatus("受控字幕 · 不连接服务");
        caption.Update(new("sample", "source", "Keep the panel readable while moving it.", true, new("input-check", 0)));
        caption.Update(new("sample", "translation", "移动窗口时仍应保持文字清晰可读。", true, new("input-check", 0)));
        var status = new TextBlock { Text = "尚未点击", TextWrapping = TextWrapping.Wrap };
        var panel = new StackPanel { Margin = new Thickness(24), Spacing = 20 };
        panel.Children.Add(new TextBlock { Text = "输入定位检查：无账号、无网络、无真实音频设备" });
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 24 };
        var events = new List<object>();
        var finish = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var probe = new Window { Title = "Recappi · 隔离输入定位检查", Content = panel };
        void Record(string action, object? detail = null)
        {
            events.Add(new { utc = DateTimeOffset.UtcNow, action, detail });
            File.WriteAllText(Path.Combine(root, "input-events.json"), JsonSerializer.Serialize(events, new JsonSerializerOptions { WriteIndented = true }));
            status.Text = action;
        }
        foreach (var label in new[] { "左侧按钮", "中间按钮", "右侧按钮" })
        {
            var button = new Button { Content = label, Width = 140, Height = 64 };
            button.Click += (_, _) => Record(label);
            buttons.Children.Add(button);
        }
        panel.Children.Add(buttons); panel.Children.Add(status);
        var positionedRecorder = false;
        var showRecorder = new Button { Content = "显示受控录音条" };
        showRecorder.Click += async (_, _) =>
        {
            recorder.Show();
            await Task.Delay(500);
            if (!positionedRecorder) recorder.AppWindow.Move(new Windows.Graphics.PointInt32(1400, 500));
            positionedRecorder = true;
            Record("show-recorder");
        };
        panel.Children.Add(showRecorder);
        var positionedCaption = false;
        var showCaption = new Button { Content = "显示受控字幕" };
        showCaption.Click += async (_, _) =>
        {
            caption.Show();
            await Task.Delay(500);
            if (!positionedCaption) caption.AppWindow.Move(new Windows.Graphics.PointInt32(1400, 850));
            positionedCaption = true;
            Record("show-caption");
        };
        panel.Children.Add(showCaption);
        var done = new Button { Content = "结束检查" };
        done.Click += (_, _) => finish.TrySetResult();
        panel.Children.Add(done);
        panel.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, e) =>
        {
            var point = e.GetCurrentPoint(panel).Position;
            Record("probe-pointer", new { point.X, point.Y, scale = panel.XamlRoot.RasterizationScale });
        }), true);
        recorder.Content.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, e) =>
        {
            var point = e.GetCurrentPoint(recorder.Content).Position;
            Record("recorder-pointer", new { point.X, point.Y, scale = recorder.Content.XamlRoot.RasterizationScale });
        }), true);
        recorder.AppWindow.Changed += (_, _) => Record("recorder-window", new
        {
            x = recorder.AppWindow.Position.X, y = recorder.AppWindow.Position.Y,
            width = recorder.AppWindow.Size.Width, height = recorder.AppWindow.Size.Height
        });
        caption.AppWindow.Changed += (_, _) => Record("caption-window", new
        {
            x = caption.AppWindow.Position.X, y = caption.AppWindow.Position.Y,
            width = caption.AppWindow.Size.Width, height = caption.AppWindow.Size.Height
        });
        probe.Closed += (_, _) => finish.TrySetResult();
        probe.AppWindow.Resize(new Windows.Graphics.SizeInt32(1900, 1400));
        probe.AppWindow.Move(new Windows.Graphics.PointInt32(1000, 150));
        probe.Activate();
        try
        {
            await recorder.RefreshDevices();
            Record("ready", new { processId = Environment.ProcessId, autoUpload = host.Preferences.AutoUpload, includeMicrophone = host.Preferences.IncludeMicrophone, signedIn = false });
            await Task.WhenAny(finish.Task, Task.Delay(TimeSpan.FromMinutes(10)));
            Record("finished", new { state = host.Engine.Snapshot.State.ToString(), recordings = host.Store.List().Count });
        }
        finally { recorder.Close(); caption.Close(); probe.Close(); }
    }
}
