using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Recappi.Core;

public sealed record DesktopRelease(string Version, Uri Page, Uri Download, string FileName, long Size, string Sha256);
public sealed record DesktopUpdateCheck(DesktopRelease? Update, bool HasCompatibleRelease);

public sealed class DesktopUpdates : IDisposable
{
    public static readonly Uri ReleasesPage = new("https://github.com/Recappi/recappi-mini/releases");
    private const string DownloadPrefix = "https://github.com/Recappi/recappi-mini/releases/download/";
    private const long MaxPackageBytes = 1024L * 1024 * 1024;
    private readonly HttpClient http;

    public DesktopUpdates(HttpMessageHandler? handler = null)
    {
        http = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect = false }) { Timeout = Timeout.InfiniteTimeSpan };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("Recappi-Mini-Windows/1.0");
        http.DefaultRequestHeaders.Add("X-GitHub-Api-Version", "2022-11-28");
    }

    public async Task<DesktopUpdateCheck> CheckAsync(string currentVersion, string runtime, CancellationToken cancellation = default)
    {
        var current = ReleaseVersion.Parse(currentVersion);
        if (runtime is not ("win-x64" or "win-arm64")) throw new ArgumentException("Unsupported update architecture.", nameof(runtime));
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        DesktopRelease? latest = null;
        ReleaseVersion? latestVersion = null;
        var found = false;
        for (var page = 1; page <= 10; page++)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, $"https://api.github.com/repos/Recappi/recappi-mini/releases?per_page=100&page={page}");
            request.Headers.Accept.ParseAdd("application/vnd.github+json");
            using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            response.EnsureSuccessStatusCode();
            using var body = await ReadBoundedAsync(response.Content, 4 * 1024 * 1024, timeout.Token).ConfigureAwait(false);
            using var document = await JsonDocument.ParseAsync(body, cancellationToken: timeout.Token).ConfigureAwait(false);
            if (document.RootElement.ValueKind != JsonValueKind.Array) throw new InvalidDataException("Invalid release feed.");
            foreach (var release in document.RootElement.EnumerateArray())
            {
                if (release.GetProperty("draft").GetBoolean() || (release.GetProperty("prerelease").GetBoolean() && !current.IsPreview)) continue;
                var tag = release.GetProperty("tag_name").GetString();
                if (string.IsNullOrWhiteSpace(tag)) continue;
                var expectedPrefix = DownloadPrefix + Uri.EscapeDataString(tag) + "/";
                foreach (var asset in release.GetProperty("assets").EnumerateArray())
                {
                    var name = asset.GetProperty("name").GetString() ?? "";
                    const string prefix = "Recappi-Mini-";
                    var suffix = "-" + runtime + ".zip";
                    if (!name.StartsWith(prefix, StringComparison.Ordinal) || !name.EndsWith(suffix, StringComparison.Ordinal)) continue;
                    if (!ReleaseVersion.TryParse(name[prefix.Length..^suffix.Length], out var version) || (!current.IsPreview && version.IsPreview)) continue;
                    if (asset.GetProperty("state").GetString() != "uploaded") continue;
                    var digest = asset.TryGetProperty("digest", out var hash) ? hash.GetString() : null;
                    var size = asset.GetProperty("size").GetInt64();
                    var url = asset.GetProperty("browser_download_url").GetString();
                    if (digest is null || !Regex.IsMatch(digest, @"\Asha256:[0-9a-fA-F]{64}\z") || size is <= 0 or > MaxPackageBytes ||
                        url != expectedPrefix + Uri.EscapeDataString(name)) continue;
                    found = true;
                    if (version.CompareTo(current) <= 0 || (latestVersion is not null && version.CompareTo(latestVersion) <= 0)) continue;
                    latestVersion = version;
                    latest = new(version.Text, new Uri(ReleasesPage + "/tag/" + Uri.EscapeDataString(tag)), new Uri(url), name, size, digest[7..].ToLowerInvariant());
                }
            }
            if (document.RootElement.GetArrayLength() < 100) return new(latest, found);
        }
        throw new InvalidDataException("Release feed exceeds the supported search limit; open the official releases page.");
    }

    public async Task<string> DownloadAsync(DesktopRelease release, string destination, IProgress<double>? progress = null, CancellationToken cancellation = default)
    {
        if (!release.Download.AbsoluteUri.StartsWith(DownloadPrefix, StringComparison.Ordinal) || !TrustedUri(release.Download, false) ||
            release.Size is <= 0 or > MaxPackageBytes || !Regex.IsMatch(release.Sha256, @"\A[0-9a-fA-F]{64}\z"))
            throw new InvalidDataException("Untrusted release package.");
        var target = Path.GetFullPath(destination);
        var partial = target + "." + Guid.NewGuid().ToString("N") + ".partial";
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        timeout.CancelAfter(TimeSpan.FromMinutes(10));
        try
        {
            var url = release.Download;
            for (var hop = 0; hop <= 5; hop++)
            {
                using var response = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
                if (response.StatusCode is HttpStatusCode.MovedPermanently or HttpStatusCode.Redirect or HttpStatusCode.SeeOther or HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect)
                {
                    var location = response.Headers.Location ?? throw new InvalidDataException("Missing download redirect.");
                    url = location.IsAbsoluteUri ? location : new Uri(url, location);
                    if (!TrustedUri(url, true)) throw new InvalidDataException("Untrusted download redirect.");
                    continue;
                }
                response.EnsureSuccessStatusCode();
                if (response.Content.Headers.ContentLength is { } length && length != release.Size) throw new InvalidDataException("Package length mismatch.");
                await using (var input = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false))
                await using (var output = new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None, 64 * 1024, true))
                using (var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
                {
                    var buffer = new byte[64 * 1024];
                    long received = 0;
                    int read;
                    while ((read = await input.ReadAsync(buffer, timeout.Token).ConfigureAwait(false)) != 0)
                    {
                        received += read;
                        if (received > release.Size) throw new InvalidDataException("Package exceeds declared length.");
                        hash.AppendData(buffer, 0, read);
                        await output.WriteAsync(buffer.AsMemory(0, read), timeout.Token).ConfigureAwait(false);
                        progress?.Report((double)received / release.Size);
                    }
                    if (received != release.Size || !CryptographicOperations.FixedTimeEquals(hash.GetHashAndReset(), Convert.FromHexString(release.Sha256)))
                        throw new InvalidDataException("Package integrity verification failed.");
                    await output.FlushAsync(timeout.Token).ConfigureAwait(false);
                }
                timeout.Token.ThrowIfCancellationRequested();
                File.Move(partial, target, overwrite: true);
                return target;
            }
            throw new InvalidDataException("Too many download redirects.");
        }
        finally { if (File.Exists(partial)) File.Delete(partial); }
    }

    private static bool TrustedUri(Uri url, bool allowCdn) => url.Scheme == "https" && url.IsDefaultPort && url.UserInfo.Length == 0 && url.Fragment.Length == 0 &&
        ((url.Host == "github.com" && url.AbsoluteUri.StartsWith(DownloadPrefix, StringComparison.Ordinal)) || (allowCdn && url.Host == "release-assets.githubusercontent.com"));

    private static async Task<MemoryStream> ReadBoundedAsync(HttpContent content, int limit, CancellationToken token)
    {
        if (content.Headers.ContentLength > limit) throw new InvalidDataException("Release response too large.");
        await using var input = await content.ReadAsStreamAsync(token).ConfigureAwait(false);
        var output = new MemoryStream();
        try
        {
            var buffer = new byte[16 * 1024];
            int read;
            while ((read = await input.ReadAsync(buffer, token).ConfigureAwait(false)) != 0)
            {
                if (output.Length + read > limit) throw new InvalidDataException("Release response too large.");
                output.Write(buffer, 0, read);
            }
            output.Position = 0;
            return output;
        }
        catch { output.Dispose(); throw; }
    }
    public void Dispose() => http.Dispose();
}

