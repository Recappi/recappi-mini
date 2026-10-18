using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Recappi.Core;

namespace Recappi.WinUI;

internal sealed class StartupProbe(string path)
{
    private readonly long started = Stopwatch.GetTimestamp();
    private readonly TaskCompletionSource<double> firstFrame = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public bool ExitAfterReady => Environment.GetEnvironmentVariable("RECAPPI_DESKTOP_STARTUP_EXIT") == "1";
    public static StartupProbe? Create() => Environment.GetEnvironmentVariable("RECAPPI_DESKTOP_STARTUP_REPORT") is { } path && Path.IsPathFullyQualified(path) ? new(path) : null;
    public void Observe(DesktopWindow window)
    {
        EventHandler<object>? rendered = null;
        rendered = (_, _) =>
        {
            if (!window.IsUserVisible) return;
            CompositionTarget.Rendering -= rendered;
            firstFrame.TrySetResult(Stopwatch.GetElapsedTime(started).TotalMilliseconds);
        };
        CompositionTarget.Rendering += rendered;
    }
    public async Task Complete(AccountSession account, RecorderWindow window)
    {
        var frame = await firstFrame.Task.WaitAsync(TimeSpan.FromSeconds(20));
        var report = new { processId = Environment.ProcessId, ready = true, firstFrameAfterStartupMs = frame,
            readyAfterStartupMs = Stopwatch.GetElapsedTime(started).TotalMilliseconds,
            accountState = account.Snapshot.State.ToString(), recordingState = window.State.ToString(),
            canStart = window.CanStart, sourceCount = window.SourceCount, microphoneCount = window.MicrophoneCount,
            uiFramework = "WinUI3", framework = RuntimeInformation.FrameworkDescription, architecture = RuntimeInformation.ProcessArchitecture.ToString() };
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        await using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.Read);
        await JsonSerializer.SerializeAsync(file, report);
    }
}
