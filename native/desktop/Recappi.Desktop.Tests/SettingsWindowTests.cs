using System.IO;
using System.Windows;
using System.Windows.Controls;
using Recappi.Core;
using Recappi.Desktop;

internal static class SettingsWindowTests
{
    public static async Task RunAsync(string root)
    {
        var store = new PreferencesStore(Path.Combine(root, "ui-preferences"));
        var rejectSave = false;
        void Save(DesktopPreferences value) { if (rejectSave) throw new IOException("test failure"); store.Save(value); }
        var window = new SettingsWindow(new(), Save, () => { }, current: store.Load) { ShowActivated = false }; window.Show(); window.UpdateLayout();
        ((TextBox)window.FindName("TranscriptionLanguage")).Text = "zh";
        ((TextBox)window.FindName("CaptionLanguage")).Text = "zh-CN";
        ((TextBox)window.FindName("TranslationLanguage")).Text = "en";
        ((TextBox)window.FindName("ExtraContext")).Text = "Test names";
        ((ComboBox)window.FindName("Scene")).SelectedValue = "podcast";
        ((CheckBox)window.FindName("AutoUpload")).IsChecked = false;
        ((TextBox)window.FindName("LongReminderMinutes")).Text = "30";
        ((TextBox)window.FindName("MaxDurationMinutes")).Text = "120";
        await Task.Delay(500);
        var saved = store.Load();
        if (saved.OnboardingCompleted || saved.AutoUpload || saved.CaptionLanguage != "zh-CN" || !saved.Processing.Prompt!.Contains("episode summary")) throw new Exception("Settings fields were not persisted/applied or settings completed onboarding.");
        if (saved.Attention.LongReminderSeconds != 1800 || saved.Attention.MaxDurationSeconds != 7200) throw new Exception("Reminder minutes were not converted to seconds.");
        ((TextBox)window.FindName("CaptionLanguage")).Text = "invalid language";
        await Task.Delay(500);
        if (store.Load() != saved || ((Button)window.FindName("SaveButton")).Visibility != Visibility.Visible) throw new Exception("Invalid language was silently persisted.");
        window.Close();
        if (!window.IsVisible) throw new Exception("Invalid pending edits were silently discarded on close.");
        store.Save(saved with { SourceId = "process:123", CaptionLanguage = "de", OnboardingCompleted = true, OnboardingStep = 3 });
        ((ComboBox)window.FindName("Theme")).SelectedValue = "dark";
        if (store.Load().Theme != "dark" || store.Load().SourceId != "process:123" || store.Load().CaptionLanguage != "de" || !store.Load().OnboardingCompleted)
            throw new Exception("Immediate save overwrote another window or invalid text blocked a valid theme change.");
        ((TextBox)window.FindName("CaptionLanguage")).Text = "fr";
        await Task.Delay(500);
        if (store.Load().CaptionLanguage != "fr" || ((Button)window.FindName("SaveButton")).Visibility != Visibility.Collapsed) throw new Exception("Corrected field did not autosave.");
        rejectSave = true;
        ((CheckBox)window.FindName("AutoUpload")).IsChecked = true;
        if (store.Load().AutoUpload || ((Button)window.FindName("SaveButton")).Visibility != Visibility.Visible) throw new Exception("Failed write reported success.");
        rejectSave = false;
        ((Button)window.FindName("SaveButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        if (!store.Load().AutoUpload) throw new Exception("Retry failed to persist pending edit.");
        ((TextBox)window.FindName("ExtraContext")).Text = "Saved on close";
        window.Close();
        if (window.IsVisible || store.Load().ExtraContext != "Saved on close") throw new Exception("Closing before debounce lost the final input.");
        await RecoveryAsync(root);
        Console.WriteLine("PASS native settings autosave, validation, retry, closing flush and preservation of concurrent source/onboarding changes.");
    }

    private static async Task RecoveryAsync(string root)
    {
        var directory = Path.Combine(root, "settings-recovery-ui");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "settings.json");
        File.WriteAllText(path, "{incomplete");
        var original = File.ReadAllBytes(path);
        var store = new PreferencesStore(directory);
        var result = store.LoadForStartup();
        var applied = result.Preferences;
        var saves = 0;
        SettingsWindow Open() => new(applied, value => { store.Save(value); applied = value; saves++; }, () => { }, current: () => applied) { ShowActivated = false };
        var untouched = Open();
        untouched.Show(); untouched.UpdateLayout();
        foreach (var name in new[] { "AutoUpload", "AutoTranscribe", "CaptionsEnabled", "IncludeMicrophone", "RecordingSuggestions" })
            if (((CheckBox)untouched.FindName(name)).IsChecked != false) throw new Exception("Recovery UI enabled " + name);
        await Task.Delay(450);
        untouched.Close();
        if (saves != 0 || !original.SequenceEqual(File.ReadAllBytes(path)))
            throw new Exception("Opening or closing recovery settings silently replaced the unreadable file.");
        var edited = Open();
        edited.Show(); edited.UpdateLayout();
        ((ComboBox)edited.FindName("Theme")).SelectedValue = "dark";
        var persisted = store.LoadForStartup();
        if (persisted.RecoveryRequired || persisted.Preferences.AutoUpload || persisted.Preferences.IncludeMicrophone || persisted.Preferences.Theme != "dark")
            throw new Exception("Changing appearance in recovery re-enabled capture or cloud upload.");
        ((CheckBox)edited.FindName("IncludeMicrophone")).IsChecked = true;
        ((CheckBox)edited.FindName("AutoUpload")).IsChecked = true;
        edited.Close();
        if (!store.Load().IncludeMicrophone || !store.Load().AutoUpload || store.Load().CaptionsEnabled)
            throw new Exception("Explicit recovery settings did not persist independently.");
        Console.WriteLine("PASS recovery settings display disabled capture/cloud defaults, preserve corrupt bytes until editing and allow explicit opt-in.");
    }
}
