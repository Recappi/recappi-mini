using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;
using Recappi.Core;
using Recappi.Desktop;

internal static class LibraryProfile
{
    public static async Task RunAsync(bool smokeOnly = false)
    {
        var root = Path.GetFullPath(Path.Combine("build/native-desktop-validation", "library-profile-" + Guid.NewGuid().ToString("N")));
        Directory.CreateDirectory(root);
        var count = smokeOnly ? 500 : 10000;
        const int pageSize = 50;
        var today = DateTime.Today;
        var remote = Enumerable.Range(0, count).Select(i => new CloudRecordingItem("profile-" + i, "Recording " + i, "ready", 1000)
            { CreatedAt = new DateTimeOffset(today.AddDays(-i / 100).AddHours(12)) }).ToArray();
        var store = new AccountStore(Path.Combine(root, "account"));
        store.Save(new("https://example.test", "library-profile", null, "fixture"));
        var listCalls = 0;
        var session = new AccountSession(store, (origin, token) => new CloudClient(origin, token, new Handler(request =>
        {
            if (request.RequestUri!.AbsolutePath.EndsWith("get-session")) return Json("""{"session":{},"user":{"id":"library-profile"}}""");
            if (request.RequestUri.AbsolutePath == "/api/recordings")
            {
                var part = request.RequestUri.Query.Split('&').FirstOrDefault(x => x.StartsWith("cursor=", StringComparison.Ordinal));
                var offset = part is null ? 0 : int.Parse(part[7..]);
                listCalls++;
                return Json(JsonSerializer.Serialize(new { items = remote.Skip(offset).Take(pageSize).Select(x => new { id = x.Id, title = x.Title, status = x.Status, createdAt = x.CreatedAt }), nextCursor = offset + pageSize < count ? (offset + pageSize).ToString() : null }));
            }
            return Json("{}");
        })));
        await session.RestoreAsync();
        var window = new CloudLibraryWindow(session, contentCache: new CloudContentCache(Path.Combine(root, "cache")), localToday: () => today) { ShowActivated = false };
        var results = new List<object>();
        var dispatcher = Application.Current.Dispatcher;
        async Task Layout() => await dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
        var total = Stopwatch.StartNew();
        var pageTimes = new List<double>();
        try
        {
            DesktopTheme.Apply("system");
            window.Show(); await Layout();
            var list = (ListBox)window.FindName("Recordings");
            var more = (Button)window.FindName("MoreButton");
            foreach (var target in smokeOnly ? new[] { 50, count } : new[] { 50, 500, 2000, count })
            {
                while (list.Items.Count < target)
                {
                    if (!more.IsEnabled) throw new Exception("Pagination stopped before target " + target);
                    var page = Stopwatch.StartNew();
                    more.RaiseEvent(new RoutedEventArgs(Button.ClickEvent)); await Layout();
                    pageTimes.Add(page.Elapsed.TotalMilliseconds);
                }
                var realized = Descendants(list).OfType<ListBoxItem>().Count();
                if (realized is < 1 or > 100) throw new Exception("Grouped library virtualization failed: " + realized);
                using var process = Process.GetCurrentProcess(); process.Refresh();
                var sample = new { loaded = list.Items.Count, realized, elapsedMs = total.Elapsed.TotalMilliseconds, process.WorkingSet64, process.PrivateMemorySize64 };
                results.Add(sample); if (!smokeOnly) Console.WriteLine(JsonSerializer.Serialize(sample));
            }
            var last = list.Items[count - 1];
            var selection = Stopwatch.StartNew(); list.SelectedItem = last; list.ScrollIntoView(last); await Layout();
            var selectionMs = selection.Elapsed.TotalMilliseconds;
            var endRealized = Descendants(list).OfType<ListBoxItem>().Count();
            if (endRealized is < 1 or > 100 || !ReferenceEquals(list.SelectedItem, last)) throw new Exception("Last-row selection or virtualization failed.");
            var regroup = Stopwatch.StartNew(); today = today.AddDays(1); window.RefreshDateGroups(); await Layout();
            var regroupMs = regroup.Elapsed.TotalMilliseconds;
            if (!ReferenceEquals(list.SelectedItem, last)) throw new Exception("Date refresh lost selected recording.");
            if (smokeOnly) { Console.WriteLine("PASS native grouped library virtualizes 500 rows, paginates and preserves last-row selection across date changes."); return; }
            var refreshTimes = new List<double>();
            for (var i = 0; i < 5; i++)
            {
                var refresh = Stopwatch.StartNew(); window.RebuildLibrary(); await Layout(); refreshTimes.Add(refresh.Elapsed.TotalMilliseconds);
                if ((list.SelectedItem as LibraryRecording)?.Key != (last as LibraryRecording)?.Key) throw new Exception("Rebuild lost selected recording.");
                if (!Descendants(list).OfType<ListBoxItem>().Any(x => x.IsSelected)) throw new Exception("Rebuild scrolled the previously visible selected row out of view.");
            }
            var local = remote.Select((x, i) => new LocalRecording("local-" + i, x.Title, Path.Combine(root, "synthetic-" + i), x.CreatedAt!.Value, 1000, RecordingState.Done)).ToArray();
            var links = local.Take(5000).Select((x, i) => new ProcessingEntry(x.Id, "profile", x.Title, ProcessingStage.Completed, new(remote[i].Id, 1, 1), UploadCompleted: true)).ToArray();
            var merge = Stopwatch.StartNew(); var merged = LibraryRecording.Merge(local, remote, links, "profile"); var mergeMs = merge.Elapsed.TotalMilliseconds;
            if (merged.Count != 15000) throw new Exception("Large-copy merge lost or duplicated records.");
            await Task.Delay(1000);
            using var current = Process.GetCurrentProcess(); var cpuBefore = current.TotalProcessorTime.TotalMilliseconds;
            var idle = Stopwatch.StartNew(); await Task.Delay(10000); current.Refresh();
            var idleCpu = (current.TotalProcessorTime.TotalMilliseconds - cpuBefore) / idle.Elapsed.TotalMilliseconds * 100;
            var report = new { createdAt = DateTimeOffset.UtcNow, scope = "Production WPF library, synthetic HTTP pages of 50; no network, recording, authentication UI, or cloud-service timing", os = Environment.OSVersion.ToString(), architecture = System.Runtime.InteropServices.RuntimeInformation.ProcessArchitecture.ToString(), logicalProcessors = Environment.ProcessorCount, renderTier = RenderCapability.Tier >> 16,
                count, pageSize, listCalls, samples = results, pageMaxMs = pageTimes.Max(), pageP95Ms = pageTimes.Order().ElementAt((int)(pageTimes.Count * .95)), selectionMs, endRealized, regroupMs, rebuildMs = refreshTimes, mergeLocalCount = local.Length, mergeRemoteCount = remote.Length, mergeLinkCount = links.Length, mergeMs, idleElapsedMs = idle.Elapsed.TotalMilliseconds, idleCpuPercentOneCore = idleCpu, workingSetBytes = current.WorkingSet64, privateBytes = current.PrivateMemorySize64 };
            File.WriteAllText(Path.Combine(root, "results.json"), JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine(JsonSerializer.Serialize(report)); Console.WriteLine("Library profile: " + root);
        }
        finally { window.Close(); }
    }
    private static HttpResponseMessage Json(string body) => new(HttpStatusCode.OK) { Content = new StringContent(body, Encoding.UTF8, "application/json") };
    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => Task.FromResult(send(request));
    }
    private static IEnumerable<DependencyObject> Descendants(DependencyObject node)
    {
        for (var i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
        {
            var child = VisualTreeHelper.GetChild(node, i); yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
}
