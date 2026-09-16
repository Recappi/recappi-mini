using System.IO;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using System.Windows.Threading;
using Recappi.Core;
using Recappi.Desktop;

internal static class DiscardLifecycleTests
{
    public static async Task RunAsync(string root, Dispatcher dispatcher)
    {
        ConfirmDialog(dispatcher);
        await ReplacedDuringCleanupAsync(root, dispatcher, replace: true);
        await ReplacedDuringCleanupAsync(root, dispatcher, replace: false);
        await ReplacedDuringConfirmationAsync(root, dispatcher);
        await CancelFailureAndSuccessAsync(root, dispatcher);
        Console.WriteLine("PASS discard confirmation/cleanup preserve changed sessions, cancel/failure retain audio, and successful discard removes only its target without publishing Saved.");
    }

    private static void ConfirmDialog(Dispatcher dispatcher)
    {
        var owner = new Window { Width = 520, Height = 80, Left = 100, Top = 100, ShowInTaskbar = false };
        owner.Show();
        try
        {
            foreach (var action in new[] { "KeepButton", "DiscardButton", "Close" })
            {
                var dialog = new DiscardRecordingDialog { Owner = owner };
                Exception? failure = null;
                dialog.Loaded += (_, _) => dispatcher.BeginInvoke(() =>
                {
                    try
                    {
                        var keep = (Button)dialog.FindName("KeepButton");
                        var discard = (Button)dialog.FindName("DiscardButton");
                        if (!keep.IsDefault || !keep.IsCancel || !keep.IsKeyboardFocused || discard.IsDefault)
                            throw new Exception("Discard confirmation did not default focus and cancellation to keeping audio.");
                        if (action == "Close") dialog.Close();
                        else ((IInvokeProvider)new ButtonAutomationPeer((Button)dialog.FindName(action)).GetPattern(PatternInterface.Invoke)).Invoke();
                    }
                    catch (Exception error) { failure = error; dialog.Close(); }
                }, DispatcherPriority.ApplicationIdle);
                var result = dialog.ShowDialog();
                if (failure is not null) throw failure;
                if ((result == true) != (action == "DiscardButton"))
                    throw new Exception("Discard confirmation returned the wrong decision for " + action);
            }
        }
        finally { owner.Close(); }
        Console.WriteLine("PASS native discard dialog defaults to keeping audio; keep, close and explicit discard return correct decisions.");
    }

    private static async Task ReplacedDuringCleanupAsync(string root, Dispatcher dispatcher, bool replace)
    {
        var store = new LocalRecordingStore(Path.Combine(root, "discard-stopped-session-" + replace));
        await using var engine = new RecordingEngine(store, _ => [new ToneInput()]);
        var model = new RecorderViewModel(engine, store, dispatcher) { ConfirmDiscard = () => true };
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var release = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        model.BeforeDiscard = () => { entered.TrySetResult(); return release.Task; };
        await engine.StartAsync(new("Confirmed original", true, false));
        await Task.Delay(250);
        var original = engine.Snapshot.Recording!;
        try
        {
            model.Discard.Execute(null);
            await entered.Task.WaitAsync(TimeSpan.FromSeconds(3));
            if (model.Stop.CanExecute(null) || model.ToggleMicrophone.CanExecute(null) || model.OpenFolder.CanExecute(null))
                throw new Exception("A pending discard allowed another recorder command to clear its busy state.");
            await engine.StopAsync();
            await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            if (model.NewRecording.CanExecute(null)) throw new Exception("A pending discard allowed setup to reset.");
            var originalBytes = await File.ReadAllBytesAsync(original.AudioPath);
            if (replace)
            {
                await engine.StartAsync(new("Replacement recording", true, false));
                await Task.Delay(250);
            }
            var replacement = engine.Snapshot.Recording!;
            release.TrySetResult();
            await WaitAsync(() => model.Discard.CanExecute(null) || model.CanConfigure);
            var expectedState = replace ? RecordingState.Recording : RecordingState.Done;
            if (engine.Snapshot.State != expectedState || engine.Snapshot.Recording?.Id != replacement.Id || !File.Exists(replacement.AudioPath))
                throw new Exception("Discarding the original session stopped or deleted a changed recording.");
            var afterBytes = await File.ReadAllBytesAsync(original.AudioPath);
            if (!originalBytes.SequenceEqual(afterBytes)) throw new Exception("A stale discard changed the original saved audio.");
        }
        finally { release.TrySetResult(); await engine.StopAsync(); }
        Console.WriteLine(replace ? "PASS delayed discard cannot stop or delete a replacement recording." : "PASS delayed discard preserves an already saved original recording.");
    }

