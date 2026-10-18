using Microsoft.UI.Xaml.Controls;
using Recappi.Core;

namespace Recappi.WinUI;

internal sealed class ReviewPanel : IDisposable
{
    public StackPanel Root { get; } = new() { Spacing = 12, Padding = new Microsoft.UI.Xaml.Thickness(0, 16, 16, 16), MaxWidth = 720, HorizontalAlignment = Microsoft.UI.Xaml.HorizontalAlignment.Left };
    private readonly LibraryWindow owner;
    private readonly IDesktopHost app;
    private readonly CloudAccount account;
    private readonly CloudRecordingItem recording;
    private readonly Func<bool> current;
    private readonly Func<string?, Task> selectVersion;
    private readonly CancellationTokenSource lifetime = new();
    private readonly ComboBox versions = new() { Header = "转写历史", DisplayMemberPath = "Display" };
    private readonly TextBlock status = Ui.Text("");
    private CloudJob[] jobs = [];
    private bool busy;
    private bool disposed;
    private bool uncertain;
    private bool summaryPending;
    private bool summaryNeedsRefresh;
    private bool hasTranscript;
    private bool historyLoaded;
    private bool rendering;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer timer;
    private readonly Button transcribe;
    private readonly Button summarize;
    private readonly Button retry;
    private DateTimeOffset pollUntil = DateTimeOffset.UtcNow.AddMinutes(30);
    public ReviewPanel(LibraryWindow owner, IDesktopHost app, CloudAccount account, CloudRecordingItem recording, Func<bool> current, Func<string?, Task> selectVersion)
    {
        this.owner = owner; this.app = app; this.account = account; this.recording = recording; this.current = current; this.selectVersion = selectVersion;
        timer = owner.DispatcherQueue.CreateTimer(); timer.Interval = TimeSpan.FromSeconds(2); timer.Tick += async (_, _) => await Load();
        Root.Children.Add(new TextBlock { Text = "重新处理", Style = RecappiTheme.Style("RecappiSectionTitle") });
        status.Style = RecappiTheme.Style("RecappiBodySecondary"); Root.Children.Add(status);
        versions.MinWidth = 320; Root.Children.Add(versions);
        transcribe = Ui.Button("重新转写", () => Submit("重新转写", "将使用当前语言和上下文创建新版本，可能消耗转写额度。", 0), owner);
        summarize = Ui.Button("重新生成摘要", () => Submit("重新生成摘要", "重新生成当前转写的摘要？", 1), owner);
        retry = Ui.Button("重试失败分块", () => Submit("重试失败分块", "只重试所选任务可重试的失败部分。", 2), owner);
        Root.Children.Add(Ui.Row(Ui.Button("当前版本", async () => { versions.SelectedItem = null; await selectVersion(null); }, owner), Ui.Button("刷新任务", Load, owner)));
        Root.Children.Add(Ui.Row(transcribe, summarize, retry));
        versions.SelectionChanged += async (_, _) => { if (!rendering && Current) { Render(); if (versions.SelectedItem is CloudJob { Status: "succeeded" } job) await owner.Run(() => selectVersion(job.Id)); } };
        Render();
    }
    private bool Current => !disposed && current();
    public async Task Load()
    {
        if (!Current || busy) return;
        busy = true; Render();
        try { using var client = app.Account.Client(account); await Fetch(client); }
        catch (OperationCanceledException) { }
        catch (Exception) { if (Current) { status.Text = "任务历史加载失败，请刷新重试。"; timer.Stop(); } }
        finally { busy = false; if (Current) Render(); }
    }
    public void UpdateTranscript(CloudTranscript value)
    {
        hasTranscript = true; summaryPending = value.SummaryStatus is "pending" or "queued" or "running";
        if (summaryPending) timer.Start(); Render();
    }
    private void Render()
    {
        var available = Current && !busy && !uncertain && historyLoaded;
        transcribe.IsEnabled = available && recording.Status is not ("uploading" or "aborted") && !jobs.Any(x => x.IsActive);
        summarize.IsEnabled = available && hasTranscript && !summaryPending && !jobs.Any(x => x.IsActive);
        retry.IsEnabled = available && versions.SelectedItem is CloudJob { Status: "failed", HasRetryableChunks: true } && !jobs.Any(x => x.IsActive);
    }
    private async Task Fetch(CloudClient client)
    {
        var value = await client.JobsAsync(recording.Id, lifetime.Token);
        if (!Current) return;
        var prior = versions.SelectedItem as CloudJob; var wasActive = jobs.Any(x => x.IsActive);
        jobs = value.GetProperty("items").EnumerateArray().Select(CloudJob.Parse).ToArray();
        historyLoaded = true; rendering = true;
        try { versions.ItemsSource = jobs; versions.SelectedItem = jobs.FirstOrDefault(x => x.Id == prior?.Id); }
        finally { rendering = false; }
        status.Text = jobs.FirstOrDefault()?.Display ?? "暂无转写任务";
        if (prior is not null && prior.Status != "succeeded" && versions.SelectedItem is CloudJob { Status: "succeeded" } ready) await selectVersion(ready.Id);
        else if (prior is null && wasActive && !jobs.Any(x => x.IsActive)) await selectVersion(null);
        if (!Current) return;
        if (summaryPending || summaryNeedsRefresh)
        {
            var text = CloudTranscript.Parse(await client.TranscriptAsync(recording.Id, cancellation: lifetime.Token));
            if (!Current) return;
            summaryNeedsRefresh = false; summaryPending = text.SummaryStatus is "pending" or "queued" or "running";
            status.Text = summaryPending ? "摘要正在生成…" : text.SummaryStatus == "failed" ? "摘要生成失败，可以重试。" : "摘要已更新。";
            if (!summaryPending && versions.SelectedItem is null) await selectVersion(null);
        }
        if (!Current) return;
        uncertain = false;
        if ((jobs.Any(x => x.IsActive) || summaryPending) && DateTimeOffset.UtcNow < pollUntil) timer.Start(); else timer.Stop();
    }
    private async Task Submit(string title, string message, int operation)
    {
        if (busy || !Current || uncertain || !(operation == 0 ? transcribe.IsEnabled : operation == 1 ? summarize.IsEnabled : retry.IsEnabled)) return;
        busy = true; Render();
        try
        {
            var selectedJob = (versions.SelectedItem as CloudJob)?.Id;
            if (!await owner.Confirm(title, message, "确认") || !Current) return;
            using var client = app.Account.Client(account);
            var latest = await client.JobsAsync(recording.Id, lifetime.Token);
            if (!Current) return;
            var latestJobs = latest.GetProperty("items").EnumerateArray().Select(CloudJob.Parse).ToArray();
            if (latestJobs.Any(x => x.IsActive)) throw new InvalidOperationException("已有转写任务正在处理，请稍后再试。");
            if (operation == 2 && !latestJobs.Any(x => x.Id == selectedJob && x.Status == "failed" && x.HasRetryableChunks)) throw new InvalidOperationException("所选任务没有可重试分块。");
            if (operation == 1)
            {
                var text = CloudTranscript.Parse(await client.TranscriptAsync(recording.Id, cancellation: lifetime.Token));
                if (!Current) return;
                if (text.SummaryStatus is "pending" or "queued" or "running") throw new InvalidOperationException("摘要正在生成，请稍后再试。");
            }
            uncertain = true; summaryNeedsRefresh = operation == 1;
            if (operation == 0) await client.TranscribeAsync(recording.Id, app.Preferences.TranscriptionLanguage, true, app.Preferences.Processing.Prompt, lifetime.Token,
                provider: "gemini");
            else if (operation == 1) await client.SummarizeAsync(recording.Id, app.Preferences.Processing.Prompt, lifetime.Token);
            else await client.RetryChunksAsync(selectedJob!, lifetime.Token);
            if (!Current) return;
            summaryPending |= operation == 1; pollUntil = DateTimeOffset.UtcNow.AddMinutes(30); await Fetch(client);
        }
        catch (Exception) { if (Current) { timer.Stop(); status.Text = uncertain ? "请求结果未能确认。请先刷新任务历史，再决定是否重试。" : "操作未完成，请刷新后重试。"; } }
        finally { busy = false; if (Current) Render(); }
    }
    public void Dispose() { if (disposed) return; disposed = true; timer.Stop(); lifetime.Cancel(); }
}
