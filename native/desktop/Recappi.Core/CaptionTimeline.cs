namespace Recappi.Core;

/// <summary>A bounded live timeline; predecessor links move an item and its known descendants together.</summary>
internal sealed class CaptionTimeline(Func<long> allocateSequence)
{
    private sealed class Item(string id, long sequence)
    {
        public string Id { get; } = id;
        public long Sequence { get; set; } = sequence;
        public string? Previous { get; set; }
        public Dictionary<int, CaptionDelta> Content { get; } = [];
    }

    private readonly Dictionary<string, Item> items = [];
    private readonly List<Item> order = [];
    private int contentCount;
    internal int Count => items.Count;
    internal int ContentCount => contentCount;
    public bool Contains(string id) => items.ContainsKey(id);
    public bool IsTerminal(string id) => items.TryGetValue(id, out var item) && item.Content.Count != 0 && item.Content.Values.All(x => x.IsFinal || x.IsFailed);

    public IReadOnlyList<CaptionDelta> Register(string id, string? previous, Func<string, bool> isAwaiting)
    {
        var changed = false;
        if (!items.TryGetValue(id, out var item))
        {
            // Only retire a completed prefix: later reordering must never move live
            // items across captions whose final positions have already been retired.
            while (items.Count >= 256 || contentCount >= 512)
            {
                var oldest = order[0];
                if (isAwaiting(oldest.Id) || oldest.Content.Count == 0 || oldest.Content.Values.Any(x => !x.IsFinal && !x.IsFailed))
                    throw new IOException(L.T("字幕顺序等待过久，需重新连接。", "Caption ordering waited too long. Reconnect needed."));
                contentCount -= oldest.Content.Count;
                items.Remove(oldest.Id); order.RemoveAt(0);
            }
            item = new(id, allocateSequence());
            items.Add(id, item); order.Add(item);
            changed = true;
        }
        if (!string.IsNullOrEmpty(previous) && previous != item.Previous)
        {
            var ancestor = previous;
            var visited = new HashSet<string>();
            while (ancestor is not null && visited.Add(ancestor))
            {
                if (ancestor == id) throw new InvalidDataException(L.T("字幕顺序包含循环引用。", "Caption ordering contains a cycle."));
                ancestor = items.TryGetValue(ancestor, out var parent) ? parent.Previous : null;
            }
            item.Previous = previous;
            changed = true;
        }

        if (!changed) return [];

        var children = items.Values.Where(x => x.Previous is not null && items.ContainsKey(x.Previous))
            .GroupBy(x => x.Previous!).ToDictionary(x => x.Key, x => x.Reverse().ToArray());
        var resolved = new List<Item>(order.Count);
        void Visit(Item current)
        {
            resolved.Add(current);
            if (children.TryGetValue(current.Id, out var successors))
                foreach (var successor in successors) Visit(successor);
        }
        foreach (var root in order.Where(x => x.Previous is null || !items.ContainsKey(x.Previous))) Visit(root);
        if (resolved.Count != order.Count) throw new InvalidDataException(L.T("字幕顺序无效。", "Caption ordering is invalid."));
        var slots = order.Select(x => x.Sequence).Order().ToArray();
        var revisions = new List<CaptionDelta>();
        for (var index = 0; index < resolved.Count; index++)
        {
            var current = resolved[index];
            if (current.Sequence == slots[index]) continue;
            current.Sequence = slots[index];
            foreach (var contentIndex in current.Content.Keys.ToArray())
            {
                var prior = current.Content[contentIndex];
                var updated = prior with { Position = prior.Position! with { Sequence = current.Sequence } };
                current.Content[contentIndex] = updated;
                revisions.Add(updated);
            }
        }
        order.Clear(); order.AddRange(resolved);
        return revisions;
    }

    public CaptionPosition Position(string id, string session, int contentIndex) => new(session, items[id].Sequence, contentIndex);

    public void Remember(string id, CaptionDelta value)
    {
        var item = items[id];
        var contentIndex = value.Position!.ContentIndex;
        if (!item.Content.ContainsKey(contentIndex))
        {
            if (contentCount >= 512) throw new IOException(L.T("字幕内容等待过多，需重新连接。", "Too much caption content is pending. Reconnect needed."));
            contentCount++;
        }
        item.Content[contentIndex] = value;
    }
}
