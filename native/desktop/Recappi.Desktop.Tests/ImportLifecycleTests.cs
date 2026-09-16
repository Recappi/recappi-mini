using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Recappi.Core;
using Recappi.Desktop;

internal static class ImportLifecycleTests
{
    public static async Task RunAsync(string root, Dispatcher dispatcher)
    {
        var directory = Path.Combine(root, "import-lifecycle");
        Directory.CreateDirectory(directory);
        var source = Path.Combine(directory, "source.wav");
        using (var writer = new PcmWaveWriter(source)) writer.Append(new float[48000]);
        var sourceHash = SHA256.HashData(File.ReadAllBytes(source));
        var store = new LocalRecordingStore(Path.Combine(directory, "Recordings"));
        var accountStore = new AccountStore(Path.Combine(directory, "Account"));
        accountStore.Save(new("https://example.test", "import-user", null, "test-token"));
        var session = new AccountSession(accountStore, (origin, token) => new CloudClient(origin, token, new Handler()));
        await session.RestoreAsync();
        var worker = new TaskCompletionSource<LocalRecording>(TaskCreationOptions.RunContinuationsAsynchronously);
        IProgress<double>? progress = null;
        var imports = 0;
        var actualImport = false;
        var local = new LocalLibraryView(store, session, importAudio: async (path, report, cancellation) =>
        {
            imports++; progress = report;
            if (actualImport) return await new AudioImport(store).ImportAsync(path, progress: report, cancellation: cancellation);
            var currentWorker = worker;
            using var registration = cancellation.Register(() => currentWorker.TrySetCanceled(cancellation));
            return await currentWorker.Task;
        });
        var window = new CloudLibraryWindow(session, localLibrary: local, contentCache: new(Path.Combine(directory, "Cache"))) { ShowActivated = false };
        try
        {
            window.Show();
            var list = (ListBox)window.FindName("Recordings");
            for (var n = 0; n < 100 && list.Items.Count == 0; n++) await Task.Delay(20);
            if (list.Items.Count != 1) throw new Exception("Import fixture cloud row did not load.");
            var importButton = (Button)window.FindName("ImportLocalButton");
            var cancelButton = (Button)window.FindName("CancelLocalImportButton");
            var status = (TextBlock)window.FindName("ImportLocalStatus");
            var dialogs = 0;
            local.ShowImportDialog = _ =>
            {
                dialogs++;
                if (importButton.IsEnabled || local.CanImport) throw new Exception("File chooser did not disable import.");
                if (!local.PickImportFileAsync().IsCompletedSuccessfully) throw new Exception("Nested file chooser was not rejected.");
                return false;
            };
            await local.PickImportFileAsync();
            if (dialogs != 1 || !importButton.IsEnabled) throw new Exception("Canceled file chooser did not restore import.");

            var importing = local.ImportFileAsync(source);
            list.SelectedIndex = 0;
            progress!.Report(.25);
            await dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
            if (!((FrameworkElement)window.FindName("CloudDetail")).IsVisible || ((FrameworkElement)window.FindName("LocalDetail")).IsVisible ||
                importButton.IsEnabled || !cancelButton.IsVisible || !status.IsVisible || !status.Text.Contains("25"))
                throw new Exception("Cloud detail hid import progress/cancellation or allowed another import.");
            var cancelTop = cancelButton.TranslatePoint(new Point(), window).Y;
            if (cancelTop < 0 || cancelTop + cancelButton.ActualHeight > window.ActualHeight) throw new Exception("Import cancellation is outside the window.");
            await local.PickImportFileAsync();
            await local.ImportFileAsync(source);
            if (dialogs != 1 || imports != 1) throw new Exception("Import allowed duplicate chooser/worker.");
            cancelButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            await importing.WaitAsync(TimeSpan.FromSeconds(5));
            if (!importButton.IsEnabled || cancelButton.IsVisible || !status.Text.Contains("已取消") || store.List().Count != 0)
                throw new Exception("Cancel did not restore the sidebar and preserve the empty library.");

            worker = new(TaskCreationOptions.RunContinuationsAsynchronously);
            importing = local.ImportFileAsync(source);
            var staleProgress = progress;
            worker.SetException(new InvalidDataException("Fixture decoder failed."));
            await importing;
            staleProgress!.Report(.9);
            await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            if (!importButton.IsEnabled || cancelButton.IsVisible || !status.Text.Contains("导入失败"))
                throw new Exception("Failure or delayed progress left the sidebar in a stale state.");

            actualImport = true;
            await local.ImportFileAsync(source);
            await dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
            if (!importButton.IsEnabled || cancelButton.IsVisible || !status.Text.Contains("已加入本机录音库") ||
                list.SelectedItem is not LibraryRecording { Local.State: RecordingState.Done } || store.List().Count != 1)
                throw new Exception("Successful real decode did not select the imported local recording and restore import.");
            if (!sourceHash.SequenceEqual(SHA256.HashData(File.ReadAllBytes(source)))) throw new Exception("Import changed the source file.");

            actualImport = false; worker = new(TaskCreationOptions.RunContinuationsAsynchronously);
            importing = local.ImportFileAsync(source);
            window.Close();
            await importing.WaitAsync(TimeSpan.FromSeconds(5));
            if (local.CanImport) throw new Exception("Closed library still accepts imports.");
        }
        finally { window.Close(); }
        Console.WriteLine("PASS native import sidebar survives cloud selection, rejects duplicates, cancels/recovers, ignores stale progress and selects actual decoded audio.");
    }

    private sealed class Handler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            var path = request.RequestUri!.AbsolutePath;
            var body = path.EndsWith("get-session") ? """{"user":{"id":"import-user"},"session":{}}"""
                : path == "/api/recordings" ? """{"items":[{"id":"cloud-import","title":"Cloud selection during import","status":"ready"}],"nextCursor":null}"""
                : path.EndsWith("/transcript") ? """{"segments":[],"summary":"Fixture summary"}""" : """{"items":[]}""";
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") });
        }
    }
}
