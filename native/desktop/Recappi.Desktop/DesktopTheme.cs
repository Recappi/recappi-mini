using System;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;

namespace Recappi.Desktop;

public static class DesktopTheme
{
    private static string currentTheme = "system";
    private static bool resourcesLoaded;

    public static void EnsureResources()
    {
        if (resourcesLoaded) return;
        Application.Current.Resources.MergedDictionaries.Add(new ResourceDictionary
        {
            Source = new Uri("/Recappi Mini;component/ModernStyles.xaml", UriKind.Relative)
        });
        resourcesLoaded = true;
        UpdatePalette();
        SystemEvents.UserPreferenceChanged += (_, _) =>
        {
            var dispatcher = Application.Current?.Dispatcher;
            if (dispatcher is not null && !dispatcher.HasShutdownStarted)
                dispatcher.BeginInvoke(new Action(UpdatePalette));
        };
    }

    private static void UpdatePalette()
    {
        bool dark = currentTheme == "dark";
        if (currentTheme == "system")
        {
            using var personalization = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            dark = personalization?.GetValue("AppsUseLightTheme") is int value && value == 0;
        }
        Set("CanvasBrush", dark ? "#191C20" : "#F3F5F8", SystemColors.WindowColor);
        Set("SurfaceBrush", dark ? "#24282E" : "#FFFFFF", SystemColors.WindowColor);
        Set("InkBrush", dark ? "#F3F5F7" : "#202936", SystemColors.WindowTextColor);
        Set("StrokeBrush", dark ? "#3A414B" : "#DEE3EB", SystemColors.WindowTextColor);
        Set("HoverBrush", dark ? "#2C333D" : "#E9EDF4", SystemColors.HighlightColor);
        Set("SelectionBrush", dark ? "#263D56" : "#E1EDFC", SystemColors.WindowColor);
        Set("AccentBrush", dark ? "#83BCFF" : "#175CD3", SystemColors.HighlightColor);
        Set("AccentInkBrush", dark ? "#10243D" : "#FFFFFF", SystemColors.HighlightTextColor);
    }

    private static void Set(string key, string hex, Color accessible)
    {
        var brush = new SolidColorBrush(SystemParameters.HighContrast ? accessible : (Color)ColorConverter.ConvertFromString(hex));
        brush.Freeze();
        Application.Current.Resources[key] = brush;
    }

    public static void Apply(string theme)
    {
        if (theme is not ("light" or "dark" or "system")) throw new ArgumentException("请选择有效主题。");
        currentTheme = theme;
        EnsureResources();
        UpdatePalette();
        // WPF's built-in Fluent API is marked experimental in the pinned .NET 10
        // runtime. Keep the opt-in local, with native-control switching regression.
#pragma warning disable WPF0001
        Application.Current.ThemeMode = theme switch
        {
            "light" => ThemeMode.Light,
            "dark" => ThemeMode.Dark,
            "system" => ThemeMode.System,
            _ => throw new ArgumentException("请选择有效主题。")
        };
#pragma warning restore WPF0001
    }
}
