using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows;
using Recappi.Core;

namespace Recappi.Desktop;

/// <summary>Explicit benchmark opt-in; normal launches do not write startup telemetry.</summary>
internal sealed class StartupProbe(string path)
{
    private readonly long started = Stopwatch.GetTimestamp();
    private readonly TaskCompletionSource<double> rendered = new(TaskCreationOptions.RunContinuationsAsynchronously);
    public bool ExitAfterReady => Environment.GetEnvironmentVariable("RECAPPI_DESKTOP_STARTUP_EXIT") == "1";
    public static StartupProbe? Create()
    {
        var path = Environment.GetEnvironmentVariable("RECAPPI_DESKTOP_STARTUP_REPORT");
        return !string.IsNullOrWhiteSpace(path) && Path.IsPathFullyQualified(path) ? new(path) : null;
    }
    public void Observe(Window window)
    {
        void FirstFrame(object? sender, EventArgs args)
        {
            window.ContentRendered -= FirstFrame;
            rendered.TrySetResult(Stopwatch.GetElapsedTime(started).TotalMilliseconds);
        }
        window.ContentRendered += FirstFrame;
    }
    public async Task CompleteAsync(AccountSession account, RecorderViewModel recorder)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            var firstFrameMs = await rendered.Task.WaitAsync(TimeSpan.FromSeconds(20));
            var report = new
            {
                processId = Environment.ProcessId,
                ready = true,
                firstFrameAfterStartupMs = firstFrameMs,
                readyAfterStartupMs = Stopwatch.GetElapsedTime(started).TotalMilliseconds,
                accountState = account.Snapshot.State.ToString(), recordingState = recorder.Engine.Snapshot.State.ToString(),
                canStart = recorder.Start.CanExecute(null), sourceCount = recorder.Sources.Count, microphoneCount = recorder.Microphones.Count,
                framework = RuntimeInformation.FrameworkDescription,
                architecture = RuntimeInformation.ProcessArchitecture.ToString()
            };
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.WriteAllText(temporary, JsonSerializer.Serialize(report));
            File.Move(temporary, path); // A previous run's report is never overwritten.
        }
        catch (Exception) { /* Diagnostics failure must not prevent local recording. The benchmark detects missing output. */ }
        finally { try { if (File.Exists(temporary)) File.Delete(temporary); } catch (Exception) { } }
    }
}
