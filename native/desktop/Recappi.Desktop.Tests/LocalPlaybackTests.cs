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
            var longEntry = store.Create("Long playback");
            using (var writer = new NAudio.Wave.WaveFileWriter(longEntry.AudioPath, new NAudio.Wave.WaveFormat(8000, 16, 1)))
            {
                var silence = new byte[16000];
                for (var secondIndex = 0; secondIndex < 3661; secondIndex++) writer.Write(silence, 0, silence.Length);
            }
            store.Save(longEntry with { State = RecordingState.Done, DurationMs = 3661000 });
            window.RefreshRecordings(longEntry.Id);
            for (var attempt = 0; attempt < 100 && !slider.IsEnabled; attempt++) await Task.Delay(50);
            if (!slider.IsEnabled || slider.Maximum < 3660) throw new Exception("Long local media did not open.");
            void SeekWithKey(double seconds)
            {
                slider.Value = seconds;
                slider.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(window), Environment.TickCount, Key.Right)
                    { RoutedEvent = UIElement.PreviewKeyUpEvent });
            }
            SeekWithKey(3599);
            if (time.Text != "59:59") throw new Exception("Playback before one hour changed its minute format.");
            SeekWithKey(3605);
            if (time.Text != "01:00:05") throw new Exception("Long paused seek wrapped away the elapsed hour: " + time.Text);
            play.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            await Task.Delay(750);
            play.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            if (!time.Text.StartsWith("01:00:", StringComparison.Ordinal)) throw new Exception("Long playback timer wrapped away the elapsed hour: " + time.Text);
            SeekWithKey(3);
            if (time.Text != "00:03") throw new Exception("Seeking below one hour retained a stale hour prefix.");
            Console.WriteLine("PASS real 61-minute WAV paused seek and playing timer retain elapsed hours and restore short formatting below an hour.");
            Console.WriteLine("PASS local paused pointer/keyboard seek time updates immediately; selection and actual media end reset position.");
        }
        finally { window.Close(); }
    }
}
