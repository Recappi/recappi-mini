using System;
using System.Threading.Tasks;
using System.Windows;
using Recappi.Core;

namespace Recappi.Desktop;

// Standalone host retained for library tests and callers; the application can
// host the same view in its shared library without creating another window.
public sealed class LibraryWindow : Window
{
    private readonly LocalLibraryView view;
    public LibraryWindow(LocalRecordingStore store, AccountSession? accountSession = null, CloudProcessing? processing = null, Action? showAccount = null, Func<Task>? waitForCaptions = null)
    {
        Title = "Recappi Mini · 录音库"; Width = 840; Height = 560; MinWidth = 620; MinHeight = 420;
        view = new(store, accountSession, processing, showAccount, waitForCaptions); Content = view;
        Closed += (_, _) => view.Dispose();
    }
    public new object FindName(string name) => view.FindName(name);
    public void RefreshRecordings(string? selectedRecordingId = null) => view.RefreshRecordings(selectedRecordingId);
    public Task ImportFileAsync(string path) => view.ImportFileAsync(path);
}