public sealed class ReleaseVersion : IComparable<ReleaseVersion>
{
    private static readonly Regex Pattern = new(@"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?\z", RegexOptions.CultureInvariant);
    public string Text { get; }
    private readonly string[] numbers;
    private readonly string[] preview;
    public bool IsPreview => preview.Length != 0;
    private ReleaseVersion(string text, Match match) { Text = text; numbers = [match.Groups[1].Value, match.Groups[2].Value, match.Groups[3].Value]; preview = match.Groups[4].Success ? match.Groups[4].Value.Split('.') : []; }
    public static ReleaseVersion Parse(string text) => TryParse(text, out var value) ? value : throw new ArgumentException("Invalid release version.", nameof(text));
    public static bool TryParse(string text, out ReleaseVersion version)
    {
        version = null!;
        if (text.Length > 128) return false;
        var match = Pattern.Match(text);
        if (!match.Success) return false;
        var candidate = new ReleaseVersion(text, match);
        if (candidate.preview.Any(x => x.Length > 1 && x[0] == '0' && IsNumeric(x))) return false;
        version = candidate; return true;
    }
    private static bool IsNumeric(string value) => value.All(c => c is >= '0' and <= '9');
    private static int NumericCompare(string left, string right) => left.Length != right.Length ? left.Length.CompareTo(right.Length) : string.CompareOrdinal(left, right);
    public int CompareTo(ReleaseVersion? other)
    {
        if (other is null) return 1;
        for (var i = 0; i < 3; i++) { var compared = NumericCompare(numbers[i], other.numbers[i]); if (compared != 0) return compared; }
        if (!IsPreview || !other.IsPreview) return IsPreview == other.IsPreview ? 0 : IsPreview ? -1 : 1;
        for (var i = 0; i < Math.Min(preview.Length, other.preview.Length); i++)
        {
            var leftNumeric = IsNumeric(preview[i]); var rightNumeric = IsNumeric(other.preview[i]);
            var compared = leftNumeric && rightNumeric ? NumericCompare(preview[i], other.preview[i]) : leftNumeric != rightNumeric ? leftNumeric ? -1 : 1 : string.CompareOrdinal(preview[i], other.preview[i]);
            if (compared != 0) return compared;
        }
        return preview.Length.CompareTo(other.preview.Length);
    }
}
