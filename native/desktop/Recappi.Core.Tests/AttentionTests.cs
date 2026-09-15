using Recappi.Core;

internal static class AttentionTests
{
    public static Task RunAsync()
    {
        var policy = new RecordingAttention();
        var tree = new Dictionary<int, (int Parent, string Executable)> { [11] = (10, "chrome.exe"), [10] = (1, "chrome.exe"), [1] = (0, "explorer.exe"), [22] = (1, "Recappi Mini.exe") };
        var appSources = AudioActivity.ExpandParents(new HashSet<int> { 11 }, tree, true);
        if (!appSources.SetEquals(new[] { 10 })) throw new Exception("Browser audio suggestion duplicated subprocesses or included unrelated launcher ancestors.");
        if (!AudioActivity.ExpandParents(new HashSet<int> { 22 }, tree, true).SetEquals(new[] { 22 })) throw new Exception("Native playback was attributed to Explorer.");
        if (!AudioActivity.ExpandParents(new HashSet<int> { 11 }, tree, false).Contains(1)) throw new Exception("Recording activity ancestry compatibility changed.");
        var suggestions = new RecordingSuggestion();
        var start = DateTimeOffset.UtcNow;
        AudioSource[] sources = [new("process-12", "Browser audio", 12)];
        if (suggestions.Observe(start, sources, true, false, true) is not null || suggestions.Observe(start.AddSeconds(9), sources, true, false, true) is not null) throw new Exception("Suggestion appeared before debounce.");
        if (suggestions.Observe(start.AddSeconds(10), sources, true, false, true) != sources[0] || suggestions.Observe(start.AddSeconds(15), sources, true, false, true) is not null) throw new Exception("Suggestion did not respect once-per-episode rule.");
        suggestions.Observe(start.AddSeconds(50), [], true, false, true);
        suggestions.Observe(start.AddSeconds(51), sources, true, false, false);
        if (suggestions.Observe(start.AddSeconds(65), sources, true, false, true) is not null) throw new Exception("Hidden panel re-prompted existing activity.");
        suggestions.Observe(start.AddSeconds(100), [], true, false, true);
        suggestions.Observe(start.AddSeconds(101), sources, false, false, true);
        if (suggestions.Observe(start.AddSeconds(112), sources, true, false, true) is not null) throw new Exception("Disabled suggestion reappeared immediately after enabling.");
        var settings = new AttentionSettings(60, false, 300);
        AttentionSnapshot Snapshot(int seconds, bool visible = false, int? source = null, bool active = true, double level = .2, bool known = true) => new(seconds, visible, active ? new HashSet<int> { 12 } : new HashSet<int>(), source, level, known);
        void Expect(AttentionSnapshot snapshot, AttentionSettings options, params AttentionAction[] expected)
        {
            if (!policy.Evaluate(snapshot, options).SequenceEqual(expected)) throw new Exception("Recording attention boundary mismatch at " + snapshot.ElapsedSeconds);
        }
        Expect(Snapshot(59), settings);
        Expect(Snapshot(60, true), settings);
        Expect(Snapshot(61), settings, AttentionAction.LongHiddenRecording);
        Expect(Snapshot(100), settings);
        Expect(Snapshot(121), settings, AttentionAction.LongHiddenRecording);
        Expect(Snapshot(300, true), settings, AttentionAction.DurationLimit);
        Expect(Snapshot(360, true), settings);
        policy.Reset(); settings = new(0, true, 0);
        Expect(Snapshot(180, source: 12, active: false), settings);
        Expect(Snapshot(240, source: 12), settings);
        Expect(Snapshot(260, source: 12, active: false), settings);
        Expect(Snapshot(379, source: 12, active: false), settings);
        Expect(Snapshot(380, source: 12, active: false), settings, AttentionAction.InactiveSource);
        Expect(Snapshot(600, source: 12, active: false), settings);
        policy.Reset();
        Expect(Snapshot(180, active: false, level: 0), settings);
        Expect(Snapshot(300, active: true, level: 0), settings);
        Expect(Snapshot(320, active: false, level: 0), settings);
        Expect(Snapshot(500, active: false, level: 0), settings, AttentionAction.InactiveSource);
        policy.Reset();
        Expect(Snapshot(180, active: false, level: 0), settings);
        Expect(Snapshot(400, active: false, level: 0, known: false), settings);
        Expect(Snapshot(410, active: false, level: 0), settings);
        Expect(Snapshot(590, active: false, level: 0), settings, AttentionAction.InactiveSource);
        var activity = AudioActivity.ActiveProcessIds();
        if (activity.Any(id => id <= 0)) throw new Exception("Native activity enumeration returned invalid process IDs.");
        return Task.CompletedTask;
    }
}
