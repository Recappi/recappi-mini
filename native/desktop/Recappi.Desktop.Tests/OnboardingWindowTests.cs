using System.IO;
using System.Windows;
using System.Windows.Controls;
using Recappi.Core;
using Recappi.Desktop;

internal static class OnboardingWindowTests
{
    public static Task RunAsync(string root)
    {
        var store = new PreferencesStore(Path.Combine(root, "onboarding"));
        var quitting = false;
        var rejectSave = false;
        var loginOpened = 0;
        void Save(DesktopPreferences value)
        {
            if (rejectSave) throw new IOException("test failure");
            store.Save(value);
        }
        OnboardingWindow Open()
        {
            var window = new OnboardingWindow(store.Load, Save, () => loginOpened++, quitting: () => quitting) { ShowActivated = false };
            window.Show(); window.UpdateLayout(); return window;
        }
        static void Click(OnboardingWindow window, string name) => ((Button)window.FindName(name)).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
        var first = Open();
        Click(first, "NextButton");
        if (store.Load().OnboardingStep != 1 || store.Load().OnboardingCompleted) throw new Exception("Permission step did not persist independently of completion.");
        quitting = true; first.Close(); quitting = false;
        var resumed = Open();
        if (((FrameworkElement)resumed.FindName("PermissionsPage")).Visibility != Visibility.Visible) throw new Exception("Onboarding failed to resume after app shutdown.");
        rejectSave = true; Click(resumed, "NextButton");
        if (store.Load().OnboardingStep != 1 || ((FrameworkElement)resumed.FindName("PermissionsPage")).Visibility != Visibility.Visible) throw new Exception("Failed save advanced onboarding.");
        rejectSave = false; Click(resumed, "NextButton"); Click(resumed, "NextButton");
        if (store.Load().OnboardingStep != 3 || store.Load().OnboardingCompleted || loginOpened != 0) throw new Exception("Skip login should reach Done without authenticating or completing early.");
        Click(resumed, "BackButton");
        if (store.Load().OnboardingStep != 2) throw new Exception("Done cannot return to sign-in.");
        // Preserve unrelated preferences changed by another window during the walkthrough.
        store.Save(store.Load() with { Theme = "dark" });
        Click(resumed, "NextButton"); Click(resumed, "NextButton");
        if (resumed.IsVisible || !store.Load().OnboardingCompleted || store.Load().Theme != "dark") throw new Exception("Completion overwrote current settings or failed to close.");
        var restarted = Open(); restarted.Restart();
        if (store.Load().OnboardingCompleted || store.Load().OnboardingStep != 0) throw new Exception("Restart did not reset onboarding.");
        rejectSave = true; restarted.Close();
        if (!restarted.IsVisible || store.Load().OnboardingCompleted) throw new Exception("Failed completion was silently accepted.");
        rejectSave = false; restarted.Close();
        if (!store.Load().OnboardingCompleted) throw new Exception("Title-bar close should dismiss first-launch onboarding.");
        Console.WriteLine("PASS native onboarding navigation, skip, resume, restart, close, save failure and concurrent settings preservation.");
        return Task.CompletedTask;
    }
}
