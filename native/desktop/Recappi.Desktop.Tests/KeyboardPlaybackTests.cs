using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Text.Json;
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
        var observations = new List<object>();
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
                        var modifiers = Keyboard.Modifiers.ToString();
                        var key = new KeyEventArgs(Keyboard.PrimaryDevice, PresentationSource.FromVisual(window), Environment.TickCount, Key.Right)
                            { RoutedEvent = UIElement.KeyDownEvent };
                        slider.RaiseEvent(key);
                        var immediatelyAfter = slider.Value;
                        var focusedAfterKey = slider.IsKeyboardFocusWithin;
                        await Task.Delay(400); // Allow the real playback timer to run, without releasing the key.
                        observations.Add(new { player = slider == localSlider ? "local" : "cloud", repeat, before,
                            immediatelyAfter, afterTimer = slider.Value, focusedAfterKey, focusedAfterTimer = slider.IsKeyboardFocusWithin,
                            modifiers, keyHandled = key.Handled, slider.Maximum, slider.IsEnabled, slider.ActualWidth,
                            cloudMediaSeconds = slider == cloudSlider ? cloud.PlaybackSeconds : null });
                        var details = JsonSerializer.Serialize(observations.Last());
                        if (immediatelyAfter < before + .8)
                            throw new Exception($"Keyboard input did not advance the slider before the playback timer: {details}");
                        if (slider.Value < before + .8)
                            throw new Exception($"Playback timer erased an applied keyboard seek before key release: {details}");
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
        finally
        {
            local.Dispose(); cloud.Clear(); window.Close();
            File.WriteAllText(Path.Combine(root, "keyboard-playback-observations.json"), JsonSerializer.Serialize(observations, new JsonSerializerOptions { WriteIndented = true }));
        }
    }
}
