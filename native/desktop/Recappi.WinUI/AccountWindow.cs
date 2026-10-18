using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Recappi.Core;

namespace Recappi.WinUI;

internal sealed class AccountWindow : DesktopWindow
{
    private readonly IDesktopHost app;
    private readonly TextBlock identity = Ui.Text("", 24);
    private readonly TextBlock state = Ui.Text("");
    private readonly TextBlock code = Ui.Text("");
    private readonly TextBlock billing = Ui.Text("");
    private readonly Button connect;
    private readonly Button verify;
    private readonly Button cancelLogin;
    private readonly Button refresh;
    private readonly Button signOut;
    private readonly StackPanel usagePanel = new() { Spacing = 12 };
    private readonly Border usageSurface;
    private Uri? verification;
    private bool closed;
    public AccountWindow(IDesktopHost app) : base("Recappi Mini · 账号", 520, 540)
    {
        this.app = app;
        Body.Spacing = 16; Body.Children.Add(Ui.Text("账号", 24));
        var accountPanel = new StackPanel { Spacing = 12 };
        accountPanel.Children.Add(new FontIcon { Glyph = "\uE77B", FontSize = 28, HorizontalAlignment = HorizontalAlignment.Left, Opacity = 0.6 });
        accountPanel.Children.Add(identity); state.Opacity = 0.7; accountPanel.Children.Add(state);
        code.FontSize = 22; code.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; accountPanel.Children.Add(code);
        connect = Ui.Button("连接账号", async () => await app.Account.SignInAsync(app.Origin, prompt => UiDispatcher.TryEnqueue(() =>
        { if (!closed) { verification = prompt.VerificationUri; code.Text = "确认码：" + prompt.Code; Render(); } })), this);
        verify = Ui.Button("打开浏览器确认", () => { if (verification is { } uri) Open(uri); return Task.CompletedTask; }, this);
        cancelLogin = Ui.Button("取消登录", () => { app.Account.CancelLogin(); return Task.CompletedTask; }, this);
        refresh = Ui.Button("刷新连接", () => app.Account.RefreshAsync(), this);
        signOut = Ui.Button("退出账号", () => app.Account.SignOutAsync(), this);
        accountPanel.Children.Add(Ui.Row(connect, verify, cancelLogin, refresh, signOut));
        Body.Children.Add(Ui.Surface(accountPanel, new Thickness(16)));
        usagePanel.Children.Add(Ui.Text("用量与套餐", 20)); usagePanel.Children.Add(billing);
        var refreshUsage = Ui.Button("刷新用量", async () =>
        {
            var account = RequireAccount(); using var client = app.Account.Client(account);
            var usage = await client.BillingStatusAsync();
            if (!IsCurrent(account)) return;
            billing.Text = $"套餐：{usage.Tier}\n存储：{usage.StorageBytes / 1048576d:F1} MB / {(usage.UnlimitedStorage ? "不限量" : $"{usage.StorageCapBytes / 1048576d:F1} MB")}\n转写：{usage.MinutesUsed:F1} 分钟 / {(usage.UnlimitedMinutes ? "不限量" : $"{usage.MinutesCap:F1} 分钟")}";
        }, this);
        var managePlan = Ui.Button("管理套餐", async () =>
        {
            var account = RequireAccount(); using var client = app.Account.Client(account);
            var uri = await client.BillingPortalAsync(); if (IsCurrent(account)) Open(uri);
        }, this);
        usagePanel.Children.Add(Ui.Row(refreshUsage, managePlan));
        usageSurface = Ui.Surface(usagePanel, new Thickness(16)); Body.Children.Add(usageSurface);
        app.Account.Changed += Changed;
        Closed += (_, _) => { closed = true; app.Account.CancelLogin(); app.Account.Changed -= Changed; };
        Render();
    }
    private CloudAccount RequireAccount() => app.Account.Snapshot is { State: AccountState.SignedIn, Account: { } account } ? account : throw new InvalidOperationException("请先连接账号。");
    private bool IsCurrent(CloudAccount account) => !closed && app.Account.Snapshot is { State: AccountState.SignedIn, Account: { } current } && current.Partition == account.Partition && current.Token == account.Token;
    private void Changed(AccountSnapshot _) => UiDispatcher.TryEnqueue(() => { if (!closed) { billing.Text = ""; Render(); } });
    private void Render()
    {
        var value = app.Account.Snapshot;
        identity.Text = value.Account?.Email ?? "尚未登录";
        state.Text = value.Message ?? value.State switch { AccountState.SignedIn => "已连接 Recappi Cloud", AccountState.SigningIn => "等待浏览器确认…", AccountState.Checking => "正在检查连接…", AccountState.Offline => "云端暂时不可用，本地录音可继续。", AccountState.Expired => "登录已过期。", _ => "可以先使用本地录音。" };
        if (value.State != AccountState.SigningIn) { verification = null; code.Text = ""; }
        var signingIn = value.State == AccountState.SigningIn;
        var connected = value.State == AccountState.SignedIn;
        connect.Visibility = connected || signingIn ? Visibility.Collapsed : Visibility.Visible;
        connect.IsEnabled = value.State != AccountState.Checking;
        verify.Visibility = cancelLogin.Visibility = signingIn ? Visibility.Visible : Visibility.Collapsed;
        verify.IsEnabled = verification is not null;
        code.Visibility = code.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        refresh.Visibility = signOut.Visibility = value.Account is not null && !signingIn ? Visibility.Visible : Visibility.Collapsed;
        refresh.IsEnabled = signOut.IsEnabled = value.State != AccountState.Checking;
        usageSurface.Visibility = connected ? Visibility.Visible : Visibility.Collapsed;
    }
    private static void Open(Uri uri) => Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
}
