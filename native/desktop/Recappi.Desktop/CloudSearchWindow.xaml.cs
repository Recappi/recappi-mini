using System;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Input;
using Recappi.Core;

namespace Recappi.Desktop;

public partial class CloudSearchWindow : Window
{
    private readonly CloudContentCache cache;
    private readonly AccountSession accounts;
    private readonly string partition;
    private readonly Action<CloudSearchHit> open;
    private CancellationTokenSource? request;
    private bool closed;
    public CloudSearchWindow(CloudContentCache cache, AccountSession accounts, string partition, Action<CloudSearchHit> open)
    {
        DesktopTheme.EnsureResources();
        InitializeComponent(); this.cache = cache; this.accounts = accounts; this.partition = partition; this.open = open;
        accounts.Changed += AccountChanged;
        Loaded += async (_, _) => { Query.Focus(); await SearchAsync(); };
        Closed += (_, _) => { closed = true; request?.Cancel(); request?.Dispose(); accounts.Changed -= AccountChanged; Results.ItemsSource = null; };
    }
    private bool Current => !closed && accounts.Snapshot is { State: AccountState.SignedIn or AccountState.Offline, Account: { } account } && account.Partition == partition;
    private void AccountChanged(AccountSnapshot _) => Dispatcher.BeginInvoke(() => { if (!Current && !closed) Close(); });
    private async void Search(object sender, RoutedEventArgs e) => await SearchAsync();
    public async Task SearchAsync()
    {
        request?.Cancel(); request?.Dispose(); request = new();
        var cancellation = request.Token;
        Results.ItemsSource = null; Status.Text = "正在搜索本地缓存…";
        try
        {
            var result = await cache.SearchAsync(partition, Query.Text, Speaker.Text, cancellation);
            if (cancellation.IsCancellationRequested || !Current) return;
            Results.ItemsSource = result.Hits;
            Status.Text = $"已缓存 {result.CachedRecordings} 条录音；找到 {result.Hits.Count} 个结果。" + (result.Truncated ? "结果超过 100 个，请缩小搜索范围。" : "") + (result.UnreadableRecordings > 0 ? $" {result.UnreadableRecordings} 条缓存读取失败。" : "");
        }
        catch (OperationCanceledException) { }
        catch (Exception) { if (!cancellation.IsCancellationRequested && Current) Status.Text = "缓存搜索失败，请重试。"; }
    }
    private void OpenResult(object sender, MouseButtonEventArgs e) => Open();
    private void OpenSelected(object sender, RoutedEventArgs e) => Open();
    private void Open() { if (Current && Results.SelectedItem is CloudSearchHit hit) { open(hit); Close(); } }
}