    private static async Task ReplacedDuringConfirmationAsync(string root, Dispatcher dispatcher)
    {
        var store = new LocalRecordingStore(Path.Combine(root, "discard-confirmation"));
        await using var engine = new RecordingEngine(store, _ => [new ToneInput()]);
        var model = new RecorderViewModel(engine, store, dispatcher);
        var cleanupCalls = 0;
        model.BeforeDiscard = () => { cleanupCalls++; return Task.CompletedTask; };
        await engine.StartAsync(new("Before confirmation", true, false));
        await Task.Delay(250);
        var original = engine.Snapshot.Recording!;
        Exception? nestedFailure = null;
        model.ConfirmDiscard = () =>
        {
            var frame = new DispatcherFrame();
            dispatcher.BeginInvoke(async () =>
            {
                try
                {
                    await engine.StopAsync();
                    await engine.StartAsync(new("During confirmation", true, false));
                    await Task.Delay(250);
                }
                catch (Exception error) { nestedFailure = error; }
                finally { frame.Continue = false; }
            });
            Dispatcher.PushFrame(frame);
            return true;
        };
        model.Discard.Execute(null);
        await WaitAsync(() => model.Discard.CanExecute(null) || model.CanConfigure);
        if (nestedFailure is not null) throw nestedFailure;
        if (cleanupCalls != 0 || engine.Snapshot.State != RecordingState.Recording || engine.Snapshot.Recording?.Id == original.Id || !File.Exists(original.AudioPath))
            throw new Exception("Stale confirmation invoked cleanup or discarded the changed recording.");
        await engine.StopAsync();
    }

    private static async Task CancelFailureAndSuccessAsync(string root, Dispatcher dispatcher)
    {
        var store = new LocalRecordingStore(Path.Combine(root, "discard-normal"));
        var unrelated = store.Create("Unrelated audio") with { State = RecordingState.Done };
        await File.WriteAllBytesAsync(unrelated.AudioPath, [7, 8, 9]);
        store.Save(unrelated);
        await using var engine = new RecordingEngine(store, _ => [new ToneInput()]);
        var model = new RecorderViewModel(engine, store, dispatcher);
        var saved = 0;
        var cleanupCalls = 0;
        model.Saved += _ => saved++;
        model.BeforeDiscard = () => { cleanupCalls++; return Task.CompletedTask; };
        await engine.StartAsync(new("Discard only this", true, false));
        await Task.Delay(250);
        var target = engine.Snapshot.Recording!;
        model.ConfirmDiscard = () => false;
        model.Discard.Execute(null);
        if (cleanupCalls != 0 || engine.Snapshot.State != RecordingState.Recording || !File.Exists(target.AudioPath))
            throw new Exception("Cancelled confirmation changed the recording.");

        model.ConfirmDiscard = () => true;
        model.BeforeDiscard = () => throw new IOException("Controlled cleanup failure");
        model.Discard.Execute(null);
        if (model.Error is null || engine.Snapshot.State != RecordingState.Recording || !File.Exists(target.AudioPath) || !model.Discard.CanExecute(null))
            throw new Exception("Failed caption cleanup lost audio or prevented retry.");

        model.BeforeDiscard = () => { cleanupCalls++; return Task.CompletedTask; };
        model.Discard.Execute(null);
        await WaitAsync(() => model.CanConfigure);
        if (engine.Snapshot.State != RecordingState.Idle || Directory.Exists(target.Directory) || saved != 0 || cleanupCalls != 1)
            throw new Exception("Successful discard retained the target or published it as saved.");
        var unrelatedBytes = await File.ReadAllBytesAsync(unrelated.AudioPath);
        if (!unrelatedBytes.SequenceEqual(new byte[] { 7, 8, 9 }) || store.List().Single().Id != unrelated.Id)
            throw new Exception("Discard changed an unrelated recording.");
    }

    private static async Task WaitAsync(Func<bool> done)
    {
        var deadline = Environment.TickCount64 + 5000;
        while (!done() && Environment.TickCount64 < deadline) await Task.Delay(10);
        if (!done()) throw new TimeoutException("Discard operation did not settle.");
    }
    private sealed class ToneInput : IAudioInput
    {
        public string Input => "system";
        public Exception? Error => null;
        public void Start() { }
        public void Read(float[] destination) => Array.Fill(destination, .1f);
        public void Stop() { }
        public void Dispose() { }
    }
}
