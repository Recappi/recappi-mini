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
    private readonly Microsoft.UI.Xaml.Shapes.Ellipse picture = new() { Width = 48, Height = 48, Visibility = Visibility.Collapsed };
    private string? pictureUrl;
    private readonly Button connect;
    private readonly Button verify;
    private readonly Button cancelLogin;
    private readonly Button refresh;
    private readonly Button signOut;
    private readonly StackPanel usagePanel = new() { Spacing = 12 };
    private readonly TextBlock tier = new() { Text = "—" };
    private readonly TextBlock resets = new();
    private readonly Meter minutesMeter = new(L.T("转写时长", "Transcription"));
    private readonly Meter storageMeter = new(L.T("云端存储", "Cloud storage"));
    private string? usageFor;
    private readonly Grid usageSurface;
    private Uri? verification;
    private bool closed;
    public AccountWindow(IDesktopHost app) : base(L.T("Recappi Mini · 账号", "Recappi Mini · Account"), 520, 540)
    {
        this.app = app;
        Body.Spacing = 14; Body.Padding = new Thickness(24, 8, 24, 24);
        Error.Style = RecappiTheme.Style("RecappiError"); Error.FontSize = 12;
        var accountPanel = new StackPanel { Spacing = 14 };
        // Identity header: initial avatar · email · connection state.
        var header = new Grid { ColumnSpacing = 14 };
        header.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); header.ColumnDefinitions.Add(new ColumnDefinition());
        // Profile picture over the initial, as in the library header (initial while it loads or fails).
        var face = new Grid(); face.Children.Add(initial); face.Children.Add(picture);
        var avatar = new Border { Width = 48, Height = 48, CornerRadius = new CornerRadius(24), Child = face };
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
        connect = Ui.Button(L.T("连接账号", "Connect account"), async () => await app.Account.SignInAsync(app.Origin, prompt => UiDispatcher.TryEnqueue(() =>
        { if (!closed) { verification = prompt.VerificationUri; code.Text = L.T("确认码：", "Code: ") + prompt.Code; Render(); } })), this);
        verify = Ui.Button(L.T("打开浏览器确认", "Confirm in browser"), () => { if (verification is { } uri) Open(uri); return Task.CompletedTask; }, this);
        cancelLogin = Ui.Button(L.T("取消登录", "Cancel sign-in"), () => { app.Account.CancelLogin(); return Task.CompletedTask; }, this);
        refresh = Ui.Button(L.T("刷新连接", "Refresh connection"), () => app.Account.RefreshAsync(), this);
        signOut = Ui.Button(L.T("退出账号", "Sign out"), () => app.Account.SignOutAsync(), this);
        accountPanel.Children.Add(Ui.Row(connect, verify, cancelLogin, refresh, signOut));
        Body.Children.Add(Ui.Surface(accountPanel, new Thickness(20)));
        // Usage loads by itself whenever the account is connected (macOS shows it on open): the plan as a
        // badge, a meter for each allowance, and when it resets. Manage plan opens the billing portal.
        var usageHeader = new Grid();
        usageHeader.ColumnDefinitions.Add(new ColumnDefinition()); usageHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        usageHeader.Children.Add(new TextBlock { Text = L.T("用量与套餐", "Usage and plan"), Style = RecappiTheme.Style("RecappiSectionTitle"), VerticalAlignment = VerticalAlignment.Center });
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
        var managePlan = Ui.Button(L.T("管理套餐", "Manage plan"), async () =>
        {
            var account = RequireAccount(); using var client = app.Account.Client(account);
            var uri = await client.BillingPortalAsync(); if (IsCurrent(account)) Open(uri);
        }, this);
        usagePanel.Children.Add(Ui.Row(managePlan));
        usageSurface = Ui.Surface(usagePanel, new Thickness(20)); Body.Children.Add(usageSurface);
        var page = (ScrollViewer)Content;
        Content = PageFrame(page, L.T("账号", "Account")); CloseWithKeyboard(page);
        FitHeightTo(page);
        app.Account.Changed += Changed;
        Closed += (_, _) => { closed = true; app.Account.CancelLogin(); app.Account.Changed -= Changed; };
        Render();
    }
    private CloudAccount RequireAccount() => app.Account.Snapshot is { State: AccountState.SignedIn, Account: { } account } ? account : throw new InvalidOperationException(L.T("请先连接账号。", "Connect an account first."));
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
        billing.Text = L.T("正在读取用量…", "Loading usage…"); billing.Visibility = Visibility.Visible;
        minutesMeter.Root.Visibility = storageMeter.Root.Visibility = resets.Visibility = Visibility.Collapsed;
        try
        {
            using var client = app.Account.Client(account);
            var usage = await client.BillingStatusAsync();
            if (!IsCurrent(account)) return;
            tier.Text = usage.Tier switch { "free" => L.T("免费版", "Free"), "pro" => L.T("专业版", "Pro"), "unlimited" => L.T("不限量", "Unlimited"), var other => other };
            static string Size(long bytes) => bytes >= 1L << 30 ? $"{bytes / (double)(1L << 30):0.#} GB" : $"{bytes / 1048576d:0.#} MB";
            minutesMeter.Set(L.T($"{usage.MinutesUsed:0.#} / {(usage.UnlimitedMinutes ? "不限" : $"{usage.MinutesCap:0.#}")} 分钟", $"{usage.MinutesUsed:0.#} / {(usage.UnlimitedMinutes ? "unlimited" : $"{usage.MinutesCap:0.#}")} min"), usage.MinutesPercent, usage.UnlimitedMinutes, !usage.UnlimitedMinutes && usage.IsOverMinutes);
            storageMeter.Set($"{Size(usage.StorageBytes)} / {(usage.UnlimitedStorage ? L.T("不限", "unlimited") : Size(usage.StorageCapBytes))}", usage.StoragePercent, usage.UnlimitedStorage, !usage.UnlimitedStorage && usage.IsOverStorage);
            resets.Text = usage.PeriodEnd is { } end && end > DateTimeOffset.Now && !(usage.UnlimitedMinutes && usage.UnlimitedStorage) ? L.T($"额度将于 {L.MonthDay(end.ToLocalTime().DateTime)} 重置", $"Resets {L.MonthDay(end.ToLocalTime().DateTime)}") : "";
            billing.Text = usage.OverLimit ? L.T("已超出套餐额度，新的录音将无法上传处理。", "You're over your plan's limits. New recordings can't be uploaded or processed.") : "";
            billing.Visibility = billing.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
            minutesMeter.Root.Visibility = storageMeter.Root.Visibility = Visibility.Visible;
            resets.Visibility = resets.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        }
        catch (Exception) when (!closed)
        {
            usageFor = null;
            billing.Text = L.T("暂时无法读取用量，稍后重新打开账号窗口再试。", "Couldn't load usage. Reopen the Account window later to try again.");
        }
    }
    private void Render()
    {
        var value = app.Account.Snapshot;
        // Name first when the account has one, with the email beside the connection state.
        var hasName = !string.IsNullOrWhiteSpace(value.Account?.Name);
        identity.Text = hasName ? value.Account!.Name! : value.Account?.Email ?? L.T("尚未登录", "Not signed in");
        RenderPicture(value.Account?.Image);
        initial.Text = value.Account?.Email is { Length: > 0 } email ? email[..1].ToUpperInvariant() : "?";
        state.Text = (hasName && value.Account?.Email is { } shown ? shown + " · " : "") + (value.Message ?? value.State switch { AccountState.SignedIn => L.T("已连接 Recappi Cloud", "Connected to Recappi Cloud"), AccountState.SigningIn => L.T("等待浏览器确认…", "Waiting for browser confirmation…"), AccountState.Checking => L.T("正在检查连接…", "Checking connection…"), AccountState.Offline => L.T("云端暂时不可用，本地录音可继续。", "Cloud is unavailable. You can keep recording on this PC."), AccountState.Expired => L.T("登录已过期。", "Sign-in expired."), _ => L.T("可以先使用本地录音。", "You can record on this PC for now.") });
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
    private void RenderPicture(string? url)
    {
        if (url == pictureUrl) return;
        pictureUrl = url;
        if (Uri.TryCreate(url, UriKind.Absolute, out var uri) && uri.Scheme == Uri.UriSchemeHttps)
        {
            var image = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage(uri) { DecodePixelWidth = 96 };
            image.ImageOpened += (_, _) => { picture.Visibility = Visibility.Visible; initial.Visibility = Visibility.Collapsed; };
            image.ImageFailed += (_, _) => { picture.Visibility = Visibility.Collapsed; initial.Visibility = Visibility.Visible; };
            picture.Fill = new Microsoft.UI.Xaml.Media.ImageBrush { ImageSource = image, Stretch = Microsoft.UI.Xaml.Media.Stretch.UniformToFill };
        }
        else { picture.Visibility = Visibility.Collapsed; initial.Visibility = Visibility.Visible; }
    }
    private static void Open(Uri uri) => Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
}
