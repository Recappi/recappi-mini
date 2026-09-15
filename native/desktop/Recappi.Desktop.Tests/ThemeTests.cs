using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Recappi.Core;
using Recappi.Desktop;

internal static class ThemeTests
{
    public static async Task RunAsync(string root, Dispatcher dispatcher)
    {
        var store = new PreferencesStore(Path.Combine(root, "theme-settings"));
        var window = new SettingsWindow(new(), value => { store.Save(value); DesktopTheme.Apply(value.Theme); }, () => { }) { ShowActivated = false };
        window.Show();
        try
        {
            var theme = (ComboBox)window.FindName("Theme");
            var input = (TextBox)window.FindName("TranscriptionLanguage");
            theme.SelectedValue = "dark";
            await dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
            var dark = (input.Background as SolidColorBrush)?.Color;
            var darkText = (input.Foreground as SolidColorBrush)?.Color;
            theme.SelectedValue = "light";
            await dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
            var light = (input.Background as SolidColorBrush)?.Color;
            var lightText = (input.Foreground as SolidColorBrush)?.Color;
            var introduction = (TextBlock)window.FindName("Introduction");
            var reminder = (TextBox)window.FindName("LongReminderMinutes");
            if (introduction.FontWeight != FontWeights.Normal || reminder.ActualHeight > 48)
                throw new Exception("Tab selection leaked bold text into page content or input padding was applied twice.");
            if (dark is null || light is null || dark == light || darkText is null || lightText is null || darkText == lightText) throw new Exception("Native theme did not update actual input background and foreground.");
            if (store.Load().Theme != "light" || !((TextBlock)window.FindName("About")).Text.Contains(typeof(SettingsWindow).Assembly.GetName().Version!.ToString(3))) throw new Exception("Theme persistence or actual app version missing.");
        }
        finally { window.Close(); DesktopTheme.Apply("system"); }
        Console.WriteLine("PASS native dark/light input rendering, theme persistence and actual about version.");
    }
}
