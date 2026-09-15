using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Microsoft.Win32;
using Recappi.Core;

namespace Recappi.Desktop;

public partial class SettingsWindow : Window
{
    private DesktopPreferences lastSaved;
    private readonly Func<DesktopPreferences> current;
    private readonly Dictionary<Control, Func<DesktopPreferences, DesktopPreferences>> edits = new();
    private readonly HashSet<Control> pending = new();
    private readonly DispatcherTimer editTimer = new() { Interval = TimeSpan.FromMilliseconds(350) };
    private readonly Action<DesktopPreferences> save;
    private readonly Action showAccount;
    private readonly Action? restartOnboarding;
    public SettingsWindow(DesktopPreferences preferences, Action<DesktopPreferences> save, Action showAccount, string? message = null, Action? restartOnboarding = null, Func<DesktopPreferences>? current = null)
    {
        DesktopTheme.EnsureResources();
        InitializeComponent(); lastSaved = preferences; this.current = current ?? (() => lastSaved); this.save = save; this.showAccount = showAccount;
        this.restartOnboarding = restartOnboarding;
        RestartOnboardingButton.IsEnabled = restartOnboarding is not null;
        Theme.SelectedValue = preferences.Theme;
        RecordingSuggestions.IsChecked = preferences.RecordingSuggestions;
        About.Text = $"版本 {UpdatePanel.CurrentVersion} · {System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture}\nWindows 原生桌面版\n本地录音保存在所选目录；云处理需要登录账号。";
        AutoUpload.IsChecked = preferences.AutoUpload; AutoTranscribe.IsChecked = preferences.AutoTranscribe;
        CaptionsEnabled.IsChecked = preferences.CaptionsEnabled; IncludeMicrophone.IsChecked = preferences.IncludeMicrophone;
        TranscriptionLanguage.Text = preferences.TranscriptionLanguage; CaptionLanguage.Text = preferences.CaptionLanguage; TranslationLanguage.Text = preferences.TranslationLanguage;
        Scene.SelectedValue = preferences.Scene; ExtraContext.Text = preferences.ExtraContext; RecordingsRoot.Text = preferences.RecordingsRoot;
        InactivityReminders.IsChecked = preferences.InactivityReminders; LongReminderMinutes.Text = preferences.LongReminderMinutes.ToString(); MaxDurationMinutes.Text = preferences.MaxDurationMinutes.ToString();
        if (message is not null) Status.Text = message;
        Register(Theme, p => p with { Theme = Theme.SelectedValue as string ?? "system" });
        Register(Scene, p => p with { Scene = Scene.SelectedValue as string ?? "meeting" });
        Register(RecordingSuggestions, p => p with { RecordingSuggestions = RecordingSuggestions.IsChecked == true });
        Register(InactivityReminders, p => p with { InactivityReminders = InactivityReminders.IsChecked == true });
        Register(AutoUpload, p => p with { AutoUpload = AutoUpload.IsChecked == true });
        Register(AutoTranscribe, p => p with { AutoTranscribe = AutoTranscribe.IsChecked == true });
        Register(CaptionsEnabled, p => p with { CaptionsEnabled = CaptionsEnabled.IsChecked == true });
        Register(IncludeMicrophone, p => p with { IncludeMicrophone = IncludeMicrophone.IsChecked == true });
        Register(TranscriptionLanguage, p => p with { TranscriptionLanguage = TranscriptionLanguage.Text.Trim() });
        Register(CaptionLanguage, p => p with { CaptionLanguage = CaptionLanguage.Text.Trim() });
        Register(TranslationLanguage, p => p with { TranslationLanguage = TranslationLanguage.Text.Trim() });
        Register(ExtraContext, p => p with { ExtraContext = ExtraContext.Text });
        Register(RecordingsRoot, p => p with { RecordingsRoot = RecordingsRoot.Text.Trim() });
        Register(LongReminderMinutes, p => p with { LongReminderMinutes = Minutes(LongReminderMinutes.Text) });
        Register(MaxDurationMinutes, p => p with { MaxDurationMinutes = Minutes(MaxDurationMinutes.Text) });
        editTimer.Tick += (_, _) => FlushEdits();
        Closing += (_, e) => { if (!FlushEdits()) e.Cancel = true; };
        Closed += (_, _) => editTimer.Stop();
    }
    private static int Minutes(string text) => int.TryParse(text, out var value) ? value : throw new ArgumentException("提醒时间请填写整数分钟。");
    private void Register(Control control, Func<DesktopPreferences, DesktopPreferences> edit)
    {
        edits.Add(control, edit);
        void Changed(bool immediate)
        {
            pending.Add(control);
            if (immediate) FlushEdits();
            else { editTimer.Stop(); editTimer.Start(); }
        }
        if (control is TextBox text) text.TextChanged += (_, _) => Changed(false);
        else if (control is ComboBox combo) combo.SelectionChanged += (_, _) => Changed(true);
        else if (control is CheckBox toggle)
        {
            toggle.Checked += (_, _) => Changed(true);
            toggle.Unchecked += (_, _) => Changed(true);
        }
    }
    private bool FlushEdits()
    {
        editTimer.Stop();
        if (pending.Count == 0) return true;
        string? errorMessage = null;
        foreach (var control in pending.ToArray())
        {
            try
            {
                var value = edits[control](current()).Validate();
                save(value); lastSaved = value; pending.Remove(control);
            }
            catch (Exception error)
            {
                errorMessage ??= error is ArgumentException ? error.Message : "无法保存设置，请检查目录权限后重试。";
            }
        }
        Status.Text = errorMessage ?? "设置已自动保存。";
        SaveButton.Visibility = pending.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        DiscardEditsButton.Visibility = SaveButton.Visibility;
        return pending.Count == 0;
    }
    private void Save(object sender, RoutedEventArgs e) => FlushEdits();
    private void DiscardEdits(object sender, RoutedEventArgs e) { editTimer.Stop(); pending.Clear(); Close(); }
    private void Browse(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "选择本地录音目录" };
        if (dialog.ShowDialog(this) == true) RecordingsRoot.Text = dialog.FolderName;
    }
    private void MicrophonePrivacy(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo("ms-settings:privacy-microphone") { UseShellExecute = true }); }
        catch (Exception) { Status.Text = "无法打开设置。请在 Windows 设置中搜索“麦克风隐私”。"; }
    }
    private void Account(object sender, RoutedEventArgs e) => showAccount();
    private void RestartOnboarding(object sender, RoutedEventArgs e)
    {
        try { restartOnboarding?.Invoke(); }
        catch { Status.Text = "无法重启引导，请检查设置目录权限后重试。"; }
    }
    private void Cancel(object sender, RoutedEventArgs e) => Close();
}
