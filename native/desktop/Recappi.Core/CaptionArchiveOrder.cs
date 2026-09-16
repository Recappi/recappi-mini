using System.Text.Json;

namespace Recappi.Core;

/// <summary>Sort final captions without retaining an entire recording in memory.</summary>
public static class CaptionArchiveOrder
{
    private sealed record Entry(long Group, long Row, ArchivedCaption Caption);
    private static int Compare(Entry left, Entry right)
    {
        var result = left.Group.CompareTo(right.Group);
        if (result == 0) result = (left.Caption.Position?.Sequence ?? left.Row).CompareTo(right.Caption.Position?.Sequence ?? right.Row);
        if (result == 0) result = (left.Caption.Position?.ContentIndex ?? 0).CompareTo(right.Caption.Position?.ContentIndex ?? 0);
        return result != 0 ? result : left.Row.CompareTo(right.Row);
    }

    public static IEnumerable<ArchivedCaption> Read(string path)
    {
        const int batchSize = 128;
        var batch = new List<Entry>(batchSize);
        var levels = new List<string?>();
        string? directory = null;
        string? previousSession = null;
        long group = 0, row = 0;
        string NewRun()
        {
            directory ??= Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "recappi-caption-sort-" + Guid.NewGuid().ToString("N"))).FullName;
            return Path.Combine(directory, Guid.NewGuid().ToString("N") + ".jsonl");
        }
        void Spill()
        {
            batch.Sort(Compare);
            var run = NewRun();
            using (var output = new StreamWriter(run))
                foreach (var entry in batch) output.WriteLine(JsonSerializer.Serialize(entry));
            batch.Clear();
            // Binary merging bounds both open files and retained run names for long recordings.
            var level = 0;
            while (level < levels.Count && levels[level] is { } prior)
            {
                var merged = NewRun();
                Merge(prior, run, merged);
                File.Delete(prior); File.Delete(run);
                levels[level++] = null;
                run = merged;
            }
            if (level == levels.Count) levels.Add(run); else levels[level] = run;
        }
        try
        {
            foreach (var caption in CaptionArchive.Read(path))
            {
                // A retry keeps its session; a new recorder instance starts a new contiguous
                // session after the old consumer drains. Legacy entries preserve file order.
                var session = caption.Position?.Session;
                if (session != previousSession) { group++; previousSession = session; }
                if (batch.Count == batchSize) Spill();
                batch.Add(new(group, row++, caption));
            }
            if (directory is null)
            {
                batch.Sort(Compare);
                foreach (var entry in batch) yield return entry.Caption;
                yield break;
            }
            if (batch.Count != 0) Spill();
            string? final = null;
            foreach (var run in levels)
            {
                if (run is null) continue;
                if (final is null) { final = run; continue; }
                var merged = NewRun();
                Merge(final, run, merged);
                File.Delete(final); File.Delete(run);
                final = merged;
            }
            if (final is not null)
            {
                using var input = new StreamReader(final);
                while (ReadEntry(input) is { } entry) yield return entry.Caption;
            }
        }
        finally
        {
            if (directory is not null) Directory.Delete(directory, recursive: true);
        }
    }

    private static Entry? ReadEntry(StreamReader reader) => reader.ReadLine() is { } line
        ? JsonSerializer.Deserialize<Entry>(line) ?? throw new InvalidDataException("字幕排序临时文件无效。") : null;

    private static void Merge(string first, string second, string destination)
    {
        using var left = new StreamReader(first);
        using var right = new StreamReader(second);
        using var output = new StreamWriter(destination);
        var a = ReadEntry(left); var b = ReadEntry(right);
        while (a is not null || b is not null)
        {
            if (a is not null && (b is null || Compare(a, b) <= 0))
            {
                output.WriteLine(JsonSerializer.Serialize(a)); a = ReadEntry(left);
            }
            else
            {
                output.WriteLine(JsonSerializer.Serialize(b)); b = ReadEntry(right);
            }
        }
    }
}
