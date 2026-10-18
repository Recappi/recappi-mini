using Recappi.Core;

namespace Recappi.WinUI;

// Keeps windows independent of the Application singleton and makes real WinUI
// controls testable with isolated stores and deterministic audio/network inputs.
internal interface IDesktopHost
{
    RecordingEngine Engine { get; }
    LocalRecordingStore Store { get; }
    AccountSession Account { get; }
    CloudProcessing Processing { get; }
    DesktopPreferences Preferences { get; }
    string ApplicationRoot { get; }
    string Origin { get; }
    void ShowLibrary();
    void ShowRecording(string id);
    void ShowRecorder();
    void ShowAccount();
    void ShowSettings();
    void ShowCaptions();
    void ShowOnboarding(bool restart = false);
    void SavePreferences(DesktopPreferences value);
    void SetRecordingLanguage(string language, string translation);
    Task StartRecording(RecordingOptions options, DesktopPreferences preferences);
    Task StopRecording();
    Task StopCaptions(bool abort = false);
    Task StopCaptionsIfFinished();
    Task Quit();
}
