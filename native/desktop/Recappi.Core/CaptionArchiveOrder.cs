using System.Text.Json;

namespace Recappi.Core;

/// <summary>Apply the last position revision, then sort without retaining an entire recording in memory.</summary>
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
        foreach (var entry in Sort(Latest(Sort(Rows(path), CompareIdentity)), Compare)) yield return entry.Caption;
    }

    private static IEnumerable<Entry> Rows(string path)
    {
        string? previousSession = null;
        long group = 0, row = 0;
        foreach (var caption in CaptionArchive.Read(path))
        {
            // A retry keeps its session; a new recorder instance starts a new contiguous
            // session after the old consumer drains. Legacy entries preserve file order.
            var session = caption.Position?.Session;
            if (session != previousSession) { group++; previousSession = session; }
            yield return new(group, row++, caption);
        }
    }

    private static int CompareIdentity(Entry left, Entry right)
    {
        var result = left.Group.CompareTo(right.Group);
        if (result != 0) return result;
        result = (left.Caption.Position is not null).CompareTo(right.Caption.Position is not null);
        if (result != 0) return result;
        if (left.Caption.Position is not null)
        {
            result = StringComparer.Ordinal.Compare(left.Caption.SegmentId, right.Caption.SegmentId);
            if (result == 0) result = StringComparer.Ordinal.Compare(left.Caption.Stream, right.Caption.Stream);
        }
        return result != 0 ? result : left.Row.CompareTo(right.Row);
    }

    private static bool SameIdentity(Entry left, Entry right) => left.Group == right.Group &&
        left.Caption.Position is not null && right.Caption.Position is not null &&
        left.Caption.SegmentId == right.Caption.SegmentId && left.Caption.Stream == right.Caption.Stream;

    private static IEnumerable<Entry> Latest(IEnumerable<Entry> entries)
    {
        Entry? latest = null;
        foreach (var entry in entries)
        {
            if (latest is not null && !SameIdentity(latest, entry)) yield return latest;
            latest = entry;
        }
        if (latest is not null) yield return latest;
    }

    private static IEnumerable<Entry> Sort(IEnumerable<Entry> entries, Comparison<Entry> compare)
    {
        const int batchSize = 128;
        var batch = new List<Entry>(batchSize);
        var levels = new List<string?>();
        string? directory = null;
        string NewRun()
        {
            directory ??= Directory.CreateDirectory(Path.Combine(Path.GetTempPath(), "recappi-caption-sort-" + Guid.NewGuid().ToString("N"))).FullName;
            return Path.Combine(directory, Guid.NewGuid().ToString("N") + ".jsonl");
        }
        void Spill()
        {
            batch.Sort(compare);
            var run = NewRun();
            using (var output = new StreamWriter(run))
                foreach (var entry in batch) output.WriteLine(JsonSerializer.Serialize(entry));
            batch.Clear();
            // Binary merging bounds both open files and retained run names for long recordings.
            var level = 0;
            while (level < levels.Count && levels[level] is { } prior)
            {
                var merged = NewRun();
                Merge(prior, run, merged, compare);
                File.Delete(prior); File.Delete(run);
                levels[level++] = null;
                run = merged;
            }
            if (level == levels.Count) levels.Add(run); else levels[level] = run;
        }
        try
        {
            foreach (var entry in entries)
            {
                if (batch.Count == batchSize) Spill();
                batch.Add(entry);
            }
            if (directory is null)
            {
                batch.Sort(compare);
                foreach (var entry in batch) yield return entry;
                yield break;
            }
            if (batch.Count != 0) Spill();
            string? final = null;
            foreach (var run in levels)
            {
                if (run is null) continue;
                if (final is null) { final = run; continue; }
                var merged = NewRun();
                Merge(final, run, merged, compare);
                File.Delete(final); File.Delete(run);
                final = merged;
            }
            if (final is not null)
            {
                using var input = new StreamReader(final);
                while (ReadEntry(input) is { } entry) yield return entry;
            }
        }
        finally
        {
            if (directory is not null) Directory.Delete(directory, recursive: true);
        }
    }

    private static Entry? ReadEntry(StreamReader reader) => reader.ReadLine() is { } line
        ? JsonSerializer.Deserialize<Entry>(line) ?? throw new InvalidDataException(L.T("字幕排序临时文件无效。", "Caption ordering temp file is invalid.")) : null;

    private static void Merge(string first, string second, string destination, Comparison<Entry> compare)
    {
        using var left = new StreamReader(first);
        using var right = new StreamReader(second);
        using var output = new StreamWriter(destination);
        var a = ReadEntry(left); var b = ReadEntry(right);
        while (a is not null || b is not null)
        {
            if (a is not null && (b is null || compare(a, b) <= 0))
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
