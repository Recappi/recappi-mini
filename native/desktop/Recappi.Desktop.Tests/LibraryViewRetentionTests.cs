using System.ComponentModel;
using System.IO;
using System.Runtime.CompilerServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Recappi.Core;
using Recappi.Desktop;

internal static class LibraryViewRetentionTests
{
    public static async Task RunAsync(string root, Dispatcher dispatcher, bool holdForDump = false)
    {
        var account = new AccountSession(new AccountStore(Path.Combine(root, "view-retention-account")));
        var (cachedView, references) = await OpenCloseAsync(root, account, dispatcher);
        // Deliberately retain the same object WPF's ViewManager may cache.
        // A grouping callback must not turn this into ownership of a closed window.
        for (var attempt = 0; attempt < 12; attempt++)
        {
            await dispatcher.InvokeAsync(() => { }, DispatcherPriority.ApplicationIdle);
            await Task.Run(() => { GC.Collect(); GC.WaitForPendingFinalizers(); GC.Collect(); });
            await Task.Delay(50);
        }
        var retained = references.Count(reference => reference.IsAlive);
        GC.KeepAlive(cachedView);
        GC.KeepAlive(account);
        if (retained != 0)
        {
            if (holdForDump)
            {
                Console.WriteLine($"Cached view retention diagnostic PID {Environment.ProcessId}; waiting 60 seconds for dump.");
                await Task.Delay(TimeSpan.FromSeconds(60));
                GC.KeepAlive(cachedView); GC.KeepAlive(account);
            }
            throw new Exception($"A cached date-grouped view retained {retained} closed library objects.");
        }
        Console.WriteLine("PASS cached date-grouped view does not retain closed library, local view or player.");
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    private static async Task<(ICollectionView, WeakReference[])> OpenCloseAsync(string root, AccountSession account, Dispatcher dispatcher)
    {
        var store = new LocalRecordingStore(Path.Combine(root, "view-retention-recordings"));
        var recording = store.Create("Cached grouping fixture") with { State = RecordingState.Done };
        store.Save(recording);
        LocalLibraryView? local = new(store, account);
        CloudLibraryWindow? window = new(account, localLibrary: local,
            contentCache: new(Path.Combine(root, "view-retention-cache"))) { ShowActivated = false };
        try
        {
            // Keep this default regression independent of external accessibility
            // clients retaining COM automation peers for presented windows. The
            // opt-in lifetime profile separately shows/plays/closes real windows.
            await dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
            var view = (ICollectionView)((ListBox)window.FindName("Recordings")).ItemsSource;
            var references = new[] { new WeakReference(window), new WeakReference(local), new WeakReference(window.FindName("Player")) };
            window.Close();
            return (view, references);
        }
        finally
        {
            if (window.IsVisible) window.Close();
            window = null; local = null;
        }
    }
}
