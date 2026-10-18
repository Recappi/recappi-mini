using System.Runtime.InteropServices;

namespace Recappi.WinUI;

internal enum DesktopDistribution { Portable, Packaged, Unknown }

internal static class DesktopDistributionDetector
{
    public static DesktopDistribution Detect()
    {
        uint length = 0;
        return GetCurrentPackageFullName(ref length, IntPtr.Zero) switch
        {
            15700 => DesktopDistribution.Portable,
            122 when length > 0 => DesktopDistribution.Packaged,
            _ => DesktopDistribution.Unknown
        };
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int GetCurrentPackageFullName(ref uint packageFullNameLength, IntPtr packageFullName);
}
