using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using Recappi.Core;
using Recappi.Desktop;

internal static class LocalDetailScrollingTests
{
    public static async Task RunAsync(string root, Dispatcher dispatcher)
    {
        var store = new LocalRecordingStore(Path.Combine(root, "wheel-recordings"));
        var recording = store.Create("Wheel navigation") with { State = RecordingState.Done };
        store.Save(recording);
        var account = new AccountSession(new AccountStore(Path.Combine(root, "wheel-account")));
        var local = new LocalLibraryView(store, account);
        var window = new CloudLibraryWindow(account, localLibrary: local,
            contentCache: new(Path.Combine(root, "wheel-cache")))
            { Width = 800, Height = 540, ShowActivated = false };
        try
        {
            window.RefreshLocalRecordings(recording.Id);
            window.Show();
            await dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
            var scroll = (ScrollViewer)window.FindName("DetailScroll");
            var heading = (TextBlock)local.FindName("Heading");
            if (scroll.ScrollableHeight <= 0) throw new Exception("Wheel regression requires overflowing actual local detail.");
            scroll.ScrollToTop();
            await dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
            Wheel(heading, -120);
            await dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
            if (scroll.VerticalOffset <= 0) throw new Exception("Local detail swallowed mouse wheel instead of scrolling the library.");
            var previous = scroll.VerticalOffset;
            Wheel(heading, 120);
            await dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
            if (scroll.VerticalOffset >= previous) throw new Exception("Local detail mouse wheel cannot return upward.");
        }
        finally { window.Close(); }

        using var standalone = new LocalLibraryView(store);
        var standaloneWindow = new Window { Content = standalone, Width = 640, Height = 320, ShowActivated = false };
        try
        {
            standalone.RefreshRecordings(recording.Id);
            standaloneWindow.Show();
            await dispatcher.InvokeAsync(standaloneWindow.UpdateLayout, DispatcherPriority.ApplicationIdle);
            var scroll = (ScrollViewer)standalone.FindName("LocalDetailScroll");
            if (scroll.ScrollableHeight <= 0) throw new Exception("Standalone wheel regression requires overflowing detail.");
            Wheel((TextBlock)standalone.FindName("Heading"), -120);
            await dispatcher.InvokeAsync(standaloneWindow.UpdateLayout, DispatcherPriority.ApplicationIdle);
            if (scroll.VerticalOffset <= 0) throw new Exception("Standalone local library lost its own wheel scrolling.");
        }
        finally { standaloneWindow.Close(); }
        Console.WriteLine("PASS minimum embedded local detail scrolls down/up and standalone library retains wheel scrolling.");
    }

    private static void Wheel(UIElement source, int delta) => source.RaiseEvent(
        new MouseWheelEventArgs(Mouse.PrimaryDevice, Environment.TickCount, delta)
        { RoutedEvent = Mouse.MouseWheelEvent, Source = source });
}
