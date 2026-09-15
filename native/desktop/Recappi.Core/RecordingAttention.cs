using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
using NAudio.CoreAudioApi;

namespace Recappi.Core;

public enum AttentionAction { LongHiddenRecording, InactiveSource, DurationLimit }
public sealed record AttentionSettings(int LongReminderSeconds = 2700, bool InactivityEnabled = true, int MaxDurationSeconds = 0);
public sealed record AttentionSnapshot(int ElapsedSeconds, bool PanelVisible, IReadOnlySet<int> ActiveProcessIds, int? SourceProcessId, double AudioLevel, bool ActivityKnown = true);

public sealed class RecordingAttention
{
    private int? lastLongReminder;
    private (string Key, int Started, int Grace)? candidate;
    private bool inactivityRaised;
    private bool maxRaised;
    public void Reset() { lastLongReminder = null; candidate = null; inactivityRaised = maxRaised = false; }
    public IReadOnlyList<AttentionAction> Evaluate(AttentionSnapshot snapshot, AttentionSettings settings)
    {
        var actions = new List<AttentionAction>(); var elapsed = snapshot.ElapsedSeconds;
        if (elapsed <= 0) return actions;
        if (settings.LongReminderSeconds > 0 && !snapshot.PanelVisible && elapsed >= settings.LongReminderSeconds && (lastLongReminder is null || elapsed - lastLongReminder >= settings.LongReminderSeconds))
        { lastLongReminder = elapsed; actions.Add(AttentionAction.LongHiddenRecording); }
        if (settings.MaxDurationSeconds > 0 && !maxRaised && elapsed >= settings.MaxDurationSeconds)
        { maxRaised = true; actions.Add(AttentionAction.DurationLimit); }
        if (!settings.InactivityEnabled || !snapshot.ActivityKnown) { candidate = null; return actions; }
        if (!inactivityRaised && elapsed >= 180)
        {
            var key = snapshot.SourceProcessId is { } source ? !snapshot.ActiveProcessIds.Contains(source) ? "source:" + source : null : snapshot.ActiveProcessIds.Count == 0 && snapshot.AudioLevel <= .015 ? "quiet" : null;
            if (key is null) candidate = null;
            else if (candidate is { } current && current.Key == key)
            {
                if (elapsed - current.Started >= current.Grace) { inactivityRaised = true; candidate = null; actions.Add(AttentionAction.InactiveSource); }
            }
            else candidate = (key, elapsed, snapshot.SourceProcessId.HasValue ? 120 : 180);
        }
        return actions;
    }
}

public static class AudioActivity
{
    // Include parent processes: browser audio usually belongs to a child process.
    public static IReadOnlySet<int> ActiveProcessIds(bool requireSignal = false, bool sameApplicationOnly = false, int? excludedProcessId = null)
    {
        var active = new HashSet<int>();
        using var enumerator = new MMDeviceEnumerator();
        foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
        {
            using (device)
            {
                var sessions = device.AudioSessionManager.Sessions;
                for (var i = 0; i < sessions.Count; i++)
                {
                    using var session = sessions[i];
                    if ((int)session.State == 1 && session.GetProcessID is > 0 and <= int.MaxValue && session.GetProcessID != excludedProcessId && (!requireSignal || session.AudioMeterInformation.MasterPeakValue > .001f)) active.Add((int)session.GetProcessID);
                }
            }
        }
        var parents = new Dictionary<int, (int Parent, string Executable)>();
        using var snapshot = CreateToolhelp32Snapshot(2, 0);
        if (snapshot.IsInvalid) throw new IOException("Audio process activity could not be inspected.");
        var entry = new ProcessEntry { Size = (uint)Marshal.SizeOf<ProcessEntry>() };
        if (!Process32FirstW(snapshot, ref entry)) throw new IOException("Process ancestry could not be inspected.");
        do { parents[(int)entry.ProcessId] = ((int)entry.ParentProcessId, entry.Executable); } while (Process32NextW(snapshot, ref entry));
        return ExpandParents(active, parents, sameApplicationOnly);
    }
    public static IReadOnlySet<int> ExpandParents(IReadOnlySet<int> audioProcesses, IReadOnlyDictionary<int, (int Parent, string Executable)> parents, bool sameApplicationOnly)
    {
        var active = new HashSet<int>(audioProcesses);
        foreach (var process in active.ToArray())
        {
            var current = process;
            for (var depth = 0; depth < 64 && parents.TryGetValue(current, out var node) && node.Parent > 0 && node.Parent != current; depth++)
            {
                if (sameApplicationOnly && (!parents.TryGetValue(node.Parent, out var parent) || !string.Equals(node.Executable, parent.Executable, StringComparison.OrdinalIgnoreCase))) break;
                if (!active.Add(node.Parent)) break;
                current = node.Parent;
            }
        }
        // One suggestion per application root, not one for every audio subprocess.
        return sameApplicationOnly ? active.Where(id => !parents.TryGetValue(id, out var node) || !active.Contains(node.Parent)).ToHashSet() : active;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry
    {
        public uint Size, Usage, ProcessId;
        public IntPtr DefaultHeap;
        public uint ModuleId, Threads, ParentProcessId;
        public int Priority;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Executable;
    }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern SafeFileHandle CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Process32FirstW(SafeFileHandle snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool Process32NextW(SafeFileHandle snapshot, ref ProcessEntry entry);
}
