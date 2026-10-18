using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Recappi.Core;
using System.Text.Json;

namespace Recappi.WinUI.Tests;

public partial class TestApp
{
    private static async Task RecorderContentSizing(string root)
    {
        await using var host = new TestHost(Path.Combine(root, "layout-recording"));
        var window = new RecorderWindow(host, () => ([new AudioSource("system", "Controlled audio")], [new MicrophoneDevice("microphone", "Controlled microphone", true)]));
        try
        {
            window.Show(); await window.RefreshDevices();
            await Until(() => window.IsUserVisible && window.Body.ActualHeight > 0, "Recorder did not appear.");
            await Task.Delay(250);
            var row = Field<Grid>(window, "idleRow");
            var rowBottom = row.TransformToVisual(window.Content).TransformPoint(new(0, row.ActualHeight)).Y;
            var scale = window.Content.XamlRoot.RasterizationScale;
            await File.WriteAllTextAsync(Path.Combine(root, "recorder-layout.json"), JsonSerializer.Serialize(new
            {
                clientHeight = window.AppWindow.ClientSize.Height / scale,
                bodyHeight = window.Body.ActualHeight, desiredHeight = window.Body.DesiredSize.Height,
                rowHeight = row.ActualHeight, rowBottom, scale,
                windowDpi = RecorderLayoutDpi(WinRT.Interop.WindowNative.GetWindowHandle(window)),
                position = new { window.AppWindow.Position.X, window.AppWindow.Position.Y },
                size = new { window.AppWindow.Size.Width, window.AppWindow.Size.Height }
            }));
            Check(window.AppWindow.ClientSize.Height / scale - rowBottom <= 14,
                "Idle recorder has excess blank space below its controls.");
            var area = Microsoft.UI.Windowing.DisplayArea.GetFromWindowId(window.AppWindow.Id, Microsoft.UI.Windowing.DisplayAreaFallback.Primary).WorkArea;
            var initialPosition = window.AppWindow.Position;
            Check(Math.Abs(initialPosition.Y - area.Y - 16 * scale) <= 1 &&
                Math.Abs(area.X + area.Width - initialPosition.X - window.AppWindow.Size.Width - 16 * scale) <= 1,
                "Recorder did not default to the top-right work-area corner with a 16-point inset.");
            var idleHeight = window.AppWindow.ClientSize.Height;
            Click(Field<Button>(window, "start"));
            await Until(() => host.Engine.Snapshot.State == RecordingState.Recording && window.AppWindow.ClientSize.Height > idleHeight,
                "Recording state did not expand to fit its source/status row.");
            window.RequestAttention(AttentionAction.DurationLimit);
            await Until(() => Field<TextBlock>(window, "attention").ActualHeight > 0, "Reminder did not appear.");
            var recordingHeight = window.AppWindow.ClientSize.Height;
            Click(Field<Button>(window, "stop"));
            await Until(() => host.Engine.Snapshot.State == RecordingState.Done && Math.Abs(window.AppWindow.ClientSize.Height - idleHeight) <= 2,
                "Saved state did not shrink back to a single row.");
            Check(window.AppWindow.Position.Y == initialPosition.Y && window.AppWindow.ClientSize.Height < recordingHeight,
                "Content resizing moved the top edge or retained blank space.");
            var moved = new Windows.Graphics.PointInt32(initialPosition.X - 80, initialPosition.Y + 80);
            window.AppWindow.Move(moved); window.Hide(); window.Show();
            Check(window.AppWindow.Position.X == moved.X && window.AppWindow.Position.Y == moved.Y,
                "Restoring reset the user's chosen position to the default corner.");
        }
        finally { window.Close(); }
    }
    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "GetDpiForWindow")]
    private static extern uint RecorderLayoutDpi(nint window);
}
