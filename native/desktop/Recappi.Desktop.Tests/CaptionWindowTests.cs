using System.IO;
using System.Windows.Controls;
using Recappi.Core;
using Recappi.Desktop;

internal static class CaptionWindowTests
{
    public static async Task RunAsync()
    {
        await DelayedRetryCannotReplaceStateAsync();
        await BothStreamsRemainReadableAsync();
        await SubmittedOrderAsync();
        await FailedItemsAsync();
        var retryCount = 0;
        var retryCompletion = new TaskCompletionSource<bool>();
        var window = new CaptionWindow(() => { retryCount++; return retryCompletion.Task; }) { ShowActivated = false }; window.Show(); window.Reset();
        window.Update(new("one", "source", "完整原文", true));
        window.Update(new("one", "translation", "Complete translation", true));
        window.Update(new("two", "source", "正在继续", false));
        window.UpdateStatus(new("live"));
        await Task.Delay(180);
        var transcript = (TextBox)window.FindName("SourceTranscript");
        var translation = (TextBox)window.FindName("TranslationTranscript");
        if (!transcript.Text.Contains("完整原文") || !translation.Text.Contains("Complete translation")) throw new Exception("Bilingual caption window lost a stream.");
        ((CheckBox)window.FindName("Compact")).IsChecked = true;
        if (!transcript.Text.Contains("完整原文") || !transcript.Text.Contains("正在继续")) throw new Exception("Compact mode lost last complete sentence.");
        ((CheckBox)window.FindName("SourceVisible")).IsChecked = false;
        if (transcript.IsVisible || !translation.IsVisible || !translation.Text.Contains("Complete translation")) throw new Exception("Caption source visibility did not apply.");
        ((CheckBox)window.FindName("TranslationVisible")).IsChecked = false;
        if (((CheckBox)window.FindName("TranslationVisible")).IsChecked != true) throw new Exception("The last visible caption stream could be hidden.");
        window.ConfigureTranslation(false); window.UpdateLayout();
        if (!transcript.IsVisible || translation.IsVisible || ((CheckBox)window.FindName("TranslationVisible")).IsEnabled)
            throw new Exception("Transcription-only captions reserved an empty translation pane.");
        window.ConfigureTranslation(true); window.UpdateLayout();
        if (!translation.IsVisible || !((CheckBox)window.FindName("TranslationVisible")).IsEnabled)
            throw new Exception("A later bilingual recording could not restore translation.");
        window.Hide(); window.Update(new("two", "translation", "Arrived while hidden", true)); window.Show();
        await Task.Delay(180);
        if (!translation.Text.Contains("Arrived while hidden")) throw new Exception("Restoring caption window lost hidden updates.");
        window.UpdateStatus(new("failed", "Connection failed")); await Task.Delay(180);
        var retry = (Button)window.FindName("RetryButton");
        if (!retry.IsVisible) throw new Exception("Caption failure did not expose retry.");
        retry.RaiseEvent(new System.Windows.RoutedEventArgs(Button.ClickEvent));
        retry.RaiseEvent(new System.Windows.RoutedEventArgs(Button.ClickEvent));
        if (retryCount != 1 || retry.IsVisible || !translation.Text.Contains("Arrived while hidden")) throw new Exception("Caption retry duplicated action or cleared existing text.");
        retryCompletion.SetResult(true); await Task.Delay(30);
        await Task.Run(() => window.UpdateArchiveError("字幕归档写入失败"));
        window.UpdateStatus(new("live")); await Task.Delay(180);
        var archiveStatus = (TextBlock)window.FindName("ArchiveStatus");
        if (!archiveStatus.IsVisible || !archiveStatus.Text.Contains("归档") || !translation.Text.Contains("Arrived while hidden"))
            throw new Exception("Live status hid the archive failure or cleared caption text.");
        window.Hide(); window.UpdateStatus(new("reconnecting")); window.Show(); await Task.Delay(180);
        if (!archiveStatus.IsVisible) throw new Exception("Reconnect or hide/restore lost the archive warning.");
        window.Reset();
        if (archiveStatus.IsVisible || transcript.Text.Length != 0 || translation.Text.Length != 0) throw new Exception("A new recording inherited the old archive warning.");
        window.Close();
        Console.WriteLine("PASS native caption bilingual/compact/visibility toggles and hide/restore.");
    }

