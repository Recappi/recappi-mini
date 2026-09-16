using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using Recappi.Core;
using Recappi.Desktop;

internal static class KeyboardPlaybackTests
{
    public static async Task RunAsync(string root, bool preview = false)
    {
        var store = new LocalRecordingStore(Path.Combine(root, "keyboard-playback"));
        var entry = store.Create("Keyboard playback — synthetic silence");
        using (var writer = new PcmWaveWriter(entry.AudioPath))
            for (var i = 0; i < 600; i++) writer.Append(new float[4800]);
        store.Save(entry with { State = RecordingState.Done, DurationMs = 60000 });
        var local = new LocalLibraryView(store);
        local.UseExternalList();
        var cloud = new AudioPlayer();
        var grid = new Grid { Margin = new Thickness(16) };
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.ColumnDefinitions.Add(new ColumnDefinition());
        grid.Children.Add(local);
        var cloudHost = new StackPanel { Margin = new Thickness(20, 0, 0, 0) };
        cloudHost.Children.Add(new TextBlock { Text = "Cloud player · local synthetic WAV", FontSize = 20 });
        cloudHost.Children.Add(cloud);
        Grid.SetColumn(cloudHost, 1); grid.Children.Add(cloudHost);
        var window = new Window { Title = "Recappi keyboard playback validation", Width = 1000, Height = 600, Content = grid };
        var closed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        window.Closed += (_, _) => closed.TrySetResult();
        try
        {
            window.Show(); local.RefreshRecordings(entry.Id); cloud.Open(entry.AudioPath);
            var localSlider = (Slider)local.FindName("Position");
            var cloudSlider = (Slider)cloud.FindName("Position");
            for (var attempt = 0; attempt < 100 && (!localSlider.IsEnabled || !cloudSlider.IsEnabled); attempt++) await Task.Delay(50);
            if (!localSlider.IsEnabled || !cloudSlider.IsEnabled) throw new Exception("Keyboard fixture media did not open.");
            if (preview) { Console.WriteLine("READY keyboard playback fixture: two production controls, synthetic WAV, no network."); await Task.WhenAny(closed.Task, Task.Delay(TimeSpan.FromMinutes(5))); return; }
            foreach (var (slider, play) in new[] { (localSlider, (Button)local.FindName("PlayButton")), (cloudSlider, (Button)cloud.FindName("PlayButton")) })
            {
                slider.SmallChange = 1;
                window.Activate(); slider.Focus();
                if (!slider.IsKeyboardFocusWithin) throw new Exception("Keyboard playback test did not acquire real slider focus.");
                play.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                try
                {
                    for (var repeat = 0; repeat < 3; repeat++)
                    {
                        var before = slider.Value;
                        slider.RaiseEvent(new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(window), Environment.TickCount, Key.Right)
                            { RoutedEvent = UIElement.KeyDownEvent });
                        await Task.Delay(400); // Allow the real playback timer to run, without releasing the key.
                        if (slider.Value < before + .8) throw new Exception("Playback timer erased a keyboard seek before key release.");
                    }
                    var focusedPosition = slider.Value;
                    await Task.Delay(800);
                    if (!slider.IsKeyboardFocusWithin)
                        throw new Exception($"Playback test lost keyboard focus: player={(slider == localSlider ? "local" : "cloud")}, before={focusedPosition:F3}, after={slider.Value:F3}.");
                    if (slider.Value < focusedPosition + .3)
                        throw new Exception($"Playback progress froze with slider focus: player={(slider == localSlider ? "local" : "cloud")}, before={focusedPosition:F3}, after={slider.Value:F3}.");
                }
                finally { play.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); }
            }
            Console.WriteLine("PASS local/cloud native media commits repeated key-down seeks before release and progresses while keyboard focus remains on the slider.");
        }
        finally { local.Dispose(); cloud.Clear(); window.Close(); }
    }
}
