namespace Recappi.Core;

public static class CaptionText
{
    public static string Format(string text, bool failed) => !failed ? text
        : string.IsNullOrWhiteSpace(text) ? L.T("［此段字幕未能识别］", "[Caption not recognized]") : text + L.T("［字幕未完成］", " [caption incomplete]");
}
