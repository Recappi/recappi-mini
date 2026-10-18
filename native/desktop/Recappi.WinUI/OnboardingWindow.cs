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
    public OnboardingWindow(IDesktopHost app) : base("Recappi Mini · 使用引导", 540, 440)
    {
        this.app = app; index = Math.Clamp(app.Preferences.OnboardingStep, 0, 3);
        Error.Style = RecappiTheme.Style("RecappiError"); Error.FontSize = 12;
        step.Style = RecappiTheme.Style("RecappiCaption"); step.HorizontalAlignment = HorizontalAlignment.Center;
        title.Style = RecappiTheme.Style("RecappiPageTitle"); title.FontSize = 22;
        message.Style = RecappiTheme.Style("RecappiBodySecondary"); message.FontSize = 12.5; message.MaxWidth = 380; message.LineHeight = 19;
        copy.Children.Add(title); copy.Children.Add(message);
        back = Ui.Button("上一步", () => Move(-1), this); next = Ui.Button("下一步", () => Move(1), this);
        back.Style = RecappiTheme.Style("RecappiSubtleButton"); next.Style = RecappiTheme.Style("RecappiPrimaryButton");
        foreach (var button in new[] { back, next }) { button.MinHeight = 28; button.FontSize = 12; }
        back.Content = Labeled("", "上一步"); back.HorizontalAlignment = HorizontalAlignment.Left;
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
        Content = PageFrame(layout, "使用引导");
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
        step.Text = $"第 {index + 1} 步，共 4 步";
        title.Text = new[] { "录制应用与系统声音", "选择麦克风", "连接云端", "准备好开始录音" }[index];
        message.Text = new[]
        {
            "选择某个应用可以只录制该应用的声音；选择系统声音会录制所有应用。关闭面板后，录音仍会继续，可从系统托盘恢复。",
            "麦克风可以与应用声音一起录制，也可以单独录制。录音中可随时关闭或重新开启麦克风。",
            "登录后可上传录音、转写、生成摘要和使用实时字幕。也可以跳过登录，先使用本地录音。",
            "开始录音后，停止并保存会将音频写入本机录音库。丢弃需要确认；退出时会先确认保存正在进行的录音。"
        }[index];
        stage.Children.Clear();
        // Steps 1, 3 and 4 are centered like the macOS welcome/sign-in/done steps; step 2 is a left-aligned permission card.
        var centered = index != 1;
        stage.HorizontalAlignment = centered ? HorizontalAlignment.Center : HorizontalAlignment.Stretch;
        foreach (var text in new[] { title, message }) { text.HorizontalAlignment = centered ? HorizontalAlignment.Center : HorizontalAlignment.Left; text.TextAlignment = centered ? TextAlignment.Center : TextAlignment.Left; }
        if (index == 3)
        {
            var done = RecappiTheme.Glyph("", 44); done.Style = RecappiTheme.Style("RecappiIconAccent"); done.HorizontalAlignment = HorizontalAlignment.Center;
            stage.Children.Add(done);
        }
        else if (centered)
        {
            var tile = RecappiTheme.LogoTile(72); tile.HorizontalAlignment = HorizontalAlignment.Center; stage.Children.Add(tile);
        }
        if (index == 2) title.FontSize = 20; else title.FontSize = 22;
        stage.Children.Add(copy);
        if (index == 1)
        {
            var card = new Grid { ColumnSpacing = 12, Padding = new Thickness(12, 10, 12, 10), CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1) };
            RecappiTheme.Bind(card, "RecappiControlHover", brush => card.Background = brush);
            RecappiTheme.Bind(card, "RecappiBorderHairline", brush => card.BorderBrush = brush);
            foreach (var width in new[] { GridLength.Auto, new GridLength(1, GridUnitType.Star), GridLength.Auto }) card.ColumnDefinitions.Add(new ColumnDefinition { Width = width });
            var glyph = RecappiTheme.Glyph("", 18); glyph.Style = RecappiTheme.Style("RecappiIconAccent"); glyph.Width = 22; glyph.VerticalAlignment = VerticalAlignment.Center;
            card.Children.Add(glyph);
            var text = new StackPanel { Spacing = 3, VerticalAlignment = VerticalAlignment.Center };
            text.Children.Add(new TextBlock { Text = "麦克风", Style = RecappiTheme.Style("RecappiBody"), FontSize = 13, FontWeight = Microsoft.UI.Text.FontWeights.Medium });
            text.Children.Add(new TextBlock { Text = "在 Windows 隐私设置中允许 Recappi 使用麦克风。", Style = RecappiTheme.Style("RecappiBodySecondary"), FontSize = 11.5 });
            Grid.SetColumn(text, 1); card.Children.Add(text);
            var open = Ui.Button("打开设置", () => { Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true }); return Task.CompletedTask; }, this);
            Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(open, "查看 Windows 麦克风权限");
            open.MinHeight = 28; open.FontSize = 12; open.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(open, 2); card.Children.Add(open);
            stage.Children.Add(card);
        }
        if (index == 2)
        {
            var connect = Ui.Button("连接账号", () => { app.ShowAccount(); return Task.CompletedTask; }, this);
            connect.MinWidth = 180; connect.MinHeight = 30; connect.HorizontalAlignment = HorizontalAlignment.Center;
            stage.Children.Add(connect);
        }
        stage.Children.Add(step);
        dots.Children.Clear();
        for (var i = 0; i < 4; i++)
        {
            var dot = new Border { Height = 6, Width = 6, CornerRadius = new CornerRadius(3) };
            RecappiTheme.Bind(dot, i == index ? "RecappiAccent" : "RecappiBorderSubtle", brush => dot.Background = brush);
            dots.Children.Add(dot);
        }
        back.Visibility = index > 0 ? Visibility.Visible : Visibility.Collapsed;
        back.IsEnabled = index > 0;
        next.Content = index == 2 ? "稍后登录 / 下一步" : index == 3 ? "开始使用" : "继续";
        if (index == 2) next.Style = RecappiTheme.Style("RecappiButton"); else next.Style = RecappiTheme.Style("RecappiPrimaryButton");
        next.MinHeight = 28; next.FontSize = 12;
    }
}
