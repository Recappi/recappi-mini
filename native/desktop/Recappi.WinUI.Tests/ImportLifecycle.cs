using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Recappi.Core;

namespace Recappi.WinUI.Tests;

public partial class TestApp
{
    private static async Task ImportLifecycle(string root)
    {
        await using var host = new TestHost(Path.Combine(root, "import-lifecycle"));
        var source = Path.Combine(host.ApplicationRoot, "source.wav");
        using (var writer = new PcmWaveWriter(source)) writer.Append(new float[48000]);
        var chooser = new TaskCompletionSource<string?>();
        var worker = new TaskCompletionSource<LocalRecording>();
        IProgress<double>? progress = null;
        var pickCount = 0;
        var importCount = 0;
        var decode = false;
        var window = new LibraryWindow(host, () => { pickCount++; return chooser.Task; }, async (path, report, cancellation) =>
        {
            importCount++; progress = report;
            if (decode) return await new AudioImport(host.Store).ImportAsync(path, progress: report, cancellation: cancellation);
            var current = worker;
            using var registration = cancellation.Register(() => current.TrySetCanceled(cancellation));
            return await current.Task;
        });
        var windowClosed = false;
        window.Show();
        try
        {
            var status = Field<TextBlock>(window, "importStatus");
            var cancel = Field<Button>(window, "cancelImport");
            var choosing = window.Run(() => Call(window, "Import"));
            await Call(window, "Import");
            Check(pickCount == 1 && importCount == 0, "A second import opened another chooser.");
            chooser.SetResult(null); await choosing;
            Check(cancel.Visibility == Visibility.Collapsed, "Canceled file selection left import active.");

            chooser = new(); chooser.SetResult(source);
            var importing = window.Run(() => Call(window, "Import"));
            await Until(() => progress is not null, "Import did not start.");
            var canceledProgress = progress!;
            canceledProgress.Report(.25);
            await Until(() => status.Text.Contains("25"), "Import progress was not shown.");
            await Call(window, "Import");
            Check(pickCount == 2 && importCount == 1, "An active import allowed duplicate work.");
            Click(cancel); await importing;
            Check(status.Text.Contains("已取消") && cancel.Visibility == Visibility.Collapsed, "Import cancellation did not restore controls.");
            var error = (TextBlock)typeof(DesktopWindow).GetProperty("Error", System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic)!.GetValue(window)!;
            Check(error.Visibility == Visibility.Collapsed, "Expected import cancellation showed a duplicate window-level error.");
            var canceledStatus = status.Text;
            canceledProgress.Report(.9); await Task.Delay(100);
            Check(status.Text == canceledStatus, "Late progress replaced the canceled import status.");

            worker = new(); progress = null;
            importing = window.Run(() => Call(window, "Import"));
            await Until(() => progress is not null, "Import did not restart after cancellation.");
            var failedProgress = progress!;
            worker.SetException(new System.Runtime.InteropServices.COMException("Unsupported test audio", unchecked((int)0xC00D36C4)));
            await importing;
            var failedStatus = status.Text;
            failedProgress.Report(.8); await Task.Delay(100);
            Check(status.Text == failedStatus && cancel.Visibility == Visibility.Collapsed, "Late progress replaced a failed import status.");

            decode = true;
            await window.Run(() => Call(window, "Import"));
            Check(host.Store.List().Count == 1 && Field<ListView>(window, "list").SelectedItem is LibraryRecording { Local.State: RecordingState.Done },
                "Successful decode after failure did not select the imported recording.");
            var completedStatus = status.Text;
            failedProgress.Report(.7); progress!.Report(.6); await Task.Delay(100);
            Check(status.Text == completedStatus && status.Text.Contains("完成"), "Late progress replaced import completion.");

            decode = false; worker = new(); progress = null;
            importing = window.Run(() => Call(window, "Import"));
            await Until(() => progress is not null, "Close-during-import did not start.");
            window.Close(); windowClosed = true;
            await importing.WaitAsync(TimeSpan.FromSeconds(5));
            var picksBeforeClose = pickCount;
            await Call(window, "Import");
            Check(pickCount == picksBeforeClose, "Closed library accepted another import.");
        }
        finally { if (!windowClosed) window.Close(); }
    }
}
