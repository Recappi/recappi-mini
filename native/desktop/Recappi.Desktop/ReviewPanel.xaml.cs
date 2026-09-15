using System;
using System.Linq;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Recappi.Core;

namespace Recappi.Desktop;

public partial class ReviewPanel : UserControl
{
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(2) };
    private AccountSession? accounts;
    private CloudAccount? account;
    private string? recordingId;
    private string recordingStatus = "";
    private CloudJob[] jobs = [];
    private CancellationTokenSource? lifetime;
    private int generation;
    private bool busy;
    private bool rendering;
    private bool summaryPending;
    private bool historyLoaded;
    private bool hasTranscript;
    private DateTimeOffset pollUntil;
    public Func<string, bool>? Confirm { get; set; }
    public Func<ProcessingOptions> ProcessingOptions { get; set; } = () => new();
    public event Action<string?>? VersionSelected;
    public ReviewPanel() { InitializeComponent(); timer.Tick += async (_, _) => await RefreshAsync(); }
    public async Task SelectAsync(AccountSession session, CloudAccount? selectedAccount, CloudRecordingItem? recording)
    {
        Clear(); accounts = session; account = selectedAccount; recordingId = recording?.Id; recordingStatus = recording?.Status ?? "";
        if (account is null || recordingId is null) return;
        lifetime = new(); pollUntil = DateTimeOffset.UtcNow.AddMinutes(30); await RefreshAsync();
    }
    public void Clear()
    {
        generation++; timer.Stop(); lifetime?.Cancel(); lifetime?.Dispose(); lifetime = null;
        account = null; recordingId = null; jobs = []; summaryPending = false; busy = false; historyLoaded = false; hasTranscript = false;
        rendering = true; Jobs.ItemsSource = null; rendering = false; Status.Text = ""; RenderButtons();
    }
    private bool Current(int version) => generation == version && account is not null && accounts?.Snapshot.State == AccountState.SignedIn && accounts.Snapshot.Account?.Partition == account.Partition;
    private void RenderButtons()
    {
        var available = recordingId is not null && !busy;
        LatestButton.IsEnabled = RefreshButton.IsEnabled = available;
        TranscribeButton.IsEnabled = available && historyLoaded && recordingStatus is not ("uploading" or "aborted") && !jobs.Any(x => x.IsActive);
        SummaryButton.IsEnabled = available && hasTranscript && !summaryPending && !jobs.Any(x => x.IsActive);
        RetryButton.IsEnabled = available && Jobs.SelectedItem is CloudJob { Status: "failed", HasRetryableChunks: true };
    }
    private async Task RefreshAsync()
    {
        if (busy || accounts is null || account is null || recordingId is null || lifetime is null) return;
        busy = true; RenderButtons(); var version = generation;
        try { using var client = accounts.Client(account); await FetchJobsAsync(client, version, lifetime.Token); }
        catch (OperationCanceledException) { }
        catch (Exception) { if (Current(version)) { Status.Text = "任务历史加载失败，请刷新重试。"; timer.Stop(); } }
        finally { if (Current(version)) { busy = false; RenderButtons(); } }
    }
    private async Task FetchJobsAsync(CloudClient client, int version, CancellationToken cancellation)
    {
        var data = await client.JobsAsync(recordingId!, cancellation);
        var updated = data.GetProperty("items").EnumerateArray().Select(CloudJob.Parse).ToArray();
        if (!Current(version) || cancellation.IsCancellationRequested) return;
        var priorSelected = Jobs.SelectedItem as CloudJob;
        var previouslyActive = jobs.Any(x => x.IsActive); jobs = updated; historyLoaded = true;
        rendering = true; Jobs.ItemsSource = jobs; Jobs.SelectedItem = jobs.FirstOrDefault(x => x.Id == priorSelected?.Id); rendering = false;
        Status.Text = jobs.Length == 0 ? "暂无转写任务。" : string.Join(" · ", jobs.Where(x => x.IsActive).Select(x => x.Display));
        if (priorSelected is not null && priorSelected.Status != "succeeded" && Jobs.SelectedItem is CloudJob { Status: "succeeded" } ready) VersionSelected?.Invoke(ready.Id);
        else if (priorSelected is null && previouslyActive && !jobs.Any(x => x.IsActive)) VersionSelected?.Invoke(null);
        if (summaryPending)
        {
            var transcript = await client.TranscriptAsync(recordingId!, cancellation: cancellation);
            if (!Current(version) || cancellation.IsCancellationRequested) return;
            var summary = CloudTranscript.Parse(transcript);
            summaryPending = summary.SummaryStatus is "pending" or "queued" or "running";
            if (!summaryPending && Jobs.SelectedItem is null) VersionSelected?.Invoke(null);
            Status.Text = summaryPending ? "摘要正在生成…" : summary.SummaryStatus == "failed" ? "摘要生成失败，可重试。" : "摘要已更新。";
        }
        if ((jobs.Any(x => x.IsActive) || summaryPending) && DateTimeOffset.UtcNow < pollUntil) timer.Start(); else timer.Stop();
    }
    private void SelectVersion(object sender, SelectionChangedEventArgs e)
    {
        if (rendering) return;
        if (Jobs.SelectedItem is CloudJob job)
        {
            if (job.Status == "succeeded") VersionSelected?.Invoke(job.Id);
            else Status.Text = job.Status == "failed" ? "此版本处理失败。可重试失败分块，或重新转写。" : job.Display;
        }
        RenderButtons();
    }
    public void UpdateSummaryStatus(string status)
    {
        hasTranscript = true; summaryPending = status is "pending" or "queued" or "running";
        if (summaryPending) timer.Start(); RenderButtons();
    }
    private void Latest(object sender, RoutedEventArgs e) { Jobs.SelectedItem = null; VersionSelected?.Invoke(null); }
    private async void Refresh(object sender, RoutedEventArgs e) => await RefreshAsync();
    private bool Approve(string text) => Confirm?.Invoke(text) ?? MessageBox.Show(Window.GetWindow(this), text, "云端处理", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No) == MessageBoxResult.Yes;
    private async void Transcribe(object sender, RoutedEventArgs e)
    {
        if (!TranscribeButton.IsEnabled || !Approve("重新转写会创建新版本，并使用当前设置的语言和上下文。继续？")) return;
        var options = ProcessingOptions();
        await MutateAsync(client => client.TranscribeAsync(recordingId!, options.Language, true, options.Prompt, lifetime!.Token));
    }
    private async void Summarize(object sender, RoutedEventArgs e)
    {
        if (!SummaryButton.IsEnabled || !Approve("重新生成当前转写的摘要？完成后将更新当前摘要。")) return;
        var options = ProcessingOptions();
        await MutateAsync(client => client.SummarizeAsync(recordingId!, options.Prompt, lifetime!.Token), true);
    }
    private async void RetryChunks(object sender, RoutedEventArgs e)
    {
        if (!RetryButton.IsEnabled || Jobs.SelectedItem is not CloudJob job) return;
        await MutateAsync(client => client.RetryChunksAsync(job.Id, lifetime!.Token));
    }
    private async Task MutateAsync(Func<CloudClient, Task<System.Text.Json.JsonElement>> mutation, bool summary = false)
    {
        if (busy || accounts is null || account is null || lifetime is null) return;
        var version = generation; var cancellation = lifetime.Token;
        busy = true; RenderButtons(); Status.Text = "正在提交…";
        try
        {
            using var client = accounts.Client(account); await mutation(client);
            if (!Current(version) || cancellation.IsCancellationRequested) return;
            summaryPending |= summary; pollUntil = DateTimeOffset.UtcNow.AddMinutes(30);
            await FetchJobsAsync(client, version, cancellation);
        }
        catch (OperationCanceledException) { if (Current(version)) Status.Text = "请求已取消；服务器可能已接收，请刷新任务历史确认。"; }
        catch (Exception error)
        {
            if (Current(version)) Status.Text = error is CloudException { Status: HttpStatusCode.Unauthorized } ? "登录已过期，请重新连接账号。" : "请求未能确认。请刷新任务历史，确认结果后再重试。";
        }
        finally { if (Current(version)) { busy = false; RenderButtons(); } }
    }
}
