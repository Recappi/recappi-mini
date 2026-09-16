using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Recappi.Core;
using Recappi.Desktop;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        var exit = 1;
        app.Startup += async (_, _) =>
        {
            try
            {
                // Match App startup before any isolated diagnostic constructs controls.
                DesktopTheme.Apply("system");
                if (args.Contains("--caption-window-test")) { await CaptionWindowTests.RunAsync(); exit = 0; return; }
                if (args.Contains("--idle-profile")) { await IdleProfile.RunAsync(); exit = 0; return; }
                if (args.Contains("--recording-ui-profile")) { await RecordingUiProfile.RunAsync(args.Contains("--software-rendering")); exit = 0; return; }
                if (args.Contains("--library-profile")) { await LibraryProfile.RunAsync(); exit = 0; return; }
                if (args.Contains("--local-playback-test")) { await LocalPlaybackTests.RunAsync(Path.Combine("build", "native-desktop-validation", "playback-" + Guid.NewGuid().ToString("N"))); exit = 0; return; }
                if (args.Contains("--library-lifetime-profile")) { await LibraryLifetimeProfile.RunAsync(args.Contains("--hold-for-dump")); exit = 0; return; }
                var root = Path.GetFullPath(Path.Combine("build", "native-desktop-validation", "ui-smoke-" + Guid.NewGuid().ToString("N")));
                if (args.Contains("--local-removal-test")) { await LocalRemovalTests.RunAsync(root); exit = 0; return; }
                if (args.Contains("--cloud-completion-test")) { await CloudCompletionLayoutTests.RunAsync(root, app.Dispatcher); exit = 0; return; }
                if (args.Contains("--caption-failure-preview")) { await CaptionFailurePreview.RunAsync(root); exit = 0; return; }
                if (args.Contains("--discard-lifecycle-test")) { await DiscardLifecycleTests.RunAsync(root, app.Dispatcher); exit = 0; return; }
                if (args.Contains("--speaker-editor-test")) { await TranscriptPanelTests.RunAsync(root, app.Dispatcher); exit = 0; return; }
                if (args.Contains("--keyboard-playback-test") || args.Contains("--keyboard-playback-preview")) { await KeyboardPlaybackTests.RunAsync(root, preview: args.Contains("--keyboard-playback-preview")); exit = 0; return; }
                if (args.Contains("--ask-draft-preview")) { await AskPanelTests.PreviewAsync(root); exit = 0; return; }
                if (args.Contains("--ask-slow-suggestions-preview")) { await AskPanelTests.PreviewAsync(root, slowSuggestions: true); exit = 0; return; }
                if (args.Contains("--view-retention-profile")) { await LibraryViewRetentionTests.RunAsync(root, app.Dispatcher, holdForDump: args.Contains("--hold-for-dump")); exit = 0; return; }
                if (args.Contains("--onboarding-stress"))
                {
                    for (var attempt = 0; attempt < 50; attempt++)
                        await OnboardingWindowTests.RunAsync(Path.Combine(root, attempt.ToString()));
                    exit = 0; return;
                }
                if (args.Contains("--billing-preview") || args.Contains("--billing-preview-dark")) { await BillingPanelTests.PreviewAsync(root, args.Contains("--billing-preview-dark")); exit = 0; return; }
                var store = new LocalRecordingStore(root);
                await using var engine = new RecordingEngine(store, _ => [new SilenceInput()]);
                var model = new RecorderViewModel(engine, store, app.Dispatcher, () => ([new AudioSource("system", "System")], [new MicrophoneDevice("mic", "Mic", true)]));
                await model.RefreshDevicesAsync();
                string? openedRecordingId = null;
                var quitRequests = 0;
                var window = new RecorderWindow(model, () => { }, showRecording: id => openedRecordingId = id, requestQuit: () => quitRequests++) { ShowActivated = false };
                window.Show();
                await app.Dispatcher.InvokeAsync(() => window.UpdateLayout(), DispatcherPriority.ApplicationIdle);
                if (!window.IsVisible || window.ActualHeight <= 0 || !model.Start.CanExecute(null)) throw new Exception("Recorder failed to show/bind.");
                if (window.WindowStyle != WindowStyle.None || System.Windows.Shell.WindowChrome.GetWindowChrome(window)?.CaptionHeight != 0 || !((FrameworkElement)window.FindName("MoveHandle")).IsVisible)
                    throw new Exception("Compact recorder retained system title chrome or lost its move handle.");
                var moveHandle = (System.Windows.Controls.Primitives.Thumb)window.FindName("MoveHandle");
                var originalLeft = window.Left; var originalTop = window.Top;
                moveHandle.RaiseEvent(new System.Windows.Input.KeyEventArgs(System.Windows.Input.Keyboard.PrimaryDevice, PresentationSource.FromVisual(window), Environment.TickCount, System.Windows.Input.Key.Left) { RoutedEvent = System.Windows.Input.Keyboard.KeyDownEvent });
                if (window.Left != originalLeft - 10 || window.Top != originalTop) throw new Exception("Recorder keyboard move handle did not move the native window.");
                window.Left = originalLeft; window.Top = originalTop;
                if (window.ActualHeight > 200 || !((FrameworkElement)window.FindName("SetupPanel")).IsVisible || ((FrameworkElement)window.FindName("CapturePanel")).IsVisible)
                    throw new Exception("Idle recorder did not use the compact source/options/start layout.");
                ((System.Windows.Controls.Primitives.ToggleButton)window.FindName("OptionsButton")).IsChecked = true;
                await app.Dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
                if (!((System.Windows.Controls.Primitives.Popup)window.FindName("OptionsPopup")).IsOpen) throw new Exception("Recording options did not open.");
                var optionsContent = (Grid)window.FindName("OptionsContent");
                var optionsScroll = (ScrollViewer)window.FindName("OptionsScroll");
                var quitButton = (Button)window.FindName("QuitButton");
                foreach (var maximumHeight in new[] { 500d, 360d })
                {
                    optionsContent.MaxHeight = maximumHeight;
                    optionsContent.UpdateLayout();
                    await app.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                    var quitBottom = quitButton.TranslatePoint(new Point(0, quitButton.ActualHeight), optionsContent).Y;
                    if (quitButton.ActualHeight <= 0 || quitBottom > optionsContent.ActualHeight + 1 ||
                        optionsScroll.ViewportHeight <= 0 || (maximumHeight == 360 && optionsScroll.ExtentHeight <= optionsScroll.ViewportHeight))
                        throw new Exception($"Recording options hid the quit footer or lost the scrollable form under constrained height: max={maximumHeight}, footer={quitBottom}, height={optionsContent.ActualHeight}, viewport={optionsScroll.ViewportHeight}, extent={optionsScroll.ExtentHeight}.");
                }
                optionsContent.MaxHeight = 500;
                ((Button)window.FindName("QuitButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                if (quitRequests != 1 || ((System.Windows.Controls.Primitives.Popup)window.FindName("OptionsPopup")).IsOpen) throw new Exception("Options quit did not dismiss the popup and delegate application shutdown.");
                ((System.Windows.Controls.Primitives.ToggleButton)window.FindName("OptionsButton")).IsChecked = true;
                window.RaiseEvent(new System.Windows.Input.KeyEventArgs(System.Windows.Input.Keyboard.PrimaryDevice, PresentationSource.FromVisual(window), Environment.TickCount, System.Windows.Input.Key.Escape) { RoutedEvent = System.Windows.Input.Keyboard.PreviewKeyDownEvent });
                if (((System.Windows.Controls.Primitives.Popup)window.FindName("OptionsPopup")).IsOpen) throw new Exception("Escape with focus in the recorder did not dismiss options.");
                ((System.Windows.Controls.Primitives.ToggleButton)window.FindName("OptionsButton")).IsChecked = true;
                await engine.StartAsync(new("UI smoke", true, false));
                await Task.Delay(350);
                if (!model.IsActive || !model.Stop.CanExecute(null)) throw new Exception("Recording commands not updated.");
                ((MenuItem)window.FindName("QuitMenuItem")).RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
                if (quitRequests != 2 || engine.Snapshot.State != RecordingState.Recording) throw new Exception("Recording quit bypassed application confirmation or lost its callback.");
                if (!((FrameworkElement)window.FindName("CapturePanel")).IsVisible || ((FrameworkElement)window.FindName("SetupPanel")).IsVisible || ((System.Windows.Controls.Primitives.Popup)window.FindName("OptionsPopup")).IsOpen)
                    throw new Exception("Active recording did not replace configuration or close its popup.");
                model.RequestAttention(AttentionAction.DurationLimit);
                if (!model.HasAttention || engine.Snapshot.State != RecordingState.Recording) throw new Exception("Duration reminder unexpectedly stopped recording.");
                model.KeepRecording.Execute(null);
                if (model.HasAttention || engine.Snapshot.State != RecordingState.Recording) throw new Exception("Keep recording did not dismiss reminder safely.");
                window.Hide();
                await Task.Delay(200);
                if (engine.Snapshot.State != RecordingState.Recording) throw new Exception("Hiding the window interrupted recording.");
                var recording = await engine.StopAsync();
                await app.Dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
                if (model.IsActive || recording?.State != RecordingState.Done) throw new Exception("Stop state did not reach UI.");
                window.Show();
                await app.Dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
                if (!((FrameworkElement)window.FindName("DonePanel")).IsVisible || ((FrameworkElement)window.FindName("SetupPanel")).IsVisible) throw new Exception("Saved recording did not show its result row.");
                ((Button)window.FindName("ViewSavedButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                if (openedRecordingId != recording!.Id) throw new Exception("View saved recording did not target this recording.");
                model.NewRecording.Execute(null);
                await app.Dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
                if (!model.ShowSetup || model.IsDone || !File.Exists(recording.AudioPath) || !((FrameworkElement)window.FindName("SetupPanel")).IsVisible) throw new Exception("New recording did not restore setup while preserving the saved file.");
                var library = new LibraryWindow(store) { ShowActivated = false };
                library.RefreshRecordings(recording.Id); library.Show();
                await app.Dispatcher.InvokeAsync(() => library.UpdateLayout(), DispatcherPriority.ApplicationIdle);
                var list = (ListBox)library.FindName("Recordings");
                if (list.Items.Count != 1) throw new Exception("Saved recording missing from native library.");
                if ((list.SelectedItem as LocalRecording)?.Id != recording.Id) throw new Exception("Requested library recording was not selected.");
                list.SelectedIndex = 0;
                await app.Dispatcher.InvokeAsync(() => library.UpdateLayout(), DispatcherPriority.ApplicationIdle);
                if (!((Button)library.FindName("PlayButton")).IsEnabled) throw new Exception("Completed recording cannot be played.");
                await library.ImportFileAsync(recording!.AudioPath);
                if (list.Items.Count != 2 || list.SelectedItem is not LocalRecording imported || imported.Id == recording.Id || !((Button)library.FindName("PlayButton")).IsEnabled)
                    throw new Exception("Imported audio did not appear selected and playable in the library.");
                if (!((Button)library.FindName("ImportButton")).IsEnabled || ((Button)library.FindName("CancelImportButton")).Visibility != Visibility.Collapsed)
                    throw new Exception("Import controls did not return to idle.");
                // Simulate the persisted state left by an interrupted process, then use
                // the real recovery and native media paths (no upload/network request).
                library.RefreshRecordings(recording.Id); // Release the imported file's player handle.
                store.Save(imported with { State = RecordingState.Recording, DurationMs = 0 });
                if (store.RecoverInterruptedRecordings() != 1) throw new Exception("Interrupted library entry was not recovered.");
                library.RefreshRecordings(imported.Id);
                if (list.SelectedItem is not LocalRecording { State: RecordingState.Error, DurationMs: > 0 } ||
                    !((Button)library.FindName("PlayButton")).IsEnabled || ((Button)library.FindName("UploadButton")).IsEnabled ||
                    !((TextBlock)library.FindName("Status")).Text.Contains("意外中断"))
                    throw new Exception("Recovered audio was not playable with an interruption warning, or became uploadable.");
                var recoveredPosition = (Slider)library.FindName("Position");
                for (var attempt = 0; attempt < 100 && !recoveredPosition.IsEnabled; attempt++) await Task.Delay(50);
                if (!recoveredPosition.IsEnabled || recoveredPosition.Maximum <= 0) throw new Exception("Native player could not open recovered WAV.");
                library.Close(); window.Close();
                await LocalPlaybackTests.RunAsync(root);
                await LocalRemovalTests.RunAsync(root);
                await DiscardLifecycleTests.RunAsync(root, app.Dispatcher);
                await KeyboardPlaybackTests.RunAsync(root);
                await ProcessingRecoveryTests.RunAsync(root);
                await CloudLibraryTests.RunAsync(root, app.Dispatcher);
                await LibraryViewRetentionTests.RunAsync(root, app.Dispatcher, holdForDump: args.Contains("--hold-for-dump"));
                await LocalDetailScrollingTests.RunAsync(root, app.Dispatcher);
                await CloudCompletionLayoutTests.RunAsync(root, app.Dispatcher);
                await ImportLifecycleTests.RunAsync(root, app.Dispatcher);
                await LibraryProfile.RunAsync(smokeOnly: true);
                await CloudSearchTests.RunAsync(root, app.Dispatcher);
                await TranscriptPanelTests.RunAsync(root, app.Dispatcher);
                await AskPanelTests.RunAsync(root, app.Dispatcher);
                await CaptionWindowTests.RunAsync();
                await WindowVisibilityTests.RunAsync();
                await BillingPanelTests.RunAsync(root);
                await SettingsWindowTests.RunAsync(root);
                await SourceSelectionTests.RunAsync(root, app.Dispatcher);
                await RecordingNotificationTests.RunAsync(root, app.Dispatcher);
                await OnboardingWindowTests.RunAsync(root);
                await UpdatePanelTests.RunAsync(root);
                await ThemeTests.RunAsync(root, app.Dispatcher);
                await ReviewPanelTests.RunAsync(root, app.Dispatcher);
                await CloudLibraryActionTests.RunAsync(root, app.Dispatcher);
                var audio = new AudioPlayer();
                double? lastPosition = null;
                audio.PlaybackPositionChanged += position => lastPosition = position;
                var audioWindow = new Window { Content = audio, ShowActivated = false }; audioWindow.Show();
                var audioCopy = Path.Combine(root, "download.wav"); File.Copy(recording!.AudioPath, audioCopy);
                audio.Open(audioCopy, .1);
                var audioPlay = (Button)audio.FindName("PlayButton");
                for (var attempt = 0; attempt < 100 && !audioPlay.IsEnabled; attempt++) await Task.Delay(50);
                if (!audioPlay.IsEnabled || ((Slider)audio.FindName("Position")).Value < .09) throw new Exception("Native audio did not open/seek downloaded audio.");
                if (lastPosition is not >= .09) throw new Exception("Native seek did not report playback position.");
                var audioPosition = (Slider)audio.FindName("Position");
                foreach (var key in new[] { System.Windows.Input.Key.Tab, System.Windows.Input.Key.LeftShift, System.Windows.Input.Key.Space, System.Windows.Input.Key.A })
                {
                    var before = audio.PlaybackSeconds;
                    audioPosition.Value = .4;
                    audioPosition.RaiseEvent(new System.Windows.Input.KeyEventArgs(System.Windows.Input.Keyboard.PrimaryDevice, PresentationSource.FromVisual(audioWindow), Environment.TickCount, key)
                        { RoutedEvent = UIElement.KeyDownEvent });
                    audioPosition.RaiseEvent(new System.Windows.Input.KeyEventArgs(System.Windows.Input.Keyboard.PrimaryDevice, PresentationSource.FromVisual(audioWindow), Environment.TickCount, key)
                        { RoutedEvent = UIElement.PreviewKeyUpEvent });
                    if (audio.PlaybackSeconds != before) throw new Exception("Unrelated key changed cloud audio playback position: " + key);
                }
                audioPlay.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                await Task.Delay(100);
                audio.Clear(); audioWindow.Close();
                if (lastPosition is not null) throw new Exception("Cleared player retained active transcript position.");
                Console.WriteLine("PASS native media opens downloaded WAV content, applies pending citation seek and clears playback.");
                Console.WriteLine("PASS native WPF window construction, bindings, command states, hide/restore during recording, local library selection.");
                exit = 0;
            }
            catch (Exception error) { Console.Error.WriteLine(error); }
            finally { app.Shutdown(); }
        };
        app.Run();
        return exit;
    }

    private sealed class SilenceInput : IAudioInput
    {
        public string Input => "system";
        public Exception? Error => null;
        public void Start() { }
        public void Stop() { }
        public void Dispose() { }
        public void Read(float[] destination) => Array.Clear(destination);
    }
}
