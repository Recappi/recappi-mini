using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using Recappi.Core;

internal static class DesktopUpdateTests
{
    private static void Check(bool value, string message) { if (!value) throw new Exception(message); }
    private static async Task Reject(Func<Task> action)
    {
        try { await action(); } catch (Exception error) when (error is InvalidDataException or HttpRequestException or OperationCanceledException) { return; }
        throw new Exception("Invalid update operation succeeded.");
    }
    public static async Task RunAsync(string root)
    {
        string[] versions = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2", "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0", "1.0.1", "1.1.0", "2.0.0", "10.0.0"];
        for (var i = 0; i < versions.Length - 1; i++) Check(ReleaseVersion.Parse(versions[i]).CompareTo(ReleaseVersion.Parse(versions[i + 1])) < 0, "Version precedence incorrect.");
        Check(ReleaseVersion.Parse("1.0.0+build.1").CompareTo(ReleaseVersion.Parse("1.0.0+build.2")) == 0, "Build metadata changes precedence.");
        foreach (var invalid in new[] { "01.0.0", "1.0", "1.0.0-preview.01", "1.0.0-", "1.0.0/../../", "v1.0.0", "1.0.0\n", "1١.0.0" })
            Check(!ReleaseVersion.TryParse(invalid, out _), "Invalid version accepted: " + invalid);
        var bytes = Enumerable.Range(0, 180000).Select(i => (byte)(i % 251)).ToArray();
        var digest = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
        object Release(string version, string runtime = "win-x64", bool preview = false, bool draft = false, string? hash = null, string? url = null)
        {
            var name = $"Recappi-Mini-{version}-{runtime}.zip";
            return new { tag_name = "windows-v" + version, draft, prerelease = preview, assets = new[] { new { name, state = "uploaded", size = bytes.Length, digest = hash ?? "sha256:" + digest,
                browser_download_url = url ?? $"https://github.com/Recappi/recappi-mini/releases/download/windows-v{version}/{name}" } } };
        }
        var feed = new[] { Release("1.2.0"), Release("9.0.0", draft: true), Release("2.0.0-preview.2", preview: true), Release("8.0.0", hash: ""), Release("7.0.0", url: "https://evil.invalid/Recappi-Mini-7.0.0-win-x64.zip"), Release("6.0.0", runtime: "win-arm64"), Release("1.10.0") };
        using var discovery = new DesktopUpdates(new Handler((request, _) =>
        {
            Check(request.RequestUri!.Host == "api.github.com" && request.RequestUri.AbsolutePath == "/repos/Recappi/recappi-mini/releases", "Update source was not pinned.");
            Check(request.Headers.Authorization is null, "Account credentials leaked to release service.");
            return Task.FromResult(Json(feed));
        }));
        var stable = await discovery.CheckAsync("1.0.0", "win-x64");
        Check(stable.Update?.Version == "1.10.0" && stable.HasCompatibleRelease, "Stable release filtering/sorting failed.");
        Check((await discovery.CheckAsync("1.0.0-preview.1", "win-x64")).Update?.Version == "2.0.0-preview.2", "Preview channel did not include previews.");
        Check((await discovery.CheckAsync("1.0.0", "win-arm64")).Update?.Version == "6.0.0", "Architecture filtering failed.");
        Check((await discovery.CheckAsync("10.0.0", "win-x64")).Update is null, "Updater offered a downgrade.");
        using var missingDigest = new DesktopUpdates(new Handler((_, _) => Task.FromResult(Json(new[] { Release("3.0.0", hash: "") }))));
        Check(!(await missingDigest.CheckAsync("1.0.0", "win-x64")).HasCompatibleRelease, "Unsigned metadata was treated as verifiable.");
        var pages = 0;
        using var paged = new DesktopUpdates(new Handler((_, _) => Task.FromResult(Json(++pages == 1 ? Enumerable.Repeat(Release("1.0.0"), 100).ToArray() : [Release("3.0.0")]))));
        Check((await paged.CheckAsync("1.0.0", "win-x64")).Update?.Version == "3.0.0" && pages == 2, "Only first release page was searched.");
        using var oversizedFeed = new DesktopUpdates(new Handler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(new byte[4 * 1024 * 1024 + 1]) })));
        await Reject(() => oversizedFeed.CheckAsync("1.0.0", "win-x64"));
        var candidate = stable.Update!;
        var target = Path.Combine(root, "update-package.zip");
        var redirects = 0;
        using (var success = new DesktopUpdates(new Handler((_, _) =>
        {
            if (++redirects == 1)
            {
                var redirect = new HttpResponseMessage(HttpStatusCode.Redirect); redirect.Headers.Location = new Uri("https://release-assets.githubusercontent.com/test-package"); return Task.FromResult(redirect);
            }
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) });
        })))
        {
            await success.DownloadAsync(candidate, target);
            Check(File.ReadAllBytes(target).SequenceEqual(bytes) && redirects == 2, "Verified download differed from source.");
        }
        var previous = File.ReadAllBytes(target);
        foreach (var payload in new[] { bytes[..^1], bytes.Concat(new byte[] { 0 }).ToArray(), bytes.Select(b => (byte)(b ^ 1)).ToArray() })
        {
            using var client = new DesktopUpdates(new Handler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(payload) })));
            await Reject(() => client.DownloadAsync(candidate, target));
            Check(File.ReadAllBytes(target).SequenceEqual(previous), "Invalid download replaced previous file.");
        }
        foreach (var location in new[] { "http://release-assets.githubusercontent.com/package", "https://github.com.evil.invalid/package", "https://release-assets.githubusercontent.com.evil.invalid/package", "https://github.com/another/repository/package", "https://user@release-assets.githubusercontent.com/package" })
        {
            using var client = new DesktopUpdates(new Handler((_, _) =>
            {
                var redirect = new HttpResponseMessage(HttpStatusCode.Redirect); redirect.Headers.Location = new Uri(location); return Task.FromResult(redirect);
            }));
            await Reject(() => client.DownloadAsync(candidate, target));
        }
        using (var cancellation = new CancellationTokenSource())
        using (var client = new DesktopUpdates(new Handler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new InterruptedStream(bytes, cancellation)) }))))
        {
            await Reject(() => client.DownloadAsync(candidate, target, cancellation: cancellation.Token));
            Check(cancellation.IsCancellationRequested && File.ReadAllBytes(target).SequenceEqual(previous), "Canceled download replaced existing file.");
        }
        Check(!Directory.EnumerateFiles(root, "*.partial").Any(), "Failed update left partial files.");
    }
    private static HttpResponseMessage Json(object value) => new(HttpStatusCode.OK) { Content = new StringContent(JsonSerializer.Serialize(value)) };
    private sealed class Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => send(request, token);
    }
    private sealed class InterruptedStream(byte[] bytes, CancellationTokenSource cancellation) : MemoryStream(bytes)
    {
        public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken token = default)
        {
            if (Position > 0) { cancellation.Cancel(); token.ThrowIfCancellationRequested(); }
            return base.ReadAsync(buffer[..Math.Min(buffer.Length, 1000)], token);
        }
    }
}
