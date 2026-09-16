using System.Windows;

namespace Recappi.Desktop;

public partial class DiscardRecordingDialog : Window
{
    public DiscardRecordingDialog()
    {
        DesktopTheme.EnsureResources();
        InitializeComponent();
        WindowVisibility.SetEnabled(this, true);
        Loaded += (_, _) => KeepButton.Focus();
    }

    private void Discard(object sender, RoutedEventArgs e) => DialogResult = true;
}
