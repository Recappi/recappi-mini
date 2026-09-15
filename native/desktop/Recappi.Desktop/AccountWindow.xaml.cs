using System;
using System.Diagnostics;
using System.Threading.Tasks;
using System.Windows;
using Recappi.Core;

namespace Recappi.Desktop;

public partial class AccountWindow : Window
{
    private readonly AccountSession session;
    private readonly string origin;
    private Uri? verification;
    private bool working;
    public AccountWindow(AccountSession session, string origin)
    {
        DesktopTheme.EnsureResources();
        InitializeComponent(); this.session = session; this.origin = origin;
        BillingContent.Content = new BillingPanel(session);
        session.Changed += Changed;
        Closed += (_, _) => { session.CancelLogin(); session.Changed -= Changed; };
        Render();
    }
    private void Changed(AccountSnapshot value) => Dispatcher.BeginInvoke(Render);
    private void Render()
    {
        var value = session.Snapshot;
        Identity.Text = value.Account?.Email ?? value.Account?.UserId ?? "尚未登录";
        Status.Text = value.Message ?? value.State switch
        {
            AccountState.Checking => "正在检查连接…", AccountState.SigningIn => "等待浏览器中的登录确认…",
            AccountState.SignedIn => "已连接 Recappi Cloud", AccountState.Expired => "登录已过期",
            AccountState.Offline => "云端暂时不可用", AccountState.Failed => "账号读取失败", _ => "可以先使用本地录音。"
        };
        SignInButton.IsEnabled = !working;
        SignOutButton.IsEnabled = !working && value.Account is not null;
        RefreshButton.IsEnabled = !working && value.Account is not null;
        CancelButton.IsEnabled = value.State == AccountState.SigningIn;
        if (value.State != AccountState.SigningIn) PromptPanel.Visibility = Visibility.Collapsed;
    }
    private async Task Run(Func<Task> action)
    {
        working = true; Render();
        try { await action(); }
        catch (Exception) { Status.Text = "操作未完成，请重试。"; }
        finally { working = false; Render(); }
    }
    private async void SignIn(object sender, RoutedEventArgs e) => await Run(() => session.SignInAsync(origin, prompt => Dispatcher.BeginInvoke(() =>
    {
        verification = prompt.VerificationUri; Code.Text = prompt.Code; PromptPanel.Visibility = Visibility.Visible;
    })));
    private async void Refresh(object sender, RoutedEventArgs e) => await Run(() => session.RefreshAsync());
    private async void SignOut(object sender, RoutedEventArgs e) => await Run(() => session.SignOutAsync());
    private void Cancel(object sender, RoutedEventArgs e) => session.CancelLogin();
    private void OpenVerification(object sender, RoutedEventArgs e)
    {
        if (verification is null) return;
        try { Process.Start(new ProcessStartInfo(verification.AbsoluteUri) { UseShellExecute = true }); }
        catch { Status.Text = "无法打开浏览器，请检查系统默认浏览器。"; }
    }
}