    private static async Task FailedItemsAsync()
    {
        var window = new CaptionWindow { ShowActivated = false };
        try
        {
            window.Show(); window.Reset();
            window.Update(new("partial", "source", "Incomplete words", false, new("session", 1)));
            await Task.Delay(180);
            window.Update(new("partial", "source", "Incomplete words", false, new("session", 1), IsFailed: true));
            await Task.Delay(180);
            var text = (TextBox)window.FindName("SourceTranscript");
            if (text.Text != "Incomplete words［字幕未完成］") throw new Exception("Failed partial caption remained indistinguishable from ordinary transcript text.");
            ((CheckBox)window.FindName("Compact")).IsChecked = true;
            window.Update(new("next", "source", "Next words", false, new("session", 2)));
            await Task.Delay(180);
            if (text.Text != "Incomplete words［字幕未完成］ Next words") throw new Exception("Failed caption remained pending and displaced the actual current sentence.");
            window.Hide();
            window.Update(new("next", "source", "", false, new("session", 2), IsFailed: true));
            window.Show(); await Task.Delay(180);
            if (text.Text != "［此段字幕未能识别］") throw new Exception("Empty failed caption disappeared or retained stale text after restore.");
            window.Update(new("success", "source", "Later success", true, new("session", 3)));
            await Task.Delay(180);
            if (text.Text != "Later success") throw new Exception("Later successful captions could not follow a failed item.");
            ((CheckBox)window.FindName("Compact")).IsChecked = false;
            if (!text.Text.Contains("字幕未完成") || !text.Text.Contains("此段字幕未能识别")) throw new Exception("Expanded history silently lost earlier caption gaps.");
            window.Reset();
            if (text.Text.Length != 0) throw new Exception("New recording retained an old caption failure marker.");
        }
        finally { window.Close(); }
        Console.WriteLine("PASS partial/empty failed caption markers, compact terminal state, later success, restore and reset.");
    }

    private static async Task SubmittedOrderAsync()
    {
        var window = new CaptionWindow { ShowActivated = false };
        try
        {
            window.Show(); window.Reset();
            window.Update(new("third", "source", "Third", true, new("session", 3)));
            await Task.Delay(180);
            window.Update(new("first", "source", "First", true, new("session", 1)));
            window.Update(new("second", "source", "Second", true, new("session", 2)));
            await Task.Delay(180);
            var text = (TextBox)window.FindName("SourceTranscript");
            if (text.Text != "First\n\nSecond\n\nThird") throw new Exception("Expanded captions used completion arrival order.");
            ((CheckBox)window.FindName("Compact")).IsChecked = true;
            if (text.Text != "Third") throw new Exception("Compact captions showed an older late completion.");
            window.Hide();
            window.Update(new("fourth", "source", "Fourth", false, new("session", 4)));
            window.Show(); await Task.Delay(180);
            if (text.Text != "Third Fourth") throw new Exception("Ordered compact captions lost the current pending sentence after restore.");
            window.Reset(); window.Hide();
            ((CheckBox)window.FindName("Compact")).IsChecked = false;
            for (var i = 300; i >= 1; i--)
                window.Update(new("bulk-" + i, "source", "Sentence " + i, true, new("bulk", i)));
            window.Show(); await Task.Delay(180);
            if (text.Text != string.Join("\n\n", Enumerable.Range(101, 200).Select(i => "Sentence " + i)))
                throw new Exception("Caption buffer eviction retained old late sentences instead of the latest 200.");
        }
        finally { window.Close(); }
        Console.WriteLine("PASS caption window preserves submitted sentence order across delayed completion, compact mode and hide/restore.");
    }

    private static async Task DelayedRetryCannotReplaceStateAsync()
    {
        foreach (var next in new[] { "reset", "live", "stopped", "failed", "closed", "unchanged" })
        foreach (var throws in new[] { false, true })
        {
            var pending = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            var calls = 0;
            var window = new CaptionWindow(() => { calls++; return pending.Task; }) { ShowActivated = false };
            try
            {
                window.Show();
                window.UpdateStatus(new("failed", "Original failure"));
                await Task.Delay(180);
                var retry = (Button)window.FindName("RetryButton");
                retry.RaiseEvent(new System.Windows.RoutedEventArgs(Button.ClickEvent));
                if (calls != 1) throw new Exception("Caption retry fixture did not enter its pending operation.");
                if (next == "reset") window.Reset();
                else if (next is not "closed" and not "unchanged") window.UpdateStatus(new(next, "New session status"));
                window.Update(new("new", "source", "New session caption", true));
                await Task.Delay(180);
                if (next == "closed") window.Close();
                var expected = ((TextBlock)window.FindName("Status")).Text;
                var expectedRetry = retry.Visibility;
                if (throws) pending.SetException(new IOException("Controlled old retry failure"));
                else pending.SetResult(false);
                await Task.Delay(180);
                if (next == "unchanged")
                {
                    if (!retry.IsVisible || ((TextBlock)window.FindName("Status")).Text == expected)
                        throw new Exception("A current caption retry failure did not permit retry.");
                }
                else if (((TextBlock)window.FindName("Status")).Text != expected || retry.Visibility != expectedRetry ||
                    !((TextBox)window.FindName("SourceTranscript")).Text.Contains("New session caption"))
                    throw new Exception("Delayed caption retry replaced a newer state: " + next + "/" + throws);
            }
            finally { pending.TrySetResult(false); window.Close(); }
        }
        Console.WriteLine("PASS delayed caption retry failure cannot replace reset, connected, stopped, newer failure or closed state; current failure still permits retry.");
    }

