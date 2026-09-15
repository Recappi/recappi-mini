using System.Diagnostics;
using Recappi.Core;

internal static class AudioActivationTests
{
    public static async Task RunAsync(string root)
    {
        var gate = new AudioActivationGate();
        var pending = NewCompletion();
        var normal = gate.RunAsync(() => pending.Task, null, value => value.Dispose());
        Check(gate.HasPendingActivation, "Unbounded CLI activation was not retained.");
        await ExpectAsync<InvalidOperationException>(() => gate.RunAsync(() => throw new Exception("Must not start another operation"), TimeSpan.FromMilliseconds(20), (Result value) => value.Dispose()));
        var owned = new Result(); pending.SetResult(owned);
        Check(ReferenceEquals(await normal, owned) && owned.Disposals == 0 && !gate.HasPendingActivation, "Successful activation lost ownership.");
        owned.Dispose();

        pending = NewCompletion();
        var timed = gate.RunAsync(() => pending.Task, TimeSpan.FromMilliseconds(20), value => value.Dispose());
        await ExpectAsync<TimeoutException>(() => timed);
        Check(gate.HasPendingActivation, "Timeout released an outstanding native activation too soon.");
        await ExpectAsync<InvalidOperationException>(() => gate.RunAsync(() => Task.FromResult(new Result()), null, value => value.Dispose()));
        var late = new Result(); pending.SetResult(late);
        await UntilAsync(() => !gate.HasPendingActivation);
        Check(late.Disposals == 1, "A late activation result was leaked or disposed twice.");
        var retry = new Result();
        Check(ReferenceEquals(await gate.RunAsync(() => Task.FromResult(retry), TimeSpan.FromSeconds(1), value => value.Dispose()), retry) && retry.Disposals == 0,
            "Late result contaminated retry or successful retry was disposed.");
        retry.Dispose();

        pending = NewCompletion();
        await ExpectAsync<TimeoutException>(() => gate.RunAsync(() => pending.Task, TimeSpan.FromMilliseconds(20), value => value.Dispose()));
        pending.SetException(new IOException("Late device rejection"));
        await UntilAsync(() => !gate.HasPendingActivation);
        await ExpectAsync<IOException>(() => gate.RunAsync(() => Task.FromException<Result>(new IOException("Immediate rejection")), null, value => value.Dispose()));
        await ExpectAsync<IOException>(() => gate.RunAsync<Result>(() => throw new IOException("Synchronous rejection"), null, value => value.Dispose()));
        Check(!gate.HasPendingActivation, "Rejected activation retained the slot.");
        var started = false;
        await ExpectAsync<ArgumentOutOfRangeException>(() => gate.RunAsync(() => { started = true; return Task.FromResult(new Result()); }, TimeSpan.Zero, value => value.Dispose()));
        Check(!started && !gate.HasPendingActivation, "Invalid timeout started an unowned activation.");

        await EngineRecoversAsync(root);
    }

    private static async Task EngineRecoversAsync(string root)
    {
        var store = new LocalRecordingStore(Path.Combine(root, "activation-timeout"));
        var gate = new AudioActivationGate();
        var pending = NewCompletion();
        var stall = true;
        await using var engine = new RecordingEngine(store, _ => [new ActivationInput(() =>
            stall ? gate.RunAsync(() => pending.Task, TimeSpan.FromMilliseconds(30), value => value.Dispose()).GetAwaiter().GetResult() : new Result())]);
        await ExpectAsync<TimeoutException>(() => engine.StartAsync(new("Timed out source", true, false)));
        var failed = engine.Snapshot.Recording!;
        Check(engine.Snapshot.State == RecordingState.Error && store.List().Single().Error is not null, "Activation timeout did not persist a recoverable failure.");
        Check((await engine.StopAsync().WaitAsync(TimeSpan.FromSeconds(2)))?.Id == failed.Id, "Stop remained blocked after activation timeout.");
        stall = false;
        await engine.StartAsync(new("Explicit other source", true, false));
        await UntilAsync(() => engine.Snapshot.Recording!.DurationMs > 0);
        var saved = await engine.StopAsync();
        Check(saved?.State == RecordingState.Done && saved.Id != failed.Id && File.Exists(failed.AudioPath), "Another source could not record without losing failed-session evidence.");
        var late = new Result(); pending.SetResult(late);
        await UntilAsync(() => !gate.HasPendingActivation);
        Check(late.Disposals == 1 && engine.Snapshot.Recording?.Id == saved!.Id, "Late activation changed the next recording.");
    }

    private static TaskCompletionSource<Result> NewCompletion() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static async Task ExpectAsync<T>(Func<Task> action) where T : Exception
    {
        var task = action();
        if (await Task.WhenAny(task, Task.Delay(2000)) != task) throw new Exception($"Expected {typeof(T).Name} did not settle.");
        try { await task; } catch (T) { return; }
        throw new Exception($"Expected {typeof(T).Name}.");
    }
    private static async Task UntilAsync(Func<bool> condition)
    {
        var clock = Stopwatch.StartNew();
        while (!condition())
        {
            if (clock.Elapsed > TimeSpan.FromSeconds(3)) throw new TimeoutException("Activation cleanup did not settle.");
            await Task.Delay(10);
        }
    }
    private sealed class Result : IDisposable
    {
        public int Disposals;
        public void Dispose() => Interlocked.Increment(ref Disposals);
    }
    private sealed class ActivationInput(Func<Result> start) : IAudioInput
    {
        private Result? owned;
        public string Input => "system";
        public Exception? Error => null;
        public void Start() => owned = start();
        public void Read(float[] destination) => Array.Fill(destination, .1f);
        public void Stop() { }
        public void Dispose() => Interlocked.Exchange(ref owned, null)?.Dispose();
    }
}
