using System;
using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace Recappi.Desktop;

public partial class RecorderWindow : Window
{
    private readonly Action showLibrary;
    private readonly Action? showAccount;
    private readonly Action? showCaptions;
    private readonly Action? showSettings;
    private readonly Action showCloud;
    private readonly Action<string>? showRecording;
    private readonly Action? requestQuit;
    private readonly RecorderViewModel recorder;
    public RecorderWindow(RecorderViewModel recorder, Action showLibrary, Action? showAccount = null, Action? showCaptions = null, Action? showSettings = null, Action? showCloud = null, Action<string>? showRecording = null, Action? requestQuit = null)
    {
        DesktopTheme.EnsureResources();
        InitializeComponent(); DataContext = recorder; this.showLibrary = showLibrary; this.showAccount = showAccount; this.showCaptions = showCaptions; this.showSettings = showSettings;
        this.recorder = recorder; this.showCloud = showCloud ?? showLibrary; this.showRecording = showRecording;
        this.requestQuit = requestQuit;
        Func<bool> confirmDiscard = () => new DiscardRecordingDialog { Owner = this }.ShowDialog() == true;
        recorder.ConfirmDiscard = confirmDiscard;
        WindowVisibility.SetEnabled(this, true);
        recorder.PropertyChanged += RecorderChanged;
        Closed += (_, _) =>
        {
            recorder.PropertyChanged -= RecorderChanged;
            if (recorder.ConfirmDiscard == confirmDiscard) recorder.ConfirmDiscard = () => false;
        };
        IsVisibleChanged += (_, _) => { if (!IsVisible) OptionsPopup.IsOpen = false; };
        var positioned = false;
        Loaded += (_, _) => { if (!positioned) { positioned = true; WindowVisibility.PlaceTopRight(this, 24); } };
    }
    private void RecorderChanged(object? sender, PropertyChangedEventArgs e) { if (recorder.IsActive) OptionsPopup.IsOpen = false; }
    private void MovePanel(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState != MouseButtonState.Pressed) return;
        OptionsPopup.IsOpen = false;
        MoveHandle.Focus(); e.Handled = true;
        DragMove();
    }
    private void MovePanelKeyDown(object sender, KeyEventArgs e)
    {
        var step = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift) ? 1 : 10;
        switch (e.Key)
        {
            case Key.Left: Left -= step; break;
            case Key.Right: Left += step; break;
            case Key.Up: Top -= step; break;
            case Key.Down: Top += step; break;
            default: return;
        }
        e.Handled = true;
        WindowVisibility.EnsureVisible(this);
    }
    private void OptionsKeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Escape && OptionsPopup.IsOpen) { OptionsPopup.IsOpen = false; OptionsButton.Focus(); e.Handled = true; }
    }
    private void OptionsOpened(object? sender, EventArgs e)
    {
        OptionsScroll.ScrollToTop();
        Dispatcher.BeginInvoke(new Action(() => { if (OptionsPopup.IsOpen) RecordingTitle.Focus(); }),
            System.Windows.Threading.DispatcherPriority.Input);
    }
    private void HidePanel(object sender, RoutedEventArgs e) { OptionsPopup.IsOpen = false; Hide(); }
    private void OpenCloud(object sender, RoutedEventArgs e) => showCloud();
    private void OpenSavedRecording(object sender, RoutedEventArgs e)
    {
        if (recorder.SavedRecordingId is { } id && showRecording is not null) showRecording(id);
        else showLibrary();
    }
    private void ShowMore(object sender, RoutedEventArgs e)
    {
        if (sender is Button { ContextMenu: { } menu } button) { menu.PlacementTarget = button; menu.IsOpen = true; }
    }
    private void OpenLibrary(object sender, RoutedEventArgs e) { OptionsPopup.IsOpen = false; showLibrary(); }
    private void OpenAccount(object sender, RoutedEventArgs e) { OptionsPopup.IsOpen = false; showAccount?.Invoke(); }
    private void OpenCaptions(object sender, RoutedEventArgs e) => showCaptions?.Invoke();
    private void OpenSettings(object sender, RoutedEventArgs e) { OptionsPopup.IsOpen = false; showSettings?.Invoke(); }
    private void QuitApplication(object sender, RoutedEventArgs e) { OptionsPopup.IsOpen = false; requestQuit?.Invoke(); }
}
