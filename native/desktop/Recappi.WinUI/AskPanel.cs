using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml;
using Recappi.Core;

namespace Recappi.WinUI;

internal sealed class AskPanel : IDisposable
{
    public Grid Root { get; } = new() { RowSpacing = 8, Margin = new Thickness(4, 12, 16, 12), HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly StackPanel timeline = new() { Spacing = 16, Padding = new Thickness(0, 0, 0, 12) };
    private readonly ScrollViewer conversation = new() { HorizontalContentAlignment = HorizontalAlignment.Stretch, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    private bool revealPending;
    private bool revealResponse;
    private readonly LibraryWindow owner;
    private readonly IDesktopHost app;
    private readonly CloudAccount account;
    private readonly string id;
    private readonly Func<bool> current;
    private readonly Func<AskCitation, Task> seek;
    private readonly CancellationTokenSource lifetime = new();
    private CancellationTokenSource? sending;
    private readonly TextBox question = new() { PlaceholderText = "这段录音里，有什么想进一步了解的？", AcceptsReturn = true, MinHeight = 88, MaxHeight = 120, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock history = Ui.Text("");
    private readonly TextBlock answer = Ui.Text("");
    private readonly StackPanel suggestions = new() { Spacing = 6 };
    private readonly StackPanel citations = new() { Spacing = 6 };
    private readonly HashSet<AskCitation> renderedCitations = [];
    private readonly StackPanel historyCitations = new() { Spacing = 6 };
    private readonly TextBlock asked = Ui.Text("", 14);
    private readonly TextBlock progress = Ui.Text("", 12);
    private readonly Border askedBubble = new() { CornerRadius = new CornerRadius(12), Padding = new Thickness(12, 8, 12, 8), HorizontalAlignment = HorizontalAlignment.Right, MaxWidth = 560, Margin = new Thickness(40, 0, 0, 0) };
    private readonly TextBlock answerLabel = new() { Text = "回答", FontSize = 9.5, FontWeight = Microsoft.UI.Text.FontWeights.SemiBold, CharacterSpacing = 60 };
    private readonly Button send;
    private readonly Button stop;
    private int edits;
    private int loadVersion;
    private bool disposed;
    public AskPanel(LibraryWindow owner, IDesktopHost app, CloudAccount account, string id, Func<bool> current, Func<AskCitation, Task> seek)
    {
        this.owner = owner; this.app = app; this.account = account; this.id = id; this.current = current; this.seek = seek;
        Root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        conversation.Content = timeline; Root.Children.Add(conversation);
        Root.LayoutUpdated += RevealAnswer;
        Root.SizeChanged += ResizeComposer;
        var intro = new StackPanel { Spacing = 4 };
        intro.Children.Add(new TextBlock { Text = "从录音中找到答案", Style = RecappiTheme.Style("RecappiSectionTitle") });
        intro.Children.Add(new TextBlock { Text = "围绕这段录音提问，回答中的引用可以定位到原音频。", Style = RecappiTheme.Style("RecappiBodySecondary") });
        timeline.Children.Add(intro);
        foreach (var text in new[] { history, answer }) { text.Style = RecappiTheme.Style("RecappiBody"); text.FontSize = 13; text.LineHeight = 21; }
        answerLabel.Style = RecappiTheme.Style("RecappiStatusAccent"); answerLabel.FontSize = 9.5;
        timeline.Children.Add(history); timeline.Children.Add(historyCitations); timeline.Children.Add(suggestions);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(question, "向这场会议提问");
        send = Ui.Button("发送", Send, owner); stop = Ui.Button("停止", () => { sending?.Cancel(); return Task.CompletedTask; }, owner);
        send.Style = stop.Style = RecappiTheme.Style("RecappiSendButton");
        send.Content = RecappiTheme.Glyph("\uE74A", 13); stop.Content = RecappiTheme.Glyph("\uE71A", 11);
        ToolTipService.SetToolTip(send, "发送"); ToolTipService.SetToolTip(stop, "停止回答");
        question.MinHeight = 34; question.CornerRadius = new CornerRadius(9);
        var reload = Ui.IconButton("重新加载问答", "\uE72C", Load, owner);
        // Composer: question field with its actions stacked at the trailing edge.
        var composer = new Grid { ColumnSpacing = 8, Padding = new Thickness(0, 10, 0, 0) };
        composer.ColumnDefinitions.Add(new ColumnDefinition()); composer.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var composerActions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, VerticalAlignment = VerticalAlignment.Bottom };
        composerActions.Children.Add(reload); composerActions.Children.Add(stop); composerActions.Children.Add(send);
        composer.Children.Add(question); Grid.SetColumn(composerActions, 1); composer.Children.Add(composerActions);
        Grid.SetRow(composer, 1); Root.Children.Add(composer);
        asked.Style = RecappiTheme.Style("RecappiBody"); asked.FontSize = 13; asked.IsTextSelectionEnabled = true;
        askedBubble.Child = asked; RecappiTheme.Bind(askedBubble, "RecappiControlHover", brush => askedBubble.Background = brush);
        progress.Style = RecappiTheme.Style("RecappiCaption");
        var response = new StackPanel { Spacing = 8 }; response.Children.Add(answerLabel); response.Children.Add(answer);
        timeline.Children.Add(askedBubble); timeline.Children.Add(progress); timeline.Children.Add(response); timeline.Children.Add(citations);
        question.TextChanging += (_, _) => { edits++; Render(); }; Render();
    }
    private bool Current => !disposed && current();
    public Task Load() { var version = ++loadVersion; _ = LoadSuggestions(version); return LoadHistory(version); }
    private async Task LoadHistory(int version)
    {
        try
        {
            using var client = app.Account.Client(account); var messages = await client.AskHistoryAsync(id, lifetime.Token);
            if (!Current || version != loadVersion) return;
            history.Text = string.Join("\n\n", messages.Select(x => (x.Role == "user" ? "你：" : "回答：") + x.Content));
            historyCitations.Children.Clear();
            foreach (var citation in messages.SelectMany(x => x.Citations ?? [])) historyCitations.Children.Add(CitationButton(citation));
            Render();
        }
        catch (Exception error) when (error is not OperationCanceledException) { if (Current && version == loadVersion) { history.Text = "历史加载失败，请重新加载问答。"; Render(); } }
        catch (OperationCanceledException) { }
    }
    private async Task LoadSuggestions(int version)
    {
        try
        {
            using var client = app.Account.Client(account); var values = await client.AskSuggestionsAsync(id, lifetime.Token);
            if (!Current || version != loadVersion) return;
            suggestions.Children.Clear();
            foreach (var value in values)
            {
                var chip = Ui.Button(value, () => { question.Text = value; return Task.CompletedTask; }, owner);
                chip.Style = RecappiTheme.Style("RecappiFollowUpButton"); chip.HorizontalAlignment = HorizontalAlignment.Left;
                suggestions.Children.Add(chip);
            }
            Render();
        }
        catch (Exception) { /* Optional suggestions cannot block asking. */ }
    }
    private async Task Send()
    {
        if (sending is not null || !Current) return;
        var prompt = question.Text; if (string.IsNullOrWhiteSpace(prompt)) return;
        using var pending = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token); sending = pending;
        question.Text = ""; var draftVersion = edits; answer.Text = ""; citations.Children.Clear(); renderedCitations.Clear(); var completed = false;
        asked.Text = prompt; progress.Text = "正在回答…"; revealResponse = false; revealPending = true; Render();
        var firstAnswer = true;
        try
        {
            using var client = app.Account.Client(account);
            await foreach (var item in client.AskAsync(id, prompt, cancellation: pending.Token))
            {
                if (!Current) return;
                if (item.Name == "answer_delta") answer.Text += item.Text;
                if (item.Name == "done")
                {
                    if (item.Text is { } text) answer.Text = text;
                    completed = true;
                    // Citations can arrive after the first streamed text changed the scroll extent.
                    revealResponse = true; revealPending = true;
                }
                foreach (var citation in item.Citations) AddCitation(citation);
                if (firstAnswer && !string.IsNullOrEmpty(answer.Text)) { firstAnswer = false; revealResponse = true; revealPending = true; }
                Render();
            }
        }
        finally
        {
            sending = null;
            if (Current && !completed && edits == draftVersion) question.Text = prompt;
            if (Current) { progress.Text = completed ? "" : pending.IsCancellationRequested ? "已停止回答" : "回答未完成，可以重试。"; Render(); }
        }
    }
    private void ResizeComposer(object sender, SizeChangedEventArgs args)
    {
        // One to four lines, as in the macOS composer; shorter on small windows.
        if (args.NewSize.Height < 400) { question.MinHeight = 34; question.MaxHeight = 64; }
        else { question.MinHeight = 34; question.MaxHeight = 96; }
    }
    private void RevealAnswer(object? sender, object args)
    {
        var target = revealResponse ? answer : asked;
        if (!revealPending || !Current || conversation.ViewportHeight <= 0 || target.ActualHeight <= 0) return;
        revealPending = false;
        var position = target.TransformToVisual(timeline).TransformPoint(new Windows.Foundation.Point());
        conversation.ChangeView(null, Math.Min(position.Y, conversation.ScrollableHeight), null, true);
    }
    private void Render()
    {
        send.IsEnabled = Current && sending is null && !string.IsNullOrWhiteSpace(question.Text);
        stop.Visibility = sending is null ? Visibility.Collapsed : Visibility.Visible;
        foreach (var text in new[] { history, asked, progress, answer }) text.Visibility = string.IsNullOrEmpty(text.Text) ? Visibility.Collapsed : Visibility.Visible;
        askedBubble.Visibility = asked.Visibility;
        answerLabel.Visibility = answer.Visibility;
        foreach (var panel in new[] { historyCitations, suggestions, citations }) panel.Visibility = panel.Children.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
    }
    private Button CitationButton(AskCitation citation)
    {
        var button = Ui.Button(citation.Display, () => Current ? seek(citation) : Task.CompletedTask, owner);
        button.Style = RecappiTheme.Style("RecappiCitationButton"); button.HorizontalAlignment = HorizontalAlignment.Left;
        ToolTipService.SetToolTip(button, "定位到引用位置");
        return button;
    }
    private void AddCitation(AskCitation citation)
    {
        if (renderedCitations.Add(citation)) citations.Children.Add(CitationButton(citation));
    }
    public void Dispose() { if (disposed) return; disposed = true; Root.LayoutUpdated -= RevealAnswer; Root.SizeChanged -= ResizeComposer; lifetime.Cancel(); sending?.Cancel(); }
}
