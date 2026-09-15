using System.Windows.Controls;
using Recappi.Core;
using Recappi.Desktop;

internal static class CaptionWindowTests
{
    public static async Task RunAsync()
    {
        var retryCount = 0;
        var retryCompletion = new TaskCompletionSource<bool>();
        var window = new CaptionWindow(() => { retryCount++; return retryCompletion.Task; }) { ShowActivated = false }; window.Show(); window.Reset();
        window.Update(new("one", "source", "完整原文", true));
        window.Update(new("one", "translation", "Complete translation", true));
        window.Update(new("two", "source", "正在继续", false));
        window.UpdateStatus(new("live"));
        await Task.Delay(180);
        var transcript = (TextBox)window.FindName("Transcript");
        if (!transcript.Text.Contains("完整原文") || !transcript.Text.Contains("Complete translation")) throw new Exception("Bilingual caption window lost a stream.");
        ((CheckBox)window.FindName("Compact")).IsChecked = true;
        if (!transcript.Text.Contains("完整原文") || !transcript.Text.Contains("正在继续")) throw new Exception("Compact mode lost last complete sentence.");
        ((CheckBox)window.FindName("SourceVisible")).IsChecked = false;
        if (transcript.Text.Contains("完整原文") || !transcript.Text.Contains("Complete translation")) throw new Exception("Caption source visibility did not apply.");
        window.Hide(); window.Update(new("two", "translation", "Arrived while hidden", true)); window.Show();
        await Task.Delay(180);
        if (!transcript.Text.Contains("Arrived while hidden")) throw new Exception("Restoring caption window lost hidden updates.");
        window.UpdateStatus(new("failed", "Connection failed")); await Task.Delay(180);
        var retry = (Button)window.FindName("RetryButton");
        if (!retry.IsVisible) throw new Exception("Caption failure did not expose retry.");
        retry.RaiseEvent(new System.Windows.RoutedEventArgs(Button.ClickEvent));
        retry.RaiseEvent(new System.Windows.RoutedEventArgs(Button.ClickEvent));
        if (retryCount != 1 || retry.IsVisible || !transcript.Text.Contains("Arrived while hidden")) throw new Exception("Caption retry duplicated action or cleared existing text.");
        retryCompletion.SetResult(true); await Task.Delay(30);
        await Task.Run(() => window.UpdateArchiveError("字幕归档写入失败"));
        window.UpdateStatus(new("live")); await Task.Delay(180);
        var archiveStatus = (TextBlock)window.FindName("ArchiveStatus");
        if (!archiveStatus.IsVisible || !archiveStatus.Text.Contains("归档") || !transcript.Text.Contains("Arrived while hidden"))
            throw new Exception("Live status hid the archive failure or cleared caption text.");
        window.Hide(); window.UpdateStatus(new("reconnecting")); window.Show(); await Task.Delay(180);
        if (!archiveStatus.IsVisible) throw new Exception("Reconnect or hide/restore lost the archive warning.");
        window.Reset();
        if (archiveStatus.IsVisible || transcript.Text.Length != 0) throw new Exception("A new recording inherited the old archive warning.");
        window.Close();
        Console.WriteLine("PASS native caption bilingual/compact/visibility toggles and hide/restore.");
    }
}
