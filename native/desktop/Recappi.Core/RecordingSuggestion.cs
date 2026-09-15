namespace Recappi.Core;

/// <summary>Offer each continuous application-audio episode once, after a short debounce.</summary>
public sealed class RecordingSuggestion
{
    private sealed class Episode(DateTimeOffset now) { public DateTimeOffset First = now, Last = now; public bool Offered; }
    private readonly Dictionary<string, Episode> episodes = [];
    public void SuppressActive() { foreach (var episode in episodes.Values) episode.Offered = true; }
    public AudioSource? Observe(DateTimeOffset now, IReadOnlyList<AudioSource> sources, bool enabled, bool recording, bool visible)
    {
        foreach (var key in episodes.Where(x => now - x.Value.Last >= TimeSpan.FromSeconds(30)).Select(x => x.Key).ToArray()) episodes.Remove(key);
        AudioSource? suggestion = null;
        foreach (var source in sources.Where(x => x.ProcessId is > 0))
        {
            if (!episodes.TryGetValue(source.Id, out var episode)) episodes[source.Id] = episode = new(now);
            episode.Last = now;
            if (!enabled || recording || !visible) { episode.Offered = true; continue; }
            if (suggestion is null && !episode.Offered && now - episode.First >= TimeSpan.FromSeconds(10))
            { episode.Offered = true; suggestion = source; }
        }
        return suggestion;
    }
}
