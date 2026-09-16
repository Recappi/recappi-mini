namespace Recappi.Core;

public static class CaptionText
{
    public static string Format(string text, bool failed) => !failed ? text
        : string.IsNullOrWhiteSpace(text) ? "［此段字幕未能识别］" : text + "［字幕未完成］";
}
