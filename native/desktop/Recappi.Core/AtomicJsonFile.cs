namespace Recappi.Core;

internal static class AtomicJsonFile
{
    public static void Write(string path, string json)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            File.WriteAllText(temporary, json);
            for (var attempt = 0; ; attempt++)
            {
                try { File.Move(temporary, path, true); break; }
                catch (Exception error) when (attempt < 3 &&
                    error is IOException or UnauthorizedAccessException && (error.HResult & 0xffff) is 5 or 32 or 33)
                {
                    // Windows readers can briefly deny replacement. Keep retries bounded
                    // and leave the previous document intact on persistent failure.
                    Thread.Sleep(25 << attempt);
                }
            }
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
