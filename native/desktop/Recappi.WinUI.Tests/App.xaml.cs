using System.Reflection;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Recappi.Core;

namespace Recappi.WinUI.Tests;

public partial class TestApp : Application
{
    [System.Runtime.InteropServices.DllImport("ole32.dll")]
    private static extern int CoGetApartmentType(out int apartmentType, out int qualifier);

    private Window? keeper;
    public TestApp() { InitializeComponent(); }
    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var root = Path.GetFullPath(Path.Combine("build", "native-desktop-validation", "winui-tests-" + Guid.NewGuid().ToString("N")));
        Directory.CreateDirectory(root);
        UnhandledException += (_, error) => File.WriteAllText(Path.Combine(root, "unhandled.txt"), error.Message + "\n" + error.Exception);
        var apartmentResult = CoGetApartmentType(out var apartmentType, out var apartmentQualifier);
        var managedApartment = Thread.CurrentThread.GetApartmentState();
        File.WriteAllText(Path.Combine(root, "run-identity.json"), JsonSerializer.Serialize(new
        {
            processId = Environment.ProcessId,
            managedApartment = managedApartment.ToString(),
            apartmentResult,
            apartmentType,
            apartmentQualifier
        }));
        if (apartmentResult < 0 || apartmentType is not (0 or 3) || managedApartment != ApartmentState.STA)
        {
            File.WriteAllText(Path.Combine(root, "failure.txt"), "WinUI validation requires the production STA COM apartment.");
            File.WriteAllText(Path.Combine(root, "report.json"), JsonSerializer.Serialize(new { framework = "WinUI3", passed = Array.Empty<string>(), success = false, processId = Environment.ProcessId }));
            Environment.ExitCode = 1;
            Exit();
            return;
        }
        File.WriteAllText(Path.Combine(root, "stage.txt"), "launch dispatch");
        var passed = new List<string>(); var exit = 1;
        var commandLine = Environment.GetCommandLineArgs();
        var focusOwnerArgument = Array.IndexOf(commandLine, "--focus-owner");
        if (focusOwnerArgument >= 0)
        {
            await ExternalFocusOwner(commandLine[focusOwnerArgument + 1]); Exit(); return;
        }
        Window? captureStart = null;
        if (commandLine.Contains("--interactive-preview"))
        {
            var begin = new Button { Content = "开始原生窗口采集", Margin = new Thickness(24) };
            var ready = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            begin.Click += (_, _) => ready.TrySetResult();
            captureStart = new Window { Title = "Recappi WinUI · 开始采集", Content = begin };
            captureStart.Activate();
            File.WriteAllText(Path.Combine(root, "stage.txt"), "waiting for capture start click");
            try { await ready.Task.WaitAsync(TimeSpan.FromSeconds(60)); }
            catch (TimeoutException) { captureStart.Close(); Environment.ExitCode = 1; Exit(); return; }
        }
        if (Environment.GetCommandLineArgs().Contains("--preview-library") || Environment.GetCommandLineArgs().Contains("--capture-native-previews") || Environment.GetCommandLineArgs().Contains("--probe-library-scroll"))
        {
            await LibraryPreview.Run(root); captureStart?.Close(); Exit(); return;
        }
        if (commandLine.Contains("--probe-basic-window") || commandLine.Contains("--probe-border-window"))
        {
            keeper = new Window { Title = "Recappi WinUI · framework probe", Content = new Button { Content = "Native button" } };
            if (commandLine.Contains("--probe-border-window"))
                ((Microsoft.UI.Windowing.OverlappedPresenter)keeper.AppWindow.Presenter).SetBorderAndTitleBar(commandLine.Contains("--keep-border"), false);
            keeper.Activate();
            await Task.Delay(30000);
            File.WriteAllText(Path.Combine(root, "basic-window.json"), "{\"visibleForThirtySeconds\":true}");
            keeper.Close(); Exit(); return;
        }
        var keeperReady = new TaskCompletionSource();
        File.WriteAllText(Path.Combine(root, "stage.txt"), "creating keeper");
        var keeperContent = new Grid(); keeperContent.Loaded += (_, _) => keeperReady.TrySetResult();
        keeper = new Window { Title = "Recappi WinUI validation host", Content = keeperContent }; keeper.Activate();
        await keeperReady.Task; keeper.AppWindow.Hide();
        File.WriteAllText(Path.Combine(root, "stage.txt"), "keeper ready");
        if (commandLine.Contains("--preview-input-calibration"))
        {
            await InputCalibrationPreview.Run(root); keeper.Close(); Exit(); return;
        }
        if (commandLine.Contains("--probe-recorder-drag"))
        {
            try { await RecorderInputProbe.DragFromControl(root); } catch (Exception error) { Console.WriteLine(error.Message); }
            keeper.Close(); Exit(); return;
        }
        if (commandLine.Contains("--probe-recorder-hover"))
        {
            await RecorderInputProbe.Hover(root); keeper.Close(); Exit(); return;
        }
        if (commandLine.Contains("--probe-recorder-input"))
        {
            await RecorderInputProbe.Run(root); keeper.Close(); Exit(); return;
        }
        if (commandLine.Contains("--capture-page-previews"))
        {
            await NativePreviewCapture.Auxiliary(root); keeper.Close(); Exit(); return;
        }
        if (commandLine.Contains("--capture-caption-previews"))
        {
            await NativePreviewCapture.Caption(root); keeper.Close(); Exit(); return;
        }
        if (commandLine.Contains("--capture-recorder-previews"))
        {
            await NativePreviewCapture.RecorderOnly(root); captureStart?.Close(); keeper.Close(); Exit(); return;
        }
        if (commandLine.Contains("--capture-update-previews"))
        {
            await NativePreviewCapture.UpdateChannels(root); captureStart?.Close(); keeper.Close(); Exit(); return;
        }
        if (Environment.GetCommandLineArgs().Contains("--preview-captions"))
        {
            await CaptionPreview.Run(); keeper.Close(); Exit(); return;
        }
        try
        {
            await Run("window-show-hide-and-restore", ShowHideRestore);
            await Run("caption-passive-first-show", PassiveCaption);
            await Run("caption-external-process-focus", () => ExternalCaptionFocus(root));
            await Run("first-reveal-cancellation", FirstRevealCancellation);
            await Run("recorder-state-and-audio", () => Recorder(root));
            await Run("recorder-saved-processing", () => RecorderProcessing(root));
            await Run("recorder-content-sizing", () => RecorderContentSizing(root));
            await Run("caption-order-and-bounds", Captions);
            await Run("settings-failure-and-merge", () => Settings(root));
            await Run("dialog-height-fits-content", () => DialogHeights(root));
            await Run("button-hit-areas", () => ButtonHitAreas(root));
            await Run("settings-update-distribution", () => SettingsUpdateDistribution(root));
            await Run("settings-update-errors", () => SettingsUpdateErrors(root));
            await Run("onboarding-save-before-navigation", () => Onboarding(root));
            await Run("library-removal-context", () => Library(root));
            await Run("library-import-lifecycle", () => ImportLifecycle(root));
            await Run("library-playback-seek-and-isolation", () => Playback(root));
            await Run("library-refresh-copy-and-draft", () => LibraryRefresh(root));
            await Run("library-long-local-transcript", () => LongLocalTranscript(root));
            await Run("cloud-account-context", () => CloudIsolation(root));
            await Run("library-auto-load-more", () => AutoLoadMore(root));
            await Run("cloud-missing-transcript-recovery", () => MissingTranscript(root));
            await Run("ask-draft-and-cancellation", () => Ask(root));
            await Run("retranscription-provider-and-confirmation", () => Review(root));
            Check(passed.Count > 0, "No test matched the requested filter.");
            if (AppDomain.CurrentDomain.GetAssemblies().Any(x => x.GetName().Name is "PresentationFramework" or "PresentationCore")) throw new Exception("WPF loaded into WinUI test process.");
            exit = 0;
        }
        catch (Exception error) { Console.Error.WriteLine(error); File.WriteAllText(Path.Combine(root, "failure.txt"), error.ToString()); }
        finally
        {
            File.WriteAllText(Path.Combine(root, "report.json"), JsonSerializer.Serialize(new { framework = "WinUI3", passed, success = exit == 0, processId = Environment.ProcessId }, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine("Report: " + root); Environment.ExitCode = exit; keeper.Close(); Exit();
        }
        async Task Run(string name, Func<Task> test)
        {
            var only = Array.IndexOf(commandLine, "--only");
            if (only >= 0 && (only + 1 >= commandLine.Length || commandLine[only + 1] != name)) return;
            File.WriteAllText(Path.Combine(root, "stage.txt"), name); await test(); passed.Add(name); Console.WriteLine("PASS " + name);
        }
    }
    internal static IEnumerable<T> Descendants<T>(DependencyObject root)
    {
        for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(root); i++)
        {
            var child = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(root, i);
            if (child is T match) yield return match;
            foreach (var nested in Descendants<T>(child)) yield return nested;
        }
    }
    [System.Runtime.InteropServices.DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    internal static T Field<T>(object target, string name) => (T)(target.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic) ?? throw new Exception("Missing field " + name)).GetValue(target)!;
    internal static async Task Call(object target, string method, params object[] arguments)
    {
        var info = target.GetType().GetMethod(method, BindingFlags.Instance | BindingFlags.NonPublic) ?? throw new Exception("Missing method " + method);
        var value = info.Invoke(target, arguments);
        if (value is Task task) await task;
    }
    internal static async Task Until(Func<bool> condition, string reason)
    {
        var deadline = DateTime.UtcNow.AddSeconds(8);
        while (!condition()) { if (DateTime.UtcNow > deadline) throw new Exception(reason); await Task.Delay(20); }
    }
    internal static void Check(bool condition, string reason) { if (!condition) throw new Exception(reason); }
    private static void Click(Button button)
    {
        Check(button.IsEnabled, "Attempt to invoke disabled control.");
        var peer = FrameworkElementAutomationPeer.CreatePeerForElement(button) ?? throw new Exception("Button has no automation peer.");
        ((IInvokeProvider)peer.GetPattern(PatternInterface.Invoke)).Invoke();
    }
    private static async Task Recorder(string root)
    {
        void Stage(string value) => File.WriteAllText(Path.Combine(root, "recorder-stage.txt"), value);
        Stage("host");
        await using var host = new TestHost(Path.Combine(root, "recorder"));
        Stage("window");
        var window = new RecorderWindow(host, () => ([new AudioSource("system", "Controlled audio")], [new MicrophoneDevice("microphone", "Controlled microphone", true)]));
        Stage("show");
        window.Show();
        try
        {
            await window.RefreshDevices();
            await Until(() => Field<Button>(window, "start").IsLoaded, "Recorder did not finish loading.");
            await Until(() => window.IsUserVisible, "Recorder did not finish its first reveal.");
            // The recorder is a non-activating panel like macOS: showing it never takes activation.
            Check(GetForegroundWindow() != WinRT.Interop.WindowNative.GetWindowHandle(window), "Recorder took activation when shown.");
            var focusedButton = Field<Button>(window, "start");
            Check(focusedButton.Focus(FocusState.Keyboard), "Cannot focus recorder action.");
            window.Show();
            Check(ReferenceEquals(Microsoft.UI.Xaml.Input.FocusManager.GetFocusedElement(window.Content.XamlRoot), focusedButton),
                "Showing the recorder reset an existing keyboard focus.");
            Stage("start");
            Click(Field<Button>(window, "start"));
            await Until(() => host.Engine.Snapshot.State == RecordingState.Recording, "Start button did not record.");
            await Until(() => Field<DotMatrixMeter>(window, "waveform").Latest > 0, "Recorded audio did not reach WinUI meter.");
            var id = host.Engine.Snapshot.Recording!.Id;
            Stage("hide");
            window.Hide(); await Task.Delay(200);
            Check(!window.IsUserVisible && window.AppWindow.IsVisible, "Recorder did not retain its hidden surface.");
            Check(host.Engine.Snapshot.State == RecordingState.Recording && host.Engine.Snapshot.Recording.Id == id, "Hiding stopped or changed recording.");
            window.Show();
            Stage("cancel discard");
            window.ConfirmAction = (_, _, _) => Task.FromResult(false); Click(Field<Button>(window, "discard")); await Task.Delay(100);
            Check(host.Engine.Snapshot.State == RecordingState.Recording, "Cancel discard stopped recording.");
            Click(Field<Button>(window, "stop"));
            Stage("stop");
            await Until(() => host.Engine.Snapshot.State == RecordingState.Done, "Stop did not save recording.");
            Check(new FileInfo(host.Engine.Snapshot.Recording!.AudioPath).Length > 4800, "Saved audio missing.");
            await Task.Delay(100); Click(Field<Button>(window, "newRecording")); Click(Field<Button>(window, "start"));
            Stage("second start");
            await Until(() => host.Engine.Snapshot.State == RecordingState.Recording && host.Engine.Snapshot.Recording?.Id != id, "Second recording did not start.");
            await Until(() => Field<Button>(window, "discard").IsEnabled, "Recorder did not become ready after starting.");
            window.ConfirmAction = (_, _, _) => Task.FromResult(true); Click(Field<Button>(window, "discard"));
            Stage("discard");
            await Until(() => host.Engine.Snapshot.State == RecordingState.Idle, "Confirmed discard did not end recording.");
            Check(host.Store.List().Count == 1 && host.Store.List()[0].Id == id, "Discard affected the previously saved recording.");
        }
        finally { Stage("close"); window.Close(); }
    }
    private static async Task Captions()
    {
        var window = new CaptionWindow(() => Task.CompletedTask); window.Show();
        try
        {
            window.Reset(true);
            Check(Field<CheckBox>(window, "compact").IsChecked == true, "Captions did not default to compact mode.");
            Field<CheckBox>(window, "compact").IsChecked = false;
            window.Update(new("b", "source", "Bravo", true, new("s", 0)));
            window.Update(new("a", "source", "Alpha", true, new("s", 1)));
            window.UpdateBatch([new("a", "source", "Alpha", true, new("s", 0)), new("b", "source", "Bravo", true, new("s", 1))]);
            Check(Field<TextBlock>(window, "original").Text == "Alpha\n\nBravo", "Caption predecessor order not reflected in WinUI.");
            window.Update(new("translated", "translation", "双语长句末尾", true, new("s", 2)));
            Check(Field<TextBlock>(window, "translation").Text.Contains("双语长句末尾"), "Translation missing.");
            Field<CheckBox>(window, "showOriginal").IsChecked = false; Field<CheckBox>(window, "showTranslation").IsChecked = false;
            Check(Field<CheckBox>(window, "showOriginal").IsChecked == true, "Both caption streams could be hidden.");
            for (var index = 0; index < 500; index++) window.Update(new("item" + index, "source", "Line " + index, true, new("s", index + 10)));
            Check(Field<Dictionary<(string, string), CaptionDelta>>(window, "segments").Count == 256, "Live captions unbounded.");
            var scroll = Field<ScrollViewer>(window, "originalScroll");
            var follow = Field<CheckBox>(window, "follow");
            await Until(() => scroll.ScrollableHeight > 100, "Caption history never became scrollable.");
            await Until(() => window.IsUserVisible, "Caption window never finished appearing.");
            await Until(() => Math.Abs(scroll.VerticalOffset - scroll.ScrollableHeight) < 2,
                "Initial caption history did not follow the latest line after layout.");
            await Task.Delay(250);
            CheckCaptionContentFits(window);
            var historyHeight = window.AppWindow.ClientSize.Height;
            follow.IsChecked = false;
            scroll.ChangeView(null, 100, null, true);
            await Until(() => Math.Abs(scroll.VerticalOffset - 100) < 2, "Cannot read an earlier caption.");
            // Cancel a pending follow request before its dispatcher callback runs.
            follow.IsChecked = true;
            follow.IsChecked = false;
            await Task.Delay(250);
            Check(Math.Abs(scroll.VerticalOffset - 100) < 2, "Disabling follow did not cancel a queued jump to the latest caption.");
            window.Update(new("item499", "source", "Updated last sentence", true, new("s", 509)));
            await Task.Delay(250);
            Check(Math.Abs(scroll.VerticalOffset - 100) < 2, "A new caption moved the paused history viewport.");
            follow.IsChecked = true;
            await Until(() => Math.Abs(scroll.VerticalOffset - scroll.ScrollableHeight) < 2, "Resuming follow did not reach the latest caption.");
            window.Update(new("item499", "source", "Line 499", true, new("s", 509)));
            Field<CheckBox>(window, "compact").IsChecked = true;
            // Compact runs recent segments together so a short segment is never shown alone.
            var running = Field<TextBlock>(window, "original").Text;
            Check(running.EndsWith("Line 499") && running.Contains("Line 498 Line 499"), "Compact caption does not show the latest running text: " + running);
            await Until(() => window.AppWindow.ClientSize.Height < historyHeight,
                "Collapsing caption history retained its expanded height.");
            await Task.Delay(250);
            CheckCaptionContentFits(window);
            window.Reset(true);
            Field<CheckBox>(window, "showTranslation").IsChecked = true;
            window.Update(new("long", "source", string.Join(" ", Enumerable.Repeat("A long sentence must wrap and remain readable in the compact caption panel.", 6)), true, new("expand", 0)));
            window.Update(new("long", "translation", string.Concat(Enumerable.Repeat("长字幕应当换行，紧凑面板也必须保留可读内容，不能把最后一行裁掉。", 6)), true, new("expand", 0)));
            window.Update(new("failed", "source", "Latest partial sentence", true, new("expand", 1), IsFailed: true));
            await Task.Delay(250);
            var translatedScroll = Field<ScrollViewer>(window, "translationScroll");
            await Until(() => translatedScroll.ScrollableHeight > 0, "Long compact translation did not overflow.");
            await Until(() => Math.Abs(translatedScroll.VerticalOffset - translatedScroll.ScrollableHeight) < 2,
                "Long compact translation did not follow its last line after layout.");
            Field<CheckBox>(window, "compact").IsChecked = false;
            await Until(() => scroll.ScrollableHeight > 100, "Expanded long caption history did not overflow.");
            await Until(() => Math.Abs(scroll.VerticalOffset - scroll.ScrollableHeight) < 2,
                "Expanding caption history did not follow the latest line after layout.");
        }
        finally { window.Close(); }
    }
    private static void CheckCaptionContentFits(CaptionWindow window)
    {
        var scale = window.Content.XamlRoot.RasterizationScale;
        var bodyBottom = window.Body.TransformToVisual(window.Content).TransformPoint(new(0, window.Body.ActualHeight)).Y;
        var clientHeight = window.AppWindow.ClientSize.Height / scale;
        // The pill window carries a transparent shadow margin around the visible surface.
        Check(bodyBottom <= clientHeight - window.ChromeMargin + 1, "Caption content is clipped below the visible pill.");
        Check(clientHeight - window.ChromeMargin - bodyBottom <= 4, "Caption client area has excess blank space below its content.");
    }
    // Icon-only buttons have square hit/hover areas of at least 22pt, centred on the glyph.
    private static async Task ButtonHitAreas(string root)
    {
        await using var host = new TestHost(Path.Combine(root, "hit-areas"));
        await host.SignIn();
        var report = new List<string>(); var problems = new List<string>();
        void Audit(string window, UIElement content)
        {
            static bool Shown(DependencyObject element)
            {
                for (var node = element; node is not null; node = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetParent(node))
                    if (node is UIElement { Visibility: Visibility.Collapsed }) return false;
                return true;
            }
            foreach (var button in Descendants<Microsoft.UI.Xaml.Controls.Primitives.ButtonBase>(content).Where(x => x.ActualWidth > 0 && Shown(x)))
            {
                var name = Microsoft.UI.Xaml.Automation.AutomationProperties.GetName(button);
                var iconOnly = button.Content is IconElement or Microsoft.UI.Xaml.Shapes.Shape or Border { Child: null } or Grid { Children.Count: <= 2 } && button.Content is not FrameworkElement { ActualWidth: > 40 };
                report.Add($"{window} {name} {button.GetType().Name} {button.ActualWidth:0.#}x{button.ActualHeight:0.#} iconOnly={iconOnly}");
                // The whole button is hit-testable, not just its glyph or label.
                if (button is not Microsoft.UI.Xaml.Controls.Primitives.RepeatButton && button.ActualWidth > 8 && button.ActualHeight > 8)
                    foreach (var probe in new[] { new Windows.Foundation.Point(3, button.ActualHeight / 2), new Windows.Foundation.Point(button.ActualWidth / 2, 3), new Windows.Foundation.Point(button.ActualWidth - 3, button.ActualHeight / 2) })
                    {
                        var at = button.TransformToVisual(null).TransformPoint(probe);
                        if (!Microsoft.UI.Xaml.Media.VisualTreeHelper.FindElementsInHostCoordinates(at, content).Contains(button)) { problems.Add($"{window} {name} not hit-testable at {probe}"); break; }
                    }
                // Floating panels have no scroll bar strip over their controls.
                if (button is Microsoft.UI.Xaml.Controls.Primitives.RepeatButton && window.StartsWith("recorder") | window == "captions") problems.Add($"{window} scroll bar {name}");
                if (iconOnly && (Math.Abs(button.ActualWidth - button.ActualHeight) > 1 || Math.Min(button.ActualWidth, button.ActualHeight) < 22))
                    problems.Add($"{window} {name} {button.ActualWidth:0.#}x{button.ActualHeight:0.#}");
            }
        }
        var recorder = new RecorderWindow(host, () => ([new AudioSource("system", "System")], [new MicrophoneDevice("microphone", "Mic", true)]));
        try
        {
            await recorder.RefreshDevices(); recorder.Show(); await Until(() => recorder.IsUserVisible, "Recorder did not appear."); await Task.Delay(300);
            Audit("recorder-idle", recorder.Content);
            Click(Field<Button>(recorder, "start")); await Until(() => host.Engine.Snapshot.State == RecordingState.Recording, "Recording did not start."); await Task.Delay(400);
            Audit("recorder-recording", recorder.Content);
            Click(Field<Button>(recorder, "stop")); await Until(() => host.Engine.Snapshot.State == RecordingState.Done, "Recording did not stop."); await Task.Delay(300);
            Audit("recorder-done", recorder.Content);
        }
        finally { recorder.Close(); }
        var caption = new CaptionWindow(() => Task.CompletedTask); caption.Show();
        try { await Task.Delay(400); var chrome = Field<Border>(caption, "chrome"); chrome.Opacity = 1; chrome.IsHitTestVisible = true; await Task.Delay(100); Audit("captions", caption.Content); }
        finally { caption.Close(); }
        var library = new LibraryWindow(host); library.Show();
        try { await library.Refresh(); await Task.Delay(500); Audit("library", library.Content); }
        finally { library.Close(); }
        var settings = new SettingsWindow(host, false); settings.Show();
        try { await Task.Delay(500); Audit("settings", settings.Content); }
        finally { settings.Close(); }
        var account = new AccountWindow(host); account.Show();
        try { await Task.Delay(500); Audit("account", account.Content); }
        finally { account.Close(); }
        await File.WriteAllLinesAsync(Path.Combine(root, "button-hit-areas.txt"), report);
        Console.WriteLine(string.Join(Environment.NewLine, report));
        Check(problems.Count == 0, "Icon buttons with non-square or small hit areas: " + string.Join("; ", problems));
    }
    // Account and settings size their height to the content, per settings tab.
    private static async Task DialogHeights(string root)
    {
        await using var host = new TestHost(Path.Combine(root, "dialog-heights"));
        static bool Fits(DesktopWindow window, ScrollViewer scroll) =>
            scroll.ViewportHeight > 0 && scroll.Content is UIElement { DesiredSize.Height: > 0 } content && content.DesiredSize.Height <= scroll.ViewportHeight + 3 &&
            // Short content stops at the 240-point floor.
            (scroll.ViewportHeight - content.DesiredSize.Height <= 3 || window.AppWindow.ClientSize.Height / window.Content.XamlRoot.RasterizationScale <= 242);
        var account = new AccountWindow(host); account.Show();
        try
        {
            var page = Descendants<ScrollViewer>(account.Content).First(x => ReferenceEquals(x.Content, account.Body));
            await Until(() => Fits(account, page), "Account window height did not fit its content.");
        }
        finally { account.Close(); }
        var settings = new SettingsWindow(host, false); settings.Show();
        try
        {
            var navigation = Field<NavigationView>(settings, "navigation"); var viewer = Field<ScrollViewer>(settings, "sectionViewer");
            var heights = new List<int>();
            for (var i = 0; i < navigation.MenuItems.Count; i++)
            {
                navigation.SelectedItem = navigation.MenuItems[i];
                await Until(() => Fits(settings, viewer), $"Settings tab {i} height did not fit its content.");
                heights.Add(settings.AppWindow.ClientSize.Height);
            }
            Check(heights.Distinct().Count() > 1, "Settings tabs did not resize the window: " + string.Join(",", heights));
        }
        finally { settings.Close(); }
    }
    private static async Task Settings(string root)
    {
        await using var host = new TestHost(Path.Combine(root, "settings"));
        var window = new SettingsWindow(host, true); window.Show();
        try
        {
            var sections = Field<Dictionary<string, StackPanel>>(window, "sections");
            var navigation = Field<NavigationView>(window, "navigation");
            for (var pass = 0; pass < 3; pass++)
                foreach (NavigationViewItem item in navigation.MenuItems)
                {
                    navigation.SelectedItem = item;
                    await Until(() => sections[(string)item.Tag].IsLoaded, "Revisited settings section did not load.");
                }
            navigation.SelectedItem = navigation.MenuItems[2];
            await Until(() => sections["录音与字幕"].IsLoaded, "Caption settings did not become visible.");
            var language = Descendants<TextBox>(sections["录音与字幕"]).First(x => (string)x.Tag == "字幕语言");
            language.Text = "zh"; host.SavePreferences(host.Preferences with { Scene = "interview" });
            host.RejectSave = true; Check(!window.Flush(), "Settings falsely reported save success.");
            Check(Field<Button>(window, "retrySave").Visibility == Visibility.Visible, "Failed settings save has no retry action.");
            host.RejectSave = false; Check(window.Flush(), "Settings failed retry.");
            Check(Field<Button>(window, "retrySave").Visibility == Visibility.Collapsed, "Successful retry left stale failure action.");
            Check(host.Preferences.CaptionLanguage == "zh" && host.Preferences.Scene == "interview", "Settings overwrote unrelated concurrent preferences.");
        }
        finally { window.Close(); }
    }
    private static async Task SettingsUpdateDistribution(string root)
    {
        Check(DesktopDistributionDetector.Detect() == DesktopDistribution.Portable, "Unpackaged test executable identity was not detected.");
        await using var host = new TestHost(Path.Combine(root, "settings-update-distribution"));
        foreach (var distribution in Enum.GetValues<DesktopDistribution>())
        {
            var created = 0;
            var window = new SettingsWindow(host, false, distribution, () => { created++; throw new InvalidOperationException("Unexpected update request."); });
            window.Show();
            try
            {
                var navigation = Field<NavigationView>(window, "navigation");
                navigation.SelectedItem = navigation.MenuItems[5];
                var section = Field<Dictionary<string, StackPanel>>(window, "sections")["关于"];
                await Until(() => section.IsLoaded, "Update section did not load.");
                var labels = Descendants<Button>(section).Where(button => button.Visibility == Visibility.Visible).Select(button => button.Content as string).ToArray();
                Check(labels.Contains("检查更新") == (distribution == DesktopDistribution.Portable), "Update check exposed for wrong installation channel.");
                Check(labels.Contains("发布页面") == (distribution == DesktopDistribution.Portable), "Portable release page exposed for wrong installation channel.");
                Check(labels.Contains("打开 Microsoft Store 更新") == (distribution == DesktopDistribution.Packaged), "Store entry exposed for wrong installation channel.");
                Check((Field<Button>(window, "downloadUpdate").Parent is not null) == (distribution == DesktopDistribution.Portable), "ZIP download exposed for wrong installation channel.");
                if (distribution != DesktopDistribution.Portable)
                {
                    var initial = Field<TextBlock>(window, "updateStatus").Text;
                    Check(!string.IsNullOrWhiteSpace(initial), "Installation channel has no update guidance.");
                    await Call(window, "CheckUpdate");
                    // A stale available release must not bypass the installation-channel guard.
                    typeof(SettingsWindow).GetField("release", BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(window,
                        new DesktopRelease("9.0.0", DesktopUpdates.ReleasesPage, new Uri("https://example.invalid/update.zip"), "update.zip", 1, new string('a', 64)));
                    await Call(window, "DownloadUpdate").WaitAsync(TimeSpan.FromSeconds(3));
                    Check(created == 0 && Field<TextBlock>(window, "updateStatus").Text == initial, "Blocked update command reached the portable service.");
                }
                else
                {
                    await Call(window, "CheckUpdate");
                    Check(created == 1 && Field<TextBlock>(window, "updateStatus").Text.Contains("无法检查更新"), "Failed update check has no recovery guidance.");
                    Check(!Field<Button>(window, "downloadUpdate").IsEnabled && !Field<bool>(window, "checkingUpdate"), "Failed update check left stale download or busy state.");
                }
            }
            finally { window.Close(); }
        }
    }
    private static async Task SettingsUpdateErrors(string root)
    {
        await using var host = new TestHost(Path.Combine(root, "settings-update-errors"));
        foreach (var (error, expected) in new (Exception, string)[]
        {
            (new HttpRequestException("rate limit exceeded", null, System.Net.HttpStatusCode.Forbidden), "访问限额"),
            (new HttpRequestException("too many requests", null, System.Net.HttpStatusCode.TooManyRequests), "访问限额"),
            (new OperationCanceledException(), "检查超时")
        })
        {
            var attempts = 0;
            var window = new SettingsWindow(host, false, DesktopDistribution.Portable, () => { attempts++; throw error; });
            window.Show();
            try
            {
                await Call(window, "CheckUpdate");
                Check(Field<TextBlock>(window, "updateStatus").Text.Contains(expected), "Update error lacks localized recovery guidance.");
                Check(!Field<Button>(window, "downloadUpdate").IsEnabled && !Field<bool>(window, "checkingUpdate"), "Update failure left stale busy/download state.");
                await Call(window, "CheckUpdate");
                Check(attempts == 2, "Update check cannot be retried after failure.");
            }
            finally { window.Close(); }
        }
    }
    private static async Task Onboarding(string root)
    {
        await using var host = new TestHost(Path.Combine(root, "onboarding"));
        var window = new OnboardingWindow(host); window.Show();
        try
        {
            host.RejectSave = true;
            try { await Call(window, "Move", 1); } catch (TargetInvocationException) { }
            Check(Field<int>(window, "index") == 0, "Onboarding advanced after failed persistence.");
            host.RejectSave = false; await Call(window, "Move", 1);
            Check(host.Preferences.OnboardingStep == 1 && Field<int>(window, "index") == 1, "Onboarding did not persist progress.");
        }
        finally { window.Close(); }
    }
    private static async Task Library(string root)
    {
        await using var host = new TestHost(Path.Combine(root, "library"));
        var first = host.Store.Create("first") with { State = RecordingState.Done }; host.Store.Save(first); File.WriteAllBytes(first.AudioPath, [1, 2, 3]);
        var second = host.Store.Create("second") with { State = RecordingState.Done }; host.Store.Save(second);
        var window = new LibraryWindow(host); window.Show();
        try
        {
            await window.Refresh(); var list = Field<ListView>(window, "list");
            var rows = Field<IReadOnlyList<LibraryRecording>>(window, "displayed"); list.SelectedItem = rows.First(x => x.Local?.Id == first.Id); await Task.Delay(80);
            window.ConfirmAction = (_, _, _) => { list.SelectedItem = rows.First(x => x.Local?.Id == second.Id); return Task.FromResult(true); };
            await Call(window, "RemoveLocal"); Check(host.Store.List().Count == 2, "Stale remove confirmation removed a recording.");
            list.SelectedItem = rows.First(x => x.Local?.Id == first.Id); await Task.Delay(80);
            window.ConfirmAction = (_, _, _) => Task.FromResult(true); await Call(window, "RemoveLocal");
            Check(host.Store.List().Count == 1 && File.ReadAllBytes(first.AudioPath).SequenceEqual(new byte[] { 1, 2, 3 }), "Library removal deleted source audio.");
            Check(host.Store.RestoreRemovedAudio(first.AudioPath)?.Id == first.Id, "Removed recording cannot be restored.");
        }
        finally { window.Close(); }
    }
    private static async Task LongLocalTranscript(string root)
    {
        await using var host = new TestHost(Path.Combine(root, "long-local"));
        var longTitle = string.Concat(Enumerable.Repeat("长标题不应挤占逐字稿和播放操作。", 20));
        var recording = host.Store.Create(longTitle) with { State = RecordingState.Done };
        host.Store.Save(recording);
        await File.WriteAllLinesAsync(host.Store.CaptionPath(recording), Enumerable.Range(0, 10005).Select(index =>
            JsonSerializer.Serialize(new ArchivedCaption(index.ToString(), "source", "Caption " + index, DateTimeOffset.UnixEpoch, new("long", index)))));
        var window = new LibraryWindow(host); window.Show();
        try
        {
            await window.Refresh();
            Field<ListView>(window, "list").SelectedIndex = 0;
            await Until(() => Field<CloudTranscript?>(window, "content") is not null, "Long local captions did not load.");
            var loaded = Field<CloudTranscript>(window, "content");
            Check(loaded.Segments.Count == 10005 && loaded.Segments[^1].Text == "Caption 10004", "Local captions were silently truncated.");
            var sections = Field<SelectorBar>(window, "tabs"); sections.SelectedItem = sections.Items[1];
            await Until(() => Field<TextBox>(window, "filter").IsLoaded, "Transcript tab did not load.");
            var scale = window.Content.XamlRoot.RasterizationScale;
            window.AppWindow.Resize(new Windows.Graphics.SizeInt32((int)(820 * scale), (int)(560 * scale)));
            await Task.Delay(100);
            Check(Field<TextBlock>(window, "heading").Text == longTitle, "Title content was destructively shortened.");
            Check(Field<TextBlock>(window, "heading").ActualHeight < 80 && Field<ListView>(window, "transcript").ActualHeight >= 100,
                "Long title consumed the transcript viewport at the minimum window size.");
            Field<TextBox>(window, "filter").Text = "Caption 10004";
            await Until(() => Field<ListView>(window, "transcript").Items.Count == 1, "Tail caption cannot be found by filtering.");
        }
        finally { window.Close(); }
    }
    private static async Task CloudIsolation(string root)
    {
        var deletes = 0;
        await using var host = new TestHost(Path.Combine(root, "cloud"), (request, token) =>
        {
            if (request.Method == HttpMethod.Delete) deletes++;
            if (request.RequestUri!.AbsolutePath == "/api/recordings") return Task.FromResult(TestHost.Json("""{"items":[{"id":"remote","title":"Remote fixture","status":"completed","durationMs":1000}],"nextCursor":null}"""));
            return TestHost.DefaultResponse(request, token);
        });
        await host.SignIn(); var window = new LibraryWindow(host); window.Show();
        try
        {
            await window.Refresh(); Field<ListView>(window, "list").SelectedIndex = 0;
            await Until(() => Field<CloudTranscript?>(window, "content") is not null, "Cloud transcript not loaded.");
            window.ConfirmAction = async (_, _, _) => { await host.Account.SignOutAsync(); return true; };
            await Call(window, "DeleteCloud"); await Task.Delay(80);
            Check(deletes == 0 && Field<SummaryDocument>(window, "summary").Text == "", "Account changed but old cloud content/action survived.");
        }
        finally { window.Close(); }
    }
    // The sidebar fetches the next page when scrolled near its end and keeps the scroll position.
    private static async Task AutoLoadMore(string root)
    {
        var pages = 0;
        static string Items(int from, int count) => string.Join(",", Enumerable.Range(from, count).Select(i => $$"""{"id":"r{{i}}","title":"Recording {{i}}","status":"completed","durationMs":1000,"createdAt":"2026-09-{{(28 - i / 3):00}}T02:00:00Z"}"""));
        await using var host = new TestHost(Path.Combine(root, "auto-load"), (request, token) =>
        {
            if (request.RequestUri!.AbsolutePath != "/api/recordings") return TestHost.DefaultResponse(request, token);
            pages++;
            var second = request.RequestUri.Query.Contains("cursor=page2");
            return Task.FromResult(TestHost.Json(second ? $$"""{"items":[{{Items(40, 10)}}],"nextCursor":null}""" : $$"""{"items":[{{Items(0, 40)}}],"nextCursor":"page2"}"""));
        });
        await host.SignIn(); var window = new LibraryWindow(host); window.Show();
        try
        {
            await window.Refresh();
            var list = Field<ListView>(window, "list");
            await Until(() => Field<ScrollViewer?>(window, "listScroll") is { ScrollableHeight: > 0 }, "Sidebar did not become scrollable.");
            Check(pages == 1, "Sidebar loaded the next page before scrolling.");
            var viewer = Field<ScrollViewer?>(window, "listScroll")!;
            viewer.ChangeView(null, viewer.ScrollableHeight, null, true);
            await Until(() => Field<IReadOnlyList<LibraryRecording>>(window, "displayed").Count == 50, "Scrolling to the end did not load the next page.");
            await Task.Delay(200);
            Check(viewer.VerticalOffset > 0, "Loading the next page reset the sidebar to the top.");
        }
        finally { window.Close(); }
    }
    private static async Task MissingTranscript(string root)
    {
        await using var host = new TestHost(Path.Combine(root, "missing-transcript"), (request, token) =>
        {
            if (request.RequestUri!.AbsolutePath == "/api/recordings") return Task.FromResult(TestHost.Json("""{"items":[{"id":"remote","title":"Awaiting transcript","status":"failed","durationMs":1000}],"nextCursor":null}"""));
            if (request.RequestUri.AbsolutePath.EndsWith("/transcript")) return Task.FromResult(new System.Net.Http.HttpResponseMessage(System.Net.HttpStatusCode.NotFound));
            return TestHost.DefaultResponse(request, token);
        });
        await host.SignIn(); var window = new LibraryWindow(host); window.Show();
        try
        {
            await window.Refresh(); Field<ListView>(window, "list").SelectedIndex = 0;
            await Until(() => Field<ReviewPanel?>(window, "review") is { } panel && Field<Button>(panel, "transcribe").IsEnabled, "Missing transcript prevented retranscription recovery.");
            Check(Field<CloudTranscript?>(window, "content") is null, "Missing transcript was replaced with fabricated content.");
        }
        finally { window.Close(); }
    }
    private static async Task Ask(string root) => await AskTests.Run(root);
    private static async Task Review(string root) => await ReviewTests.Run(root);
}
