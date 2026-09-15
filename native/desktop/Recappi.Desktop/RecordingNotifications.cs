using System;
using System.Linq;
using System.Threading.Tasks;
using Recappi.Core;
using Forms = System.Windows.Forms;

namespace Recappi.Desktop;

/// <summary>Bind suggestion selection to the currently presented balloon only.</summary>
public sealed class RecordingNotifications(RecorderViewModel recorder, Action showRecorder,
    Action<int, string, string, Forms.ToolTipIcon> showBalloon)
{
    private AudioSource? pendingSuggestion;
    private long revision;

    public void ClearSuggestion() { pendingSuggestion = null; revision++; }

    public void Show(int timeout, string title, string message, Forms.ToolTipIcon icon, AudioSource? suggestion = null)
    {
        ClearSuggestion();
        pendingSuggestion = suggestion;
        try { showBalloon(timeout, title, message, icon); }
        catch { ClearSuggestion(); throw; }
    }

    public async Task HandleClickAsync()
    {
        var candidate = pendingSuggestion;
        ClearSuggestion();
        var request = revision;
        showRecorder();
        if (candidate is null || !recorder.CanConfigure) return;
        await recorder.RefreshDevicesAsync();
        // RefreshDevicesAsync reports failures in the recorder instead of throwing.
        if (revision != request || !recorder.CanConfigure || recorder.Error is not null) return;
        var current = recorder.Sources.FirstOrDefault(source => source.Id == candidate.Id);
        if (current is not null) recorder.SelectSuggestedSource(current);
    }
}
