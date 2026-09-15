using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using Recappi.Core;

namespace Recappi.Desktop;

public partial class OnboardingWindow : Window
{
    private readonly Func<DesktopPreferences> current;
    private readonly Action<DesktopPreferences> save;
    private readonly Action showAccount;
    private readonly Func<bool> quitting;
    private readonly AccountSession? session;
    private int step;
    private bool completed;
    public OnboardingWindow(Func<DesktopPreferences> current, Action<DesktopPreferences> save,
        Action showAccount, AccountSession? session = null, Func<bool>? quitting = null)
    {
        DesktopTheme.EnsureResources();
        InitializeComponent();
        this.current = current; this.save = save; this.showAccount = showAccount;
        this.session = session; this.quitting = quitting ?? (() => false);
        step = Math.Clamp(current().OnboardingStep, 0, 3);
        if (session is not null) session.Changed += AccountChanged;
        Closing += CompleteOnClose;
        Closed += (_, _) => { if (session is not null) session.Changed -= AccountChanged; };
        Render();
    }
    private void AccountChanged(AccountSnapshot value) => Dispatcher.BeginInvoke(() =>
    {
        if (!completed && IsVisible && step == 2 && session?.Snapshot.State == AccountState.SignedIn) Advance(3);
    });
    private void Render()
    {
        WelcomePage.Visibility = step == 0 ? Visibility.Visible : Visibility.Collapsed;
        PermissionsPage.Visibility = step == 1 ? Visibility.Visible : Visibility.Collapsed;
        SignInPage.Visibility = step == 2 ? Visibility.Visible : Visibility.Collapsed;
        DonePage.Visibility = step == 3 ? Visibility.Visible : Visibility.Collapsed;
        BackButton.Visibility = step == 0 ? Visibility.Hidden : Visibility.Visible;
        NextButton.Content = step == 2 ? "稍后再说" : step == 3 ? "开始使用" : "继续";
        Progress.Text = $"{step + 1} / 4";
    }
    private void Advance(int next)
    {
        try
        {
            save(current() with { OnboardingStep = next, OnboardingCompleted = false });
            step = next; Status.Text = ""; Render();
        }
        catch { Status.Text = "无法保存引导进度，请检查设置目录权限后重试。"; }
    }
    public void Restart() => Advance(0);
    private void Back(object sender, RoutedEventArgs e) { if (step > 0) Advance(step - 1); }
    private void Next(object sender, RoutedEventArgs e)
    {
        if (step == 3) Close();
        else Advance(step == 1 && session?.Snapshot.State == AccountState.SignedIn ? 3 : step + 1);
    }
    private void CompleteOnClose(object? sender, CancelEventArgs e)
    {
        if (quitting()) return;
        try { save(current() with { OnboardingStep = step, OnboardingCompleted = true }); completed = true; }
        catch { e.Cancel = true; Status.Text = "无法保存引导进度，请检查设置目录权限后重试。"; }
    }
    private void SignIn(object sender, RoutedEventArgs e) => showAccount();
    private void MicrophonePrivacy(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true }); }
        catch { Status.Text = "无法打开设置。请在 Windows 设置中搜索“麦克风隐私”。"; }
    }
}
