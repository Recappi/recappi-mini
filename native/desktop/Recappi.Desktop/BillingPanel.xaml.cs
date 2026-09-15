using System;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Recappi.Core;

namespace Recappi.Desktop;

public partial class BillingPanel : UserControl
{
    private readonly AccountSession session;
    private readonly Action<Uri> open;
    private CancellationTokenSource? pending;
    private AccountSnapshot? displayed;
    private int generation;
    private bool busy;
    public BillingPanel(AccountSession session, Action<Uri>? open = null)
    {
        DesktopTheme.EnsureResources(); InitializeComponent(); this.session = session;
        this.open = open ?? (uri => Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true }));
        Loaded += (_, _) => { session.Changed += Changed; Synchronize(); };
        Unloaded += (_, _) => { session.Changed -= Changed; CancelRequest(); Clear(); displayed = null; };
        IsVisibleChanged += (_, _) => { if (IsLoaded) Synchronize(); };
        Clear(); RenderButtons();
    }
    private void Changed(AccountSnapshot _) => Dispatcher.BeginInvoke(Synchronize);
    private void CancelRequest() { generation++; pending?.Cancel(); pending?.Dispose(); pending = null; busy = false; }
    private void Clear() { Usage.Visibility = Visibility.Collapsed; Tier.Text = Storage.Text = Minutes.Text = Period.Text = ""; StorageProgress.Value = MinutesProgress.Value = 0; }
    private bool Available => IsLoaded && IsVisible && session.Snapshot.State == AccountState.SignedIn;
    private bool Current(int version, CloudAccount account) => version == generation && Available && session.Snapshot.Account is { } active && active.Partition == account.Partition && active.Token == account.Token;
    private void RenderButtons() { RefreshButton.IsEnabled = ManageButton.IsEnabled = Available && !busy; }
    private void Synchronize()
    {
        if (!IsLoaded) return;
        var snapshot = session.Snapshot;
        if (IsVisible && displayed == snapshot) return;
        CancelRequest(); Clear(); displayed = IsVisible ? snapshot : null;
        Status.Text = snapshot.State switch
        {
            AccountState.SignedIn => "", AccountState.Offline => "离线时无法读取最新用量，请先检查账号连接。",
            AccountState.Expired => "登录已过期，请重新连接后查看用量。", AccountState.Checking or AccountState.SigningIn => "账号连接完成后显示用量。",
            _ => "登录后可查看套餐和用量。"
        };
        RenderButtons();
        if (Available) _ = LoadAsync();
    }
    private async void Refresh(object sender, RoutedEventArgs e) => await LoadAsync();
    private async Task LoadAsync()
    {
        if (!Available || busy || session.Snapshot.Account is not { } account) return;
        CancelRequest(); var version = generation; pending = new(); var token = pending.Token;
        busy = true; Clear(); Status.Text = "正在读取用量…"; RenderButtons();
        try
        {
            using var client = session.Client(account);
            var value = await client.BillingStatusAsync(token);
            if (!Current(version, account)) return;
            Tier.Text = value.Tier switch { "free" => "Free", "starter" => "Starter", "pro" => "Pro", "business" => "Business", "unlimited" => "Unlimited", _ => value.Tier };
            Storage.Text = $"云端存储：{Bytes(value.StorageBytes)} / {(value.UnlimitedStorage ? "不限量" : Bytes(value.StorageCapBytes))}";
            Minutes.Text = $"转写：{value.MinutesUsed:N1} / {(value.UnlimitedMinutes ? "不限量" : value.MinutesCap.ToString("N1"))} 分钟";
            StorageProgress.Value = value.StoragePercent; MinutesProgress.Value = value.MinutesPercent;
            StorageProgress.Visibility = value.UnlimitedStorage ? Visibility.Collapsed : Visibility.Visible;
            MinutesProgress.Visibility = value.UnlimitedMinutes ? Visibility.Collapsed : Visibility.Visible;
            Period.Text = value.PeriodEnd is { } end ? $"当前周期截至 {end.LocalDateTime:d}" : "";
            Status.Text = value.OverLimit ? "已超出当前套餐用量；可在浏览器中管理订阅。" : "当前账号的最新用量";
            Usage.Visibility = Visibility.Visible;
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception) { if (Current(version, account)) Status.Text = "用量读取失败，请重试。"; }
        finally { if (version == generation) { pending?.Dispose(); pending = null; busy = false; RenderButtons(); } }
    }
    private async void Manage(object sender, RoutedEventArgs e)
    {
        if (!Available || busy || session.Snapshot.Account is not { } account) return;
        CancelRequest(); var version = generation; pending = new(); var token = pending.Token;
        busy = true; Status.Text = "正在打开订阅管理…"; RenderButtons();
        try
        {
            using var client = session.Client(account);
            var uri = await client.BillingPortalAsync(token);
            if (!Current(version, account)) return;
            open(uri); Status.Text = "已在浏览器打开订阅管理。";
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
        catch (Exception) { if (Current(version, account)) Status.Text = "无法打开订阅管理，请重试。"; }
        finally { if (version == generation) { pending?.Dispose(); pending = null; busy = false; RenderButtons(); } }
    }
    private static string Bytes(long bytes)
    {
        string[] units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"];
        var value = (double)bytes; var unit = 0;
        while (value >= 1000 && unit < units.Length - 1) { value /= 1000; unit++; }
        return $"{value:N1} {units[unit]}";
    }
}
