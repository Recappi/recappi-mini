using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Documents;

namespace Recappi.WinUI;

// Render the service's plain text / lightweight Markdown with native selectable text,
// laid out like the macOS summary: a hero card, then one card of labeled sections.
// No HTML interpreter or external navigation is involved.
internal sealed class SummaryDocument : UserControl
{
    private static readonly string[] KnownHeadings = ["要点", "话题", "决策", "行动项", "引用", "时间线"];
    private readonly StackPanel cards = new() { Spacing = 14 };
    private string text = "";
    public string Text
    {
        get => text;
        set { if (text == value) return; text = value; Render(); }
    }
    public SummaryDocument()
    {
        Content = cards;
        MaxWidth = 760; HorizontalAlignment = HorizontalAlignment.Stretch;
        Margin = new Thickness(0, 4, 0, 72);
    }
    private void Render()
    {
        cards.Children.Clear();
        var intro = new List<string>();
        var sections = new List<(string Title, List<string> Items)>();
        foreach (var source in text.Replace("\r\n", "\n").Split('\n'))
        {
            var line = source.TrimEnd();
            if (line.Length == 0) continue;
            if (line.StartsWith("#", StringComparison.Ordinal) || KnownHeadings.Contains(line)) { sections.Add((line.TrimStart('#', ' '), [])); continue; }
            var body = line.StartsWith("- ", StringComparison.Ordinal) || line.StartsWith("* ", StringComparison.Ordinal) || line.StartsWith("• ", StringComparison.Ordinal) ? line[2..].TrimStart() : line;
            if (sections.Count == 0) intro.Add(body); else sections[^1].Items.Add(body);
        }
        if (intro.Count > 0)
        {
            var hero = new StackPanel { Spacing = 14 };
            hero.Children.Add(Eyebrow("摘要"));
            foreach (var paragraph in intro) hero.Children.Add(Body(paragraph));
            cards.Children.Add(Card(hero));
        }
        if (sections.Count == 0) return;
        var grouped = new StackPanel { Spacing = 18 };
        foreach (var (title, items) in sections)
        {
            if (grouped.Children.Count > 0)
            {
                var divider = new Border { Height = 1 };
                RecappiTheme.Bind(divider, "RecappiBorderHairline", brush => divider.Background = brush);
                grouped.Children.Add(divider);
            }
            var section = new StackPanel { Spacing = 10 };
            section.Children.Add(Eyebrow(title));
            var actions = title.Contains("行动"); var quotes = title.Contains("引用");
            foreach (var item in items) section.Children.Add(Item(item, actions ? "✓" : quotes ? "“" : "", actions));
            grouped.Children.Add(section);
        }
        cards.Children.Add(Card(grouped));
    }
    private static Border Card(UIElement child)
    {
        var card = new Border { Child = child, Padding = new Thickness(24), CornerRadius = new CornerRadius(14), BorderThickness = new Thickness(1) };
        RecappiTheme.Bind(card, "RecappiCardSubtleActive", brush => card.Background = brush);
        RecappiTheme.Bind(card, "RecappiBorderHairline", brush => card.BorderBrush = brush);
        return card;
    }
    private static TextBlock Eyebrow(string value) => new()
    {
        Text = value, FontSize = 10.5, FontWeight = FontWeights.SemiBold, CharacterSpacing = 60, Style = RecappiTheme.Style("RecappiCaption"), IsTextSelectionEnabled = false
    };
    private static TextBlock Body(string value)
    {
        var block = new TextBlock { Style = RecappiTheme.Style("RecappiBody"), FontSize = 13, LineHeight = 21, IsTextSelectionEnabled = true };
        AddInlines(block, value);
        return block;
    }
    private static UIElement Item(string value, string marker, bool owner)
    {
        var row = new Grid { ColumnSpacing = 8 };
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(20) }); row.ColumnDefinitions.Add(new ColumnDefinition());
        if (marker.Length > 0)
        {
            var glyph = new TextBlock { Text = marker, FontSize = marker == "“" ? 18 : 12, FontWeight = FontWeights.Bold, Style = RecappiTheme.Style("RecappiStatusAccent"), Opacity = marker == "“" ? 0.5 : 0.75, VerticalAlignment = VerticalAlignment.Top };
            row.Children.Add(glyph);
        }
        var content = new StackPanel { Spacing = 3 };
        var split = owner ? value.IndexOf('：') : -1;
        if (split > 0 && split <= 12)
        {
            content.Children.Add(new TextBlock { Text = value[..split], FontSize = 10.5, FontWeight = FontWeights.SemiBold, CharacterSpacing = 40, Style = RecappiTheme.Style("RecappiStatusAccent") });
            value = value[(split + 1)..];
        }
        content.Children.Add(Body(value));
        Grid.SetColumn(content, 1); row.Children.Add(content);
        return row;
    }
    private static void AddInlines(TextBlock block, string body)
    {
        var position = 0;
        while (position < body.Length)
        {
            var open = body.IndexOf("**", position, StringComparison.Ordinal);
            var close = open < 0 ? -1 : body.IndexOf("**", open + 2, StringComparison.Ordinal);
            if (open < 0 || close < 0) { block.Inlines.Add(new Run { Text = body[position..] }); break; }
            if (open > position) block.Inlines.Add(new Run { Text = body[position..open] });
            var bold = new Bold(); bold.Inlines.Add(new Run { Text = body[(open + 2)..close] }); block.Inlines.Add(bold);
            position = close + 2;
        }
    }
}
