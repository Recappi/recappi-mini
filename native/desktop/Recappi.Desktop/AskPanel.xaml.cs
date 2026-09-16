using System;
using System.Collections.ObjectModel;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Recappi.Core;

namespace Recappi.Desktop;

public partial class AskPanel : UserControl
{
    private AccountSession? accounts;
    private CloudAccount? account;
    private string? recordingId;
    private CancellationTokenSource? work;
    private int generation;
    private int draftRevision;
    private readonly ObservableCollection<AskCitation> citations = [];
    public event Action<AskCitation>? CitationSelected;
    public AskPanel() { InitializeComponent(); Citations.ItemsSource = citations; Question.TextChanged += (_, _) => draftRevision++; }

    public async Task SelectAsync(AccountSession session, CloudAccount? selectedAccount, string? id)
    {
        Clear(); accounts = session; account = selectedAccount; recordingId = id;
        if (account is not null && id is not null) await LoadHistoryAsync();
    }
    public void Clear()
    {
        generation++; work?.Cancel(); work?.Dispose(); work = null;
        account = null; recordingId = null;
        Conversation.Clear(); Question.Clear(); citations.Clear(); Suggestions.ItemsSource = null; Status.Text = "";
        SetBusy(false);
    }
    private bool Current(int version) => version == generation && account is not null && accounts?.Snapshot.State == AccountState.SignedIn && accounts.Snapshot.Account?.Partition == account.Partition;
    private void SetBusy(bool busy)
    {
        SendButton.IsEnabled = !busy && recordingId is not null; HistoryButton.IsEnabled = SendButton.IsEnabled; CancelButton.IsEnabled = busy;
    }
    private CancellationToken Begin()
    {
        work?.Cancel(); work?.Dispose(); work = new(); SetBusy(true); return work.Token;
    }
    private async Task LoadHistoryAsync()
    {
        if (accounts is null || account is null || recordingId is null) return;
        var version = generation; var token = Begin(); Status.Text = "正在读取问答历史…";
        try
        {
            using var client = accounts.Client(account);
            var messages = await client.AskHistoryAsync(recordingId, token);
            if (!Current(version) || token.IsCancellationRequested) return;
            Conversation.Text = string.Join("\n\n", Array.ConvertAll(messages, x => (x.Role == "user" ? "你：\n" : "Recappi：\n") + x.Content + (x.Status is "failed" or "interrupted" ? "\n[回答未完成]" : "")));
            citations.Clear(); foreach (var message in messages) foreach (var citation in message.Citations ?? []) citations.Add(citation);
            Status.Text = messages.Length == 0 ? "可以开始提问。" : "已加载历史";
            try
            {
                var suggestions = await client.AskSuggestionsAsync(recordingId, token);
                if (Current(version) && !token.IsCancellationRequested) Suggestions.ItemsSource = suggestions;
            }
            catch (Exception) { /* Suggestions are optional; history remains usable. */ }
        }
        catch (OperationCanceledException) { if (Current(version)) Status.Text = "读取已停止。"; }
        catch (Exception) { if (Current(version)) Status.Text = "历史读取失败，可刷新重试。"; }
        finally { if (Current(version)) SetBusy(false); }
    }
    private async void RefreshHistory(object sender, RoutedEventArgs e) => await LoadHistoryAsync();
    private void Cancel(object sender, RoutedEventArgs e) => work?.Cancel();
    private void ChooseSuggestion(object sender, SelectionChangedEventArgs e) { if (Suggestions.SelectedItem is string text) Question.Text = text; }
    private void SelectCitation(object sender, SelectionChangedEventArgs e) { if (Citations.SelectedItem is AskCitation citation) CitationSelected?.Invoke(citation); }
    private async void Send(object sender, RoutedEventArgs e)
    {
        if (accounts is null || account is null || recordingId is null || string.IsNullOrWhiteSpace(Question.Text)) return;
        var originalDraft = Question.Text;
        var question = originalDraft.Trim(); var version = generation; var token = Begin();
        Question.Clear();
        var submittedRevision = draftRevision;
        var completed = false;
        var prefix = Conversation.Text + (Conversation.Text.Length == 0 ? "" : "\n\n") + "你：\n" + question + "\n\nRecappi：\n";
        var answer = new StringBuilder();
        Conversation.Text = prefix; Status.Text = "正在回答…";
        try
        {
            using var client = accounts.Client(account);
            await foreach (var update in client.AskAsync(recordingId, question, WebSearch.IsChecked == true, cancellation: token))
            {
                if (!Current(version) || token.IsCancellationRequested) return;
                if (update.Name == "answer_delta") answer.Append(update.Text);
                else if (update.Name == "done" && update.Text is not null) { answer.Clear(); answer.Append(update.Text); }
                foreach (var citation in update.Citations) if (!citations.Contains(citation)) citations.Add(citation);
                Conversation.Text = prefix + answer; Conversation.ScrollToEnd();
                if (update.Name == "done") { Status.Text = "回答完成"; completed = true; }
            }
        }
        catch (OperationCanceledException) { if (Current(version)) Status.Text = token.IsCancellationRequested ? "已停止，回答可能不完整。可刷新历史查看服务器保存结果。" : "连接超时，可刷新历史后重试。"; }
        catch (Exception) { if (Current(version)) Status.Text = "回答未完成。已收到的内容保留；请刷新历史确认后重试。"; }
        finally
        {
            if (Current(version))
            {
                if (!completed && draftRevision == submittedRevision && Question.Text.Length == 0) Question.Text = originalDraft;
                SetBusy(false);
            }
        }
    }
}
