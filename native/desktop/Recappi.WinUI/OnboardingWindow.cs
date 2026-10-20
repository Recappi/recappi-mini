using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Recappi.Core;

namespace Recappi.WinUI;

// Onboarding, laid out like the macOS window: a centered step above a footer band
// holding Back, the step dots and the primary action.
internal sealed class OnboardingWindow : DesktopWindow
{
    private readonly IDesktopHost app;
    private readonly TextBlock step = Ui.Text("", 14);
    private readonly TextBlock title = Ui.Text("", 26);
    private readonly TextBlock message = Ui.Text("");
    private readonly StackPanel stage = new() { Spacing = 18, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel dots = new() { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
    private readonly StackPanel copy = new() { Spacing = 8 };
    private readonly Button back;
    private readonly Button next;
    private int index;
    public OnboardingWindow(IDesktopHost app) : base(L.T("Recappi Mini · 使用引导", "Recappi Mini · Welcome"), 540, 472)
    {
        this.app = app; index = Math.Clamp(app.Preferences.OnboardingStep, 0, 3);
        Error.Style = RecappiTheme.Style("RecappiError"); Error.FontSize = 12;
        step.Style = RecappiTheme.Style("RecappiCaption"); step.HorizontalAlignment = HorizontalAlignment.Center;
        title.Style = RecappiTheme.Style("RecappiPageTitle"); title.FontSize = 22;
        message.Style = RecappiTheme.Style("RecappiBodySecondary"); message.FontSize = 12.5; message.MaxWidth = 380; message.LineHeight = 19;
        copy.Children.Add(title); copy.Children.Add(message);
        back = Ui.Button(L.T("上一步", "Back"), () => Move(-1), this); next = Ui.Button(L.T("下一步", "Next"), () => Move(1), this);
        back.Style = RecappiTheme.Style("RecappiSubtleButton"); next.Style = RecappiTheme.Style("RecappiPrimaryButton");
        foreach (var button in new[] { back, next }) { button.MinHeight = 28; button.FontSize = 12; }
        back.Content = Labeled("", L.T("上一步", "Back")); back.HorizontalAlignment = HorizontalAlignment.Left;
        next.HorizontalAlignment = HorizontalAlignment.Right; next.MinWidth = 120;

        ((ScrollViewer)Content).Content = null;
        var layout = new Grid();
        layout.RowDefinitions.Add(new RowDefinition()); layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Body.Padding = new Thickness(32, 0, 32, 16); Body.VerticalAlignment = VerticalAlignment.Center;
        Body.Children.Add(stage);
        layout.Children.Add(Body);
        var footer = new Grid { Padding = new Thickness(24, 14, 24, 14), BorderThickness = new Thickness(0, 1, 0, 0) };
        RecappiTheme.Bind(footer, "RecappiCardSubtleActive", brush => footer.Background = brush);
        RecappiTheme.Bind(footer, "RecappiBorderHairline", brush => footer.BorderBrush = brush);
        foreach (var width in new[] { new GridLength(160), new GridLength(1, GridUnitType.Star), new GridLength(160) }) footer.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        footer.Children.Add(back); Grid.SetColumn(dots, 1); footer.Children.Add(dots); Grid.SetColumn(next, 2); footer.Children.Add(next);
        Grid.SetRow(footer, 1); layout.Children.Add(footer);
        Content = PageFrame(layout, L.T("使用引导", "Welcome"));
        Render();
    }
    private static StackPanel Labeled(string glyph, string text)
    {
        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        content.Children.Add(RecappiTheme.Glyph(glyph, 10)); content.Children.Add(new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center });
        return content;
    }
    public void Restart() { index = 0; app.SavePreferences(app.Preferences with { OnboardingStep = 0, OnboardingCompleted = false }); Render(); }
    private Task Move(int delta)
    {
        var nextStep = index + delta;
        app.SavePreferences(app.Preferences with { OnboardingStep = Math.Clamp(nextStep, 0, 3), OnboardingCompleted = nextStep > 3 });
        if (nextStep > 3) Close(); else { index = nextStep; Render(); }
        return Task.CompletedTask;
    }
    private void Render()
    {
        // The four macOS steps: welcome, permissions, cloud sign-in, done.
        step.Text = "";
        title.Text = new[] { L.T("欢迎使用 Recappi Mini", "Welcome to Recappi Mini"), L.T("授予权限", "Grant permissions"), L.T("登录 Recappi Cloud", "Sign in to Recappi Cloud"), L.T("一切就绪", "You're all set") }[index];
        message.Text = new[]
        {
            "",
            L.T("Recappi 需要麦克风权限来录下你的声音；应用和系统声音无需额外授权。随时可以在 Windows 设置中撤销。", "Recappi needs microphone access to record your voice. App and system audio need no extra permission. You can revoke it anytime in Windows Settings."),
            L.T("云端会保存逐字稿、摘要和音频，并在设备间同步。也可以先跳过，稍后再登录。", "Cloud keeps your transcripts, summaries and audio, and syncs them across devices. You can skip this and sign in later."),
            L.T("从录音条或系统托盘开始录音，或打开录音库浏览云端内容。", "Start recording from the recording bar or the system tray, or open the Library to browse Cloud content.")
        }[index];
        stage.Children.Clear();
        var centered = index != 1;
        stage.HorizontalAlignment = centered ? HorizontalAlignment.Center : HorizontalAlignment.Stretch;
        foreach (var text in new[] { title, message }) { text.HorizontalAlignment = centered ? HorizontalAlignment.Center : HorizontalAlignment.Left; text.TextAlignment = centered ? TextAlignment.Center : TextAlignment.Left; }
        title.FontSize = index == 2 ? 20 : 22;
        message.Visibility = message.Text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (index == 3)
        {
            var done = RecappiTheme.Glyph("\uE930", 44); done.Style = RecappiTheme.Style("RecappiIconAccent"); done.HorizontalAlignment = HorizontalAlignment.Center;
            stage.Children.Add(done);
        }
        else if (centered)
        {
            var tile = RecappiTheme.LogoTile(72); tile.HorizontalAlignment = HorizontalAlignment.Center; stage.Children.Add(tile);
        }
        stage.Children.Add(copy);
        if (index == 0)
        {
            var bullets = new StackPanel { Spacing = 10, MaxWidth = 380, HorizontalAlignment = HorizontalAlignment.Center };
            foreach (var (glyph, text) in new[] { ("\uE9D9", L.T("一键录制任意应用的声音", "Record any app's audio in one click")), ("\uE8A5", L.T("自动转写并生成会议摘要", "Automatic transcripts and meeting summaries")), ("\uE753", L.T("录音在设备之间同步", "Recordings sync across devices")) })
            {
                var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
                var icon = RecappiTheme.Glyph(glyph, 13); icon.Style = RecappiTheme.Style("RecappiIconAccent"); icon.Width = 18;
                row.Children.Add(icon); row.Children.Add(new TextBlock { Text = text, Style = RecappiTheme.Style("RecappiBody"), FontSize = 13 });
                bullets.Children.Add(row);
            }
            stage.Children.Add(bullets);
        }
        if (index == 1) stage.Children.Add(PermissionCard());
        if (index == 2)
        {
            var connect = Ui.Button(L.T("连接账号", "Connect account"), () => { app.ShowAccount(); return Task.CompletedTask; }, this);
            connect.MinWidth = 180; connect.MinHeight = 30; connect.HorizontalAlignment = HorizontalAlignment.Center;
            stage.Children.Add(connect);
        }
        dots.Children.Clear();
        for (var i = 0; i < 4; i++)
        {
            var dot = new Border { Height = 6, Width = 6, CornerRadius = new CornerRadius(3) };
            RecappiTheme.Bind(dot, i == index ? "RecappiAccent" : "RecappiBorderSubtle", brush => dot.Background = brush);
            dots.Children.Add(dot);
        }
        back.Visibility = index > 0 ? Visibility.Visible : Visibility.Collapsed;
        back.IsEnabled = index > 0;
        next.Content = index == 2 ? L.T("稍后再说", "Not now") : index == 3 ? L.T("开始使用", "Get started") : L.T("继续", "Continue");
        next.Style = RecappiTheme.Style(index == 2 ? "RecappiButton" : "RecappiPrimaryButton");
        next.MinHeight = 28; next.FontSize = 12; next.MinWidth = 140; next.HorizontalAlignment = HorizontalAlignment.Right;
    }
    private Grid PermissionCard()
    {
        var card = new Grid { ColumnSpacing = 12, Padding = new Thickness(12, 10, 12, 10), CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1) };
        RecappiTheme.Bind(card, "RecappiControlHover", brush => card.Background = brush);
        RecappiTheme.Bind(card, "RecappiBorderHairline", brush => card.BorderBrush = brush);
        foreach (var width in new[] { GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto }) card.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
        var glyph = RecappiTheme.Glyph("\uE7BA", 18); glyph.Style = RecappiTheme.Style("RecappiIconWarning"); glyph.Width = 22; glyph.VerticalAlignment = VerticalAlignment.Center;
        card.Children.Add(glyph);
        var text = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(new TextBlock { Text = L.T("麦克风", "Microphone"), Style = RecappiTheme.Style("RecappiBody"), FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.Medium });
        text.Children.Add(new TextBlock { Text = L.T("录下你在会议和讲解中的声音。", "Records your voice in meetings and talks."), Style = RecappiTheme.Style("RecappiBodySecondary"), FontSize = 11.5 });
        Grid.SetColumn(text, 1); card.Children.Add(text);
        var open = Ui.Button(L.T("打开设置", "Open Settings"), () => { Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true }); return Task.CompletedTask; }, this);
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(open, L.T("查看 Windows 麦克风权限", "View Windows microphone access"));
        open.MinHeight = 28; open.FontSize = 12; open.MinWidth = 120; open.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(open, 2); card.Children.Add(open);
        return card;
    }
}
