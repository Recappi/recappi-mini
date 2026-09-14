using System.Diagnostics;
using NAudio.CoreAudioApi;

static class InputCatalog
{
    public static object Microphones()
    {
        using var enumerator = new MMDeviceEnumerator();
        string? defaultId = null;
        try { using var device = enumerator.GetDefaultAudioEndpoint(DataFlow.Capture, Role.Console); defaultId = device.ID; }
        catch (System.Runtime.InteropServices.COMException) { }
        var microphones = new List<object>();
        foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.Active))
        {
            using (device) microphones.Add(new { id = device.ID, label = device.FriendlyName, isDefault = device.ID == defaultId });
        }
        return new { microphones };
    }

    public static object Sources()
    {
        var sources = new List<object> { new { id = "system", kind = "system", label = "System audio · all apps" } };
        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 20348)) return new { sources };
        // Window-owning processes are useful even before they start playing audio.
        // WASAPI includes their children (e.g. browser audio subprocesses).
        var ids = new HashSet<int>();
        foreach (var process in Process.GetProcesses())
        {
            using (process)
            {
                try { if (process.MainWindowHandle != IntPtr.Zero) ids.Add(process.Id); }
                catch (InvalidOperationException) { }
                catch (System.ComponentModel.Win32Exception) { }
            }
        }
        using var enumerator = new MMDeviceEnumerator();
        foreach (var device in enumerator.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
        {
            using (device)
            {
                var sessions = device.AudioSessionManager.Sessions;
                for (int i = 0; i < sessions.Count; i++)
                {
                    using var session = sessions[i];
                    if (session.GetProcessID is > 0 and <= int.MaxValue) ids.Add((int)session.GetProcessID);
                }
            }
        }
        foreach (int id in ids.Order())
        {
            try
            {
                using var process = Process.GetProcessById(id);
                if (process.HasExited || id == Environment.ProcessId) continue;
                sources.Add(new { id = $"process:{id}", kind = "app", label = $"{process.ProcessName} (PID {id})", appName = process.ProcessName, processId = id });
            }
            catch (ArgumentException) { } // App exited during enumeration.
            catch (InvalidOperationException) { }
            catch (System.ComponentModel.Win32Exception) { }
        }
        return new { sources };
    }
}