    private static async Task BothStreamsRemainReadableAsync()
    {
        var window = new CaptionWindow(() => Task.FromResult(false)) { ShowActivated = false };
        try
        {
            window.Show(); window.Reset();
            window.Update(new("long", "source", string.Concat(Enumerable.Repeat("The team will review the design. ", 80)) + "SOURCE-END", false));
            window.Update(new("long", "translation", string.Concat(Enumerable.Repeat("团队将审核设计。", 100)) + "译文末尾", false));
            window.UpdateStatus(new("live"));
            foreach (var width in new[] { 650d, 360d })
            foreach (var compact in new[] { false, true })
            {
                window.Width = width;
                ((CheckBox)window.FindName("Compact")).IsChecked = compact;
                await Task.Delay(180);
                window.UpdateLayout();
                foreach (var marker in new[] { "SOURCE-END", "译文末尾" })
                {
                    var text = Descendants(window).OfType<TextBox>().Single(x => x.IsVisible && x.Text.Contains(marker));
                    var bounds = text.GetRectFromCharacterIndex(text.Text.IndexOf(marker, StringComparison.Ordinal) + marker.Length - 1);
                    if (bounds.IsEmpty || bounds.Top < -1 || bounds.Bottom > text.ActualHeight + 1 || bounds.Left < -1 || bounds.Right > text.ActualWidth + 1)
                        throw new Exception($"Visible {(compact ? "compact" : "expanded")} captions ({width}) scrolled {marker} outside its viewport: {bounds}; viewport {text.ActualWidth}x{text.ActualHeight}; offset {text.VerticalOffset}/{text.ExtentHeight}.");
                    if (compact)
                    {
                        var previousLine = text.GetLineIndexFromCharacterIndex(text.Text.Length - 1) - 1;
                        var previous = text.GetRectFromCharacterIndex(text.GetCharacterIndexFromLineIndex(previousLine));
                        if (previous.Bottom > 0.5) throw new Exception($"Compact stream exposes a partial preceding line: {previous.Bottom} pixels.");
                    }
                }
            }
            ((CheckBox)window.FindName("Compact")).IsChecked = false;
            window.Height = 500;
            ((CheckBox)window.FindName("TranslationVisible")).IsChecked = false;
            if (window.Height != 500) throw new Exception("Changing stream visibility reset the user-resized window.");
            ((CheckBox)window.FindName("Compact")).IsChecked = true;
            ((CheckBox)window.FindName("Compact")).IsChecked = false;
            if (window.Height != 500) throw new Exception("Expanding captions lost the user's prior height.");

            var source = (TextBox)window.FindName("SourceTranscript");
            await Task.Delay(180); source.ScrollToHome(); await Task.Delay(30);
            window.Update(new("next", "source", "A new sentence while reading earlier captions.", false));
            await Task.Delay(180);
            if (source.VerticalOffset > 1) throw new Exception("A new caption pulled the reader away from earlier text.");
            ((CheckBox)window.FindName("TranslationVisible")).IsChecked = true;
            ((CheckBox)window.FindName("Compact")).IsChecked = true;
            window.UpdateArchiveError("字幕归档写入失败；本地音频仍会保留。");
            window.UpdateStatus(new("failed", "字幕连接授权失败，本地录音继续。"));
            await Task.Delay(180); window.UpdateLayout();
            foreach (var text in Descendants(window).OfType<TextBox>().Where(x => x.IsVisible))
            {
                var pane = (System.Windows.FrameworkElement)((System.Windows.Controls.DockPanel)text.Parent).Parent;
                if (text.ActualHeight < 28 || text.ActualHeight > pane.ActualHeight)
                    throw new Exception($"Caption failure controls squeezed a compact stream out of view: text {text.ActualHeight}, pane {pane.ActualHeight}, window {window.ActualHeight}, minimum {window.MinHeight}.");
            }
        }
        finally { window.Close(); }
    }

    private static IEnumerable<System.Windows.DependencyObject> Descendants(System.Windows.DependencyObject root)
    {
        for (var index = 0; index < System.Windows.Media.VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = System.Windows.Media.VisualTreeHelper.GetChild(root, index);
            yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
}
