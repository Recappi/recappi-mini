using System.Globalization;

namespace Recappi.Core;

// Interface language. Every user-visible string is written as L.T("中文", "English") at the point
// of use. Chinese stays the default (tests and the CLI expect it); the desktop app calls
// UseSystemLanguage at startup: Chinese for zh-* Windows display languages, English otherwise.
// RECAPPI_UI_LANG=zh|en overrides the system language (screenshots, tests).
public static class L
{
    public static bool English { get; set; }

    public static string T(string zh, string en) => English ? en : zh;

    public static void UseSystemLanguage()
    {
        var forced = Environment.GetEnvironmentVariable("RECAPPI_UI_LANG");
        English = forced is "zh" or "en" ? forced == "en"
            : !CultureInfo.CurrentUICulture.TwoLetterISOLanguageName.Equals("zh", StringComparison.OrdinalIgnoreCase);
    }

    // Dates as the interface shows them.
    private static readonly CultureInfo Us = CultureInfo.GetCultureInfo("en-US");
    public static string MonthDay(DateTime value) => English ? value.ToString("MMM d", Us) : value.ToString("M月d日");
    public static string LongDate(DateTime value) => English ? value.ToString("MMM d, yyyy", Us) : value.ToString("yyyy年M月d日");
    public static string LongDateTime(DateTime value) => English ? value.ToString("MMM d, yyyy h:mm tt", Us) : value.ToString("yyyy年M月d日 HH:mm");
}
