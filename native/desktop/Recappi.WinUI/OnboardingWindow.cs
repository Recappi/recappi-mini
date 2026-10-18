using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Recappi.Core;

namespace Recappi.WinUI;

internal sealed class OnboardingWindow : DesktopWindow
{
    private readonly IDesktopHost app;
    private readonly TextBlock step = Ui.Text("", 14);
    private readonly TextBlock title = Ui.Text("", 26);
    private readonly TextBlock message = Ui.Text("");
    private readonly StackPanel actions = new() { Spacing = 8, Orientation = Orientation.Horizontal };
    private readonly StackPanel dots = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
    private readonly FontIcon illustration = new() { FontSize = 26 };
    private readonly Button back;
    private readonly Button next;
    private int index;
    public OnboardingWindow(IDesktopHost app) : base("Recappi Mini · 使用引导", 560, 450)
    {
        this.app = app; index = Math.Clamp(app.Preferences.OnboardingStep, 0, 3);
        // Step: illustration tile · title · explanation · optional action, with paging at the bottom.
        Body.Padding = new Thickness(36, 16, 36, 28); Body.Spacing = 12;
        Error.Style = RecappiTheme.Style("RecappiError"); Error.FontSize = 12;
        var tile = new Border { Width = 60, Height = 60, CornerRadius = new CornerRadius(16), Child = illustration, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 8, 0, 8) };
        RecappiTheme.Bind(tile, "RecappiAccentChipFill", brush => tile.Background = brush);
        illustration.Style = RecappiTheme.Style("RecappiIconAccent");
        step.Style = RecappiTheme.Style("RecappiEyebrow");
        title.Style = RecappiTheme.Style("RecappiPageTitle"); title.FontSize = 24;
        message.Style = RecappiTheme.Style("RecappiBody"); message.FontSize = 14; message.MaxWidth = 460; message.HorizontalAlignment = HorizontalAlignment.Left;
        Body.Children.Add(tile); Body.Children.Add(step); Body.Children.Add(title); Body.Children.Add(message); Body.Children.Add(actions);
        back = Ui.Button("上一步", () => Move(-1), this); next = Ui.Button("下一步", () => Move(1), this);
        back.Style = RecappiTheme.Style("RecappiSubtleButton"); next.Style = RecappiTheme.Style("RecappiPrimaryButton");
        var paging = new Grid { Margin = new Thickness(0, 24, 0, 0) };
        paging.ColumnDefinitions.Add(new ColumnDefinition()); paging.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        dots.VerticalAlignment = VerticalAlignment.Center; paging.Children.Add(dots);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 }; buttons.Children.Add(back); buttons.Children.Add(next);
        Grid.SetColumn(buttons, 1); paging.Children.Add(buttons);
        Body.Children.Add(paging);
        Content = PageFrame((UIElement)Content, "使用引导");
        Render();
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
        illustration.Glyph = new[] { "\uE767", "\uE720", "\uE753", "\uE7C8" }[index];
        dots.Children.Clear();
        for (var i = 0; i < 4; i++)
        {
            var dot = new Border { Height = 6, Width = i == index ? 18 : 6, CornerRadius = new CornerRadius(3) };
            RecappiTheme.Bind(dot, i == index ? "RecappiAccent" : "RecappiBorderSubtle", brush => dot.Background = brush);
            dots.Children.Add(dot);
        }
        title.Text = new[] { "录制应用与系统声音", "选择麦克风", "连接云端", "准备好开始录音" }[index];
        message.Text = new[]
        {
            "选择某个应用可以只录制该应用的声音；选择系统声音会录制所有应用。关闭面板后，录音仍会继续，可从系统托盘恢复。",
            "麦克风可以与应用声音一起录制，也可以单独录制。录音中可随时关闭或重新开启麦克风。",
            "登录后可上传录音、转写、生成摘要和使用实时字幕。也可以跳过登录，先使用本地录音。",
            "开始录音后，停止并保存会将音频写入本机录音库。丢弃需要确认；退出时会先确认保存正在进行的录音。"
        }[index];
        actions.Children.Clear();
        if (index == 1) actions.Children.Add(Ui.Button("查看 Windows 麦克风权限", () => { Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true }); return Task.CompletedTask; }, this));
        if (index == 2) actions.Children.Add(Ui.Button("连接账号", () => { app.ShowAccount(); return Task.CompletedTask; }, this));
        back.IsEnabled = index > 0; next.Content = index == 2 ? "稍后登录 / 下一步" : index == 3 ? "开始使用" : "下一步";
    }
}
