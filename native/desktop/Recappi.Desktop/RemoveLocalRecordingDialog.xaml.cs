using System.Windows;

namespace Recappi.Desktop;

public partial class RemoveLocalRecordingDialog : Window
{
    public RemoveLocalRecordingDialog(string title)
    {
        DesktopTheme.EnsureResources();
        InitializeComponent();
        RecordingTitle.Text = title;
        WindowVisibility.SetEnabled(this, true);
        Loaded += (_, _) => KeepButton.Focus();
    }

    private void Remove(object sender, RoutedEventArgs e) => DialogResult = true;
}
