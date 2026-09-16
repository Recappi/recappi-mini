using System.IO;
using System.Windows;
using System.Windows.Controls;
using Recappi.Core;
using Recappi.Desktop;

internal static class LocalRemovalTests
{
    public static async Task RunAsync(string root)
    {
        var store = new LocalRecordingStore(Path.Combine(root, "local-removal"));
        LocalRecording Create(string title)
        {
            var item = store.Create(title);
            using (var wave = new PcmWaveWriter(item.AudioPath))
                for (var i = 0; i < 30; i++) wave.Append(new float[4800]);
            item = item with { State = RecordingState.Done, DurationMs = 3000 };
            store.Save(item);
            File.WriteAllText(store.CaptionPath(item), "preserved captions");
            return item;
        }
        var first = Create("Remove this"); var other = Create("Keep this");
        var originals = Directory.EnumerateFiles(first.Directory).Concat(Directory.EnumerateFiles(other.Directory))
            .ToDictionary(path => path, File.ReadAllBytes);
        using var view = new LocalLibraryView(store);
        var host = new Window { Content = view, Width = 850, Height = 700, ShowActivated = false };
        host.Show();
        try
        {
            foreach (var approve in new[] { false, true })
            {
                var dialog = new RemoveLocalRecordingDialog("移除验证样本") { Owner = host };
                Exception? failure = null;
                dialog.ContentRendered += (_, _) =>
                {
                    try
                    {
                        var keep = (Button)dialog.FindName("KeepButton");
                        if (!keep.IsDefault || !keep.IsCancel || dialog.WindowStartupLocation != WindowStartupLocation.CenterOwner)
                            throw new Exception("Removal confirmation lost safe default or owner positioning.");
                        if (Math.Abs(dialog.Left + dialog.ActualWidth / 2 - host.Left - host.ActualWidth / 2) > 3 ||
                            Math.Abs(dialog.Top + dialog.ActualHeight / 2 - host.Top - host.ActualHeight / 2) > 3)
                            throw new Exception("Removal dialog did not center over its actual owner.");
                        if (approve) ((Button)dialog.FindName("RemoveButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                        else dialog.Close();
                    }
                    catch (Exception error) { failure = error; dialog.Close(); }
                };
                var result = dialog.ShowDialog() == true;
                if (failure is not null) throw failure;
                if (result != approve) throw new Exception("Removal dialog returned incorrect decision.");
            }
            view.RefreshRecordings(first.Id);
            var remove = (Button)view.FindName("RemoveButton");
            var play = (Button)view.FindName("PlayButton");
            var position = (Slider)view.FindName("Position");
            void Click() => remove.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            view.ConfirmRemove = _ => false;
            Click();
            if (store.List().Count != 2) throw new Exception("Cancelled removal changed library.");
            view.ConfirmRemove = _ => { view.SelectEntry(other.Id); return true; };
            Click();
            if (store.List().Count != 2) throw new Exception("Late confirmation removed another selection.");
            view.SelectEntry(first.Id);
            view.ConfirmRemove = _ => true;
            for (var i = 0; i < 100 && !position.IsEnabled; i++) await Task.Delay(50);
            if (!position.IsEnabled) throw new Exception("Removal fixture media did not open.");
            play.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            using (var locked = new FileStream(Path.Combine(first.Directory, "desktop-session.json"), FileMode.Open, FileAccess.Read, FileShare.None))
                Click();
            if (view.Entries.Count != 2 || !Equals(play.Content, "暂停"))
                throw new Exception("Failed removal lost list or stopped playback.");
            var marker = Path.Combine(first.Directory, "library-removed.json");
            Directory.CreateDirectory(marker);
            Click();
            if (view.Entries.Count != 2 || store.List().Count != 2 || !Equals(play.Content, "暂停"))
                throw new Exception("Failed marker commit lost library or playback.");
            Directory.Delete(marker);
            Click();
            if (view.Entries.Any(x => x.Id == first.Id) || !Equals(play.Content, "播放"))
                throw new Exception("Successful removal retained entry or playback state.");
            using (var audio = new FileStream(first.AudioPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None)) { }
            foreach (var (path, bytes) in originals)
                if (!File.ReadAllBytes(path).SequenceEqual(bytes)) throw new Exception("Removal modified original files.");
            store.Save(first); // A late metadata update must not resurrect the entry.
            var reopened = new LocalRecordingStore(store.Root);
            if (reopened.List().Single().Id != other.Id) throw new Exception("Removal did not persist independently of metadata.");
            await view.ImportFileAsync(first.AudioPath);
            if (view.Entries.Count != 2 || !view.Entries.Any(x => x.Id == first.Id) ||
                ((TextBlock)view.FindName("Heading")).Text != first.Title)
                throw new Exception("Reimport did not restore and select the original removed recording.");
            var active = store.Create("Active");
            var rejected = false;
            try { store.RemoveFromLibrary(active with { State = RecordingState.Done }); }
            catch (InvalidOperationException) { rejected = true; }
            if (!rejected || !store.List().Any(x => x.Id == active.Id)) throw new Exception("Stale state hid active recording.");
            Console.WriteLine("PASS local removal: cancel, changed selection, read/write failures, playing release, preserved files and reopened store: " + root);
        }
        finally { host.Close(); }
    }
}
