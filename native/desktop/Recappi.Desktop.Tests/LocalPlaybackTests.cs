using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Recappi.Core;
using Recappi.Desktop;

internal static class LocalPlaybackTests
{
    public static async Task RunAsync(string root)
    {
        var store = new LocalRecordingStore(Path.Combine(root, "local-playback"));
        LocalRecording Create(string title)
        {
            var entry = store.Create(title);
            using (var writer = new PcmWaveWriter(entry.AudioPath))
                for (var i = 0; i < 100; i++) writer.Append(new float[4800]);
            entry = entry with { State = RecordingState.Done, DurationMs = 10000 };
            store.Save(entry); return entry;
        }
        var first = Create("First"); var second = Create("Second");
        var window = new LibraryWindow(store) { ShowActivated = false };
        try
        {
            window.Show(); window.RefreshRecordings(first.Id);
            var slider = (Slider)window.FindName("Position");
            var time = (TextBlock)window.FindName("PlaybackTime");
            for (var attempt = 0; attempt < 100 && !slider.IsEnabled; attempt++) await Task.Delay(50);
            if (!slider.IsEnabled || slider.Maximum < 9) throw new Exception("Local media did not open.");
            slider.Value = 5;
            slider.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, Environment.TickCount, MouseButton.Left)
                { RoutedEvent = UIElement.PreviewMouseLeftButtonUpEvent });
            if (time.Text != "00:05") throw new Exception("Paused pointer seek retained a stale playback time.");
            slider.Value = 3;
            slider.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(window), Environment.TickCount, Key.Left)
                { RoutedEvent = UIElement.PreviewKeyUpEvent });
            if (time.Text != "00:03") throw new Exception("Paused keyboard seek retained a stale playback time.");
            window.RefreshRecordings(second.Id);
            if (time.Text != "00:00" || slider.Value != 0) throw new Exception("New selection retained the previous playback position.");
            for (var attempt = 0; attempt < 100 && !slider.IsEnabled; attempt++) await Task.Delay(50);
            if (!slider.IsEnabled) throw new Exception("Second local media did not open.");
            slider.Value = 9.75;
            slider.RaiseEvent(new MouseButtonEventArgs(Mouse.PrimaryDevice, Environment.TickCount, MouseButton.Left)
                { RoutedEvent = UIElement.PreviewMouseLeftButtonUpEvent });
            var play = (Button)window.FindName("PlayButton");
            play.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            for (var attempt = 0; attempt < 100 && Equals(play.Content, "暂停"); attempt++) await Task.Delay(50);
            if (!Equals(play.Content, "播放") || slider.Value != 0 || time.Text != "00:00") throw new Exception("Media end left a stale slider or time.");
            Console.WriteLine("PASS local paused pointer/keyboard seek time updates immediately; selection and actual media end reset position.");
        }
        finally { window.Close(); }
    }
}
