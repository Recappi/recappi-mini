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
    private readonly TextBlock initial = new();
    private readonly Button connect;
    private readonly Button verify;
    private readonly Button cancelLogin;
    private readonly Button refresh;
    private readonly Button signOut;
    private readonly StackPanel usagePanel = new() { Spacing = 12 };
    private readonly TextBlock tier = new() { Text = "—" };
    private readonly TextBlock resets = new();
    private readonly Meter minutesMeter = new("转写时长");
    private readonly Meter storageMeter = new("云端存储");
    private string? usageFor;
    private readonly Grid usageSurface;
    private Uri? verification;
    private bool closed;
    public AccountWindow(IDesktopHost app) : base("Recappi Mini · 账号", 520, 540)
    {
        this.app = app;
        Body.Spacing = 14; Body.Padding = new Thickness(24, 8, 24, 24);
        Error.Style = RecappiTheme.Style("RecappiError"); Error.FontSize = 12;
        var accountPanel = new StackPanel { Spacing = 14 };
        // Identity header: initial avatar · email · connection state.
        var header = new Grid { ColumnSpacing = 14 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); header.ColumnDefinitions.Add(new ColumnDefinition());
        var avatar = new Border { Width = 48, Height = 48, CornerRadius = new CornerRadius(24), Child = initial };
        RecappiTheme.Bind(avatar, "RecappiAccentChipFill", brush => avatar.Background = brush);
        initial.Style = RecappiTheme.Style("RecappiStatusAccent"); initial.FontSize = 20; initial.HorizontalAlignment = HorizontalAlignment.Center;
        header.Children.Add(avatar);
        var names = new StackPanel { Spacing = 2, VerticalAlignment = VerticalAlignment.Center };
        identity.Style = RecappiTheme.Style("RecappiSectionTitle"); identity.FontSize = 17; identity.TextTrimming = TextTrimming.CharacterEllipsis;
        state.Style = RecappiTheme.Style("RecappiBodySecondary");
        names.Children.Add(identity); names.Children.Add(state);
        Grid.SetColumn(names, 1); header.Children.Add(names);
        accountPanel.Children.Add(header);
        code.FontSize = 22; code.FontWeight = Microsoft.UI.Text.FontWeights.SemiBold; code.FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Cascadia Mono, Consolas");
        accountPanel.Children.Add(code);
        connect = Ui.Button("连接账号", async () => await app.Account.SignInAsync(app.Origin, prompt => UiDispatcher.TryEnqueue(() =>
        { if (!closed) { verification = prompt.VerificationUri; code.Text = "确认码：" + prompt.Code; Render(); } })), this);
        verify = Ui.Button("打开浏览器确认", () => { if (verification is { } uri) Open(uri); return Task.CompletedTask; }, this);
        cancelLogin = Ui.Button("取消登录", () => { app.Account.CancelLogin(); return Task.CompletedTask; }, this);
        refresh = Ui.Button("刷新连接", () => app.Account.RefreshAsync(), this);
        signOut = Ui.Button("退出账号", () => app.Account.SignOutAsync(), this);
        accountPanel.Children.Add(Ui.Row(connect, verify, cancelLogin, refresh, signOut));
        Body.Children.Add(Ui.Surface(accountPanel, new Thickness(20)));
        // Usage loads by itself whenever the account is connected (macOS shows it on open): the plan as a
        // badge, a meter for each allowance, and when it resets. Manage plan opens the billing portal.
        var usageHeader = new Grid();
        usageHeader.ColumnDefinitions.Add(new ColumnDefinition()); usageHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        usageHeader.Children.Add(new TextBlock { Text = "用量与套餐", Style = RecappiTheme.Style("RecappiSectionTitle"), VerticalAlignment = VerticalAlignment.Center });
        tier.Style = RecappiTheme.Style("RecappiStatusAccent"); tier.FontSize = 11.5;
        var tierChip = new Border { Child = tier, Padding = new Thickness(9, 3, 9, 3), CornerRadius = new CornerRadius(10), VerticalAlignment = VerticalAlignment.Center };
        RecappiTheme.Bind(tierChip, "RecappiAccentChipFill", brush => tierChip.Background = brush);
        Grid.SetColumn(tierChip, 1); usageHeader.Children.Add(tierChip);
        usagePanel.Children.Add(usageHeader);
        billing.Style = RecappiTheme.Style("RecappiBodySecondary"); billing.FontSize = 12.5; billing.TextWrapping = TextWrapping.Wrap;
        usagePanel.Children.Add(billing);
        usagePanel.Children.Add(minutesMeter.Root); usagePanel.Children.Add(storageMeter.Root);
        resets.Style = RecappiTheme.Style("RecappiCaption"); resets.FontSize = 11.5;
        usagePanel.Children.Add(resets);
        var managePlan = Ui.Button("管理套餐", async () =>
        {
            var account = RequireAccount(); using var client = app.Account.Client(account);
            var uri = await client.BillingPortalAsync(); if (IsCurrent(account)) Open(uri);
        }, this);
        usagePanel.Children.Add(Ui.Row(managePlan));
        usageSurface = Ui.Surface(usagePanel, new Thickness(20)); Body.Children.Add(usageSurface);
        var page = (ScrollViewer)Content;
        Content = PageFrame(page, "账号");
        FitHeightTo(page);
        app.Account.Changed += Changed;
        Closed += (_, _) => { closed = true; app.Account.CancelLogin(); app.Account.Changed -= Changed; };
        Render();
    }
    private CloudAccount RequireAccount() => app.Account.Snapshot is { State: AccountState.SignedIn, Account: { } account } ? account : throw new InvalidOperationException("请先连接账号。");
    private bool IsCurrent(CloudAccount account) => !closed && app.Account.Snapshot is { State: AccountState.SignedIn, Account: { } current } && current.Partition == account.Partition && current.Token == account.Token;
    private void Changed(AccountSnapshot _) => UiDispatcher.TryEnqueue(() => { if (!closed) Render(); });
    // One label, a thin bar and "used / allowance" on the right.
    private sealed class Meter
    {
        public readonly StackPanel Root = new() { Spacing = 5 };
        private readonly TextBlock value = new() { FontSize = 12, HorizontalAlignment = HorizontalAlignment.Right };
        private readonly ProgressBar bar = new() { Minimum = 0, Maximum = 100, Height = 4, MinHeight = 4, CornerRadius = new CornerRadius(2) };
        public Meter(string label)
        {
            var row = new Grid(); row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new TextBlock { Text = label, FontSize = 13, Style = RecappiTheme.Style("RecappiBody") });
            value.Style = RecappiTheme.Style("RecappiBodySecondary"); Grid.SetColumn(value, 1); row.Children.Add(value);
            Root.Children.Add(row); Root.Children.Add(bar);
        }
        public void Set(string text, double percent, bool unlimited, bool over)
        {
            value.Text = text; bar.Value = percent; bar.Visibility = unlimited ? Visibility.Collapsed : Visibility.Visible;
            bar.Foreground = RecappiTheme.Brush(over ? "RecappiDanger" : "RecappiAccent", bar.ActualTheme);
        }
    }
    private async Task LoadUsage()
    {
        if (app.Account.Snapshot is not { State: AccountState.SignedIn, Account: { } account } || usageFor == account.Token) return;
        usageFor = account.Token;
        billing.Text = "正在读取用量…"; billing.Visibility = Visibility.Visible;
        minutesMeter.Root.Visibility = storageMeter.Root.Visibility = resets.Visibility = Visibility.Collapsed;
        try
        {
            using var client = app.Account.Client(account);
            var usage = await client.BillingStatusAsync();
            if (!IsCurrent(account)) return;
            tier.Text = usage.Tier switch { "free" => "免费版", "pro" => "专业版", "unlimited" => "不限量", var other => other };
            static string Size(long bytes) => bytes >= 1L << 30 ? $"{bytes / (double)(1L << 30):0.#} GB" : $"{bytes / 1048576d:0.#} MB";
            minutesMeter.Set($"{usage.MinutesUsed:0.#} / {(usage.UnlimitedMinutes ? "不限" : $"{usage.MinutesCap:0.#}")} 分钟", usage.MinutesPercent, usage.UnlimitedMinutes, !usage.UnlimitedMinutes && usage.IsOverMinutes);
            storageMeter.Set($"{Size(usage.StorageBytes)} / {(usage.UnlimitedStorage ? "不限" : Size(usage.StorageCapBytes))}", usage.StoragePercent, usage.UnlimitedStorage, !usage.UnlimitedStorage && usage.IsOverStorage);
            resets.Text = usage.PeriodEnd is { } end ? $"额度将于 {end.ToLocalTime():M月d日} 重置" : "";
            billing.Text = usage.OverLimit ? "已超出套餐额度，新的录音将无法上传处理。" : "";
            billing.Visibility = billing.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            minutesMeter.Root.Visibility = storageMeter.Root.Visibility = Visibility.Visible;
            resets.Visibility = resets.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        catch (Exception) when (!closed)
        {
            usageFor = null;
            billing.Text = "暂时无法读取用量，稍后重新打开账号窗口再试。";
        }
    }
    private void Render()
    {
        var value = app.Account.Snapshot;
        identity.Text = value.Account?.Email ?? "尚未登录";
        initial.Text = value.Account?.Email is { Length: > 0 } email ? email[..1].ToUpperInvariant() : "?";
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
        if (connected) _ = LoadUsage(); else usageFor = null;
    }
    private static void Open(Uri uri) => Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
}
