// A timed-out Windows activation cannot be canceled or freed while its callback
// is pending. Retain one operation, observe it, and dispose any late result.
internal sealed class AudioActivationGate
{
    private readonly SemaphoreSlim slot = new(1, 1);
    internal bool HasPendingActivation => slot.CurrentCount == 0;

    public async Task<T> RunAsync<T>(Func<Task<T>> activate, TimeSpan? timeout, Action<T> disposeAbandoned)
    {
        if (timeout is { } limit && (limit <= TimeSpan.Zero || limit.TotalMilliseconds > uint.MaxValue - 1))
            throw new ArgumentOutOfRangeException(nameof(timeout));
        if (!await slot.WaitAsync(0).ConfigureAwait(false))
            throw new InvalidOperationException("Audio initialization is still pending. Wait for the device to recover or restart the application before retrying.");
        var deferred = false;
        try
        {
            var pending = activate();
            try
            {
                return timeout is { } deadline
                    ? await pending.WaitAsync(deadline).ConfigureAwait(false)
                    : await pending.ConfigureAwait(false);
            }
            catch (TimeoutException) when (timeout.HasValue)
            {
                deferred = true;
                _ = ReleaseLateAsync(pending, disposeAbandoned);
                throw new TimeoutException("Application audio initialization timed out. Local recording did not start; wait for the device to recover or select another source.");
            }
        }
        finally { if (!deferred) slot.Release(); }
    }

    private async Task ReleaseLateAsync<T>(Task<T> pending, Action<T> disposeAbandoned)
    {
        try { disposeAbandoned(await pending.ConfigureAwait(false)); }
        catch { /* Observe failed activation/cleanup; never surface an abandoned result to a later recording. */ }
        finally { slot.Release(); }
    }
}
