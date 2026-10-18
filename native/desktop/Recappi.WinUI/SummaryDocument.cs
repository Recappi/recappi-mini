using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;

namespace Recappi.WinUI;

// Render the service's plain text / lightweight Markdown with native selectable text.
// No HTML interpreter or external navigation is involved.
internal sealed class SummaryDocument : UserControl
{
    private readonly RichTextBlock document = new() { FontSize = 14, LineHeight = 25, IsTextSelectionEnabled = true };
    private string text = "";
    public string Text
    {
        get => text;
        set { if (text == value) return; text = value; Render(); }
    }
    public SummaryDocument()
    {
        Content = document;
        RecappiTheme.Bind(this, "RecappiLabel", brush => document.Foreground = brush);
        MaxWidth = 760; HorizontalAlignment = HorizontalAlignment.Left;
        Margin = new Thickness(4, 20, 16, 20);
    }
    private void Render()
    {
        document.Blocks.Clear();
        foreach (var source in text.Replace("\r\n", "\n").Split('\n'))
        {
            var line = source.TrimEnd();
            if (line.Length == 0) continue;
            var heading = line.StartsWith("#", StringComparison.Ordinal) || line is "要点" or "话题" or "决策" or "行动项" or "引用" or "时间线";
            var body = heading ? line.TrimStart('#', ' ') : line;
            if (body.StartsWith("- ", StringComparison.Ordinal) || body.StartsWith("* ", StringComparison.Ordinal)) body = "• " + body[2..];
            var paragraph = new Paragraph { Margin = new Thickness(0, heading && document.Blocks.Count > 0 ? 18 : 0, 0, heading ? 8 : 12),
                FontSize = heading ? 16 : 14, FontWeight = heading ? FontWeights.SemiBold : FontWeights.Normal };
            var position = 0;
            while (position < body.Length)
            {
                var open = body.IndexOf("**", position, StringComparison.Ordinal);
                var close = open < 0 ? -1 : body.IndexOf("**", open + 2, StringComparison.Ordinal);
                if (open < 0 || close < 0) { paragraph.Inlines.Add(new Run { Text = body[position..] }); break; }
                if (open > position) paragraph.Inlines.Add(new Run { Text = body[position..open] });
                var bold = new Bold(); bold.Inlines.Add(new Run { Text = body[(open + 2)..close] }); paragraph.Inlines.Add(bold);
                position = close + 2;
            }
            document.Blocks.Add(paragraph);
        }
    }
}
