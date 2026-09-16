using System.Text;

namespace Recappi.Core;

public static class CaptionExport
{
    public static void Save(LocalRecordingStore store, LocalRecording recording, string destination, bool archive)
    {
        var target = Path.GetFullPath(destination);
        var root = Path.TrimEndingDirectorySeparator(store.Root);
        if (target.Equals(root, StringComparison.OrdinalIgnoreCase) ||
            target.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("请选择录音存储目录以外的导出位置，以保留原始文件。");
        var source = store.CaptionPath(recording);
        // Open before creating output: a missing archive must not produce an empty successful export.
        using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read);
        var temporary = Path.Combine(Path.GetDirectoryName(target)!, ".recappi-export-" + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                if (archive) input.CopyTo(output);
                else
                {
                    using var writer = new StreamWriter(output, new UTF8Encoding(false), leaveOpen: true);
                    foreach (var caption in CaptionArchiveOrder.Read(source))
                        writer.WriteLine((caption.Stream == "translation" ? "[译文] " : "[原文] ") + caption.Text);
                    writer.Flush();
                }
                output.Flush(true);
            }
            File.Move(temporary, target, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
