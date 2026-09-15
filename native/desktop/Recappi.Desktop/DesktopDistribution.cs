using System;
using System.Runtime.InteropServices;

namespace Recappi.Desktop;

public enum DesktopDistribution { Portable, Packaged, Unknown }

public static class DesktopDistributionDetector
{
    public static DesktopDistribution Detect()
    {
        uint length = 0;
        var result = GetCurrentPackageFullName(ref length, IntPtr.Zero);
        return result switch
        {
            15700 => DesktopDistribution.Portable, // APPMODEL_ERROR_NO_PACKAGE
            122 when length > 0 => DesktopDistribution.Packaged, // ERROR_INSUFFICIENT_BUFFER
            _ => DesktopDistribution.Unknown
        };
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int GetCurrentPackageFullName(ref uint packageFullNameLength, IntPtr packageFullName);
}
