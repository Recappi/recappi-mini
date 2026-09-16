using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;
using Recappi.Core;
using Recappi.Desktop;

internal static class TranscriptPanelTests
{
    public static async Task RunAsync(string root, Dispatcher dispatcher)
    {
        using var legacy = JsonDocument.Parse("""{"segmentsJson":"[{\"text\":\"Legacy\",\"speakerLabel\":\"Alice\",\"start\":\"2\",\"end\":5}]"}""");
        var parsed = CloudTranscript.Parse(legacy.RootElement);
        if (parsed.Segments.Single() is not { Speaker: "Alice", StartMs: 2000, EndMs: 5000 }) throw new Exception("Legacy segment timeline/speaker mapping failed.");
        var segments = Enumerable.Range(0, 10000).Select(i => new CloudTranscriptSegment("Segment " + i, i % 2 == 0 ? "Alice" : "Bob", i * 1000L, (i + 1) * 1000L)).ToArray();
        var panel = new TranscriptPanel();
        var window = new Window { Content = panel, Width = 600, Height = 450, ShowActivated = false };
        window.Show();
        try
        {
            panel.ShowTranscript(new CloudTranscript(string.Join('\n', segments.Select(x => x.Text)), "", "") { Segments = segments });
            await dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
            var list = (ListBox)panel.FindName("Segments");
            var realized = Enumerable.Range(0, list.Items.Count).Count(i => list.ItemContainerGenerator.ContainerFromIndex(i) is not null);
            if (list.Items.Count != 10000 || realized is < 1 or > 100) throw new Exception("Long transcript does not virtualize rows: " + realized);
            panel.UpdatePlayback(.5);
            await dispatcher.InvokeAsync(window.UpdateLayout, DispatcherPriority.ApplicationIdle);
            var first = (ListBoxItem)list.ItemContainerGenerator.ContainerFromIndex(0);
            if (panel.ActiveSegment != segments[0] || first.FontWeight != FontWeights.SemiBold) throw new Exception("Playback highlight did not reach visible row.");
            panel.UpdatePlayback(1);
            if (panel.ActiveSegment != segments[1]) throw new Exception("Playback boundary did not advance to next segment.");
            panel.UpdatePlayback(10000);
            if (panel.ActiveSegment is not null) throw new Exception("Playback beyond transcript retained stale highlight.");
            ((ComboBox)panel.FindName("Speakers")).SelectedValue = "Bob";
            if (list.Items.Count != 5000) throw new Exception("Speaker filtering failed.");
            ((TextBox)panel.FindName("Query")).Text = "Segment 9999";
            if (list.Items.Count != 1) throw new Exception("Transcript text search failed.");
            if (!panel.Locate("Segment 9998", null) || list.SelectedItem as CloudTranscriptSegment != segments[9998] || list.Items.Count != 10000) throw new Exception("Citation location did not clear filters and select matching segment.");
            if (!panel.Locate(null, 9999500) || list.SelectedItem as CloudTranscriptSegment != segments[9999]) throw new Exception("Timestamp location failed.");
            var profileStore = new SpeakerProfileStore(System.IO.Path.Combine(root, "speaker-ui"));
            var account = new CloudAccount("https://recappi.test", "speaker-ui", null, "fixture");
            panel.SetSpeakerContext(profileStore, account.Partition, "meeting-a");
            panel.SaveSpeaker("Alice", new SpeakerProfile("Ada", "🎧", "Owner"));
            if (((CloudTranscriptSegment)list.Items[0]).Profile?.Name != "Ada" || ((CloudTranscriptSegment)list.Items[2]).Profile?.Name != "Ada" || ((CloudTranscriptSegment)list.Items[1]).Profile is not null)
                throw new Exception("Speaker edit did not apply to exactly that speaker's segments.");
            if (((CloudTranscriptSegment)list.Items[0]).Speaker != "Alice") throw new Exception("Local speaker edit changed original identity.");
            var editor = new SpeakerEditor(new SpeakerProfile("Ada", "🎧", "Owner"), value => panel.SaveSpeaker("Alice", value)) { Owner = window };
            _ = dispatcher.BeginInvoke(() =>
            {
                ((TextBox)editor.FindName("SpeakerName")).Text = "Ada Lovelace";
                ((Button)editor.FindName("SaveButton")).RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            }, DispatcherPriority.ApplicationIdle);
            if (editor.ShowDialog() != true || profileStore.Load(account.Partition, "meeting-a")["Alice"].Name != "Ada Lovelace") throw new Exception("Native speaker dialog failed to save edited name.");
            panel.SetSpeakerContext(profileStore, account.Partition, "meeting-b");
            panel.ShowTranscript(new CloudTranscript("Segment 0", "", "") { Segments = [segments[0]] });
            if (((CloudTranscriptSegment)list.Items[0]).Profile is not null) throw new Exception("Speaker edit leaked to another meeting.");
            panel.Clear();
            if (list.Items.Count != 0 || panel.Text.Length != 0 || panel.ActiveSegment is not null) throw new Exception("Transcript clear retained account content.");
        }
        finally { window.Close(); }
        await VerifyDialogBoundariesAsync(root, dispatcher);
        Console.WriteLine("PASS native transcript legacy timing, 10,000-row virtualization, speaker/text filters, citation location and clear.");
    }

    private static async Task VerifyDialogBoundariesAsync(string root, Dispatcher dispatcher)
    {
        var account = new CloudAccount("https://recappi.test", "speaker-dialog-a", null, "fixture");
        var other = new CloudAccount("https://recappi.test", "speaker-dialog-b", null, "fixture");
        var transcript = new CloudTranscript("Original segment", "", "")
            { Segments = [new("Original segment", "Speaker 1", 0, 1000)] };
        foreach (var scenario in new[] { "cancel", "recording-change", "account-change", "clear", "validation-retry" })
        {
            var store = new SpeakerProfileStore(System.IO.Path.Combine(root, "speaker-dialog-" + scenario));
            var panel = new TranscriptPanel();
            var owner = new Window { Content = panel, Width = 650, Height = 450, ShowActivated = false };
            owner.Show();
            try
            {
                panel.SetSpeakerContext(store, account.Partition, "meeting-a"); panel.ShowTranscript(transcript);
                ((ListBox)panel.FindName("Segments")).SelectedIndex = 0;
                await dispatcher.InvokeAsync(owner.UpdateLayout, DispatcherPriority.ApplicationIdle);
                var editButton = Descendants(panel).OfType<Button>().Single(x => Equals(x.Content, "编辑说话人"));
                var interaction = dispatcher.InvokeAsync(() =>
                {
                    var editor = Application.Current.Windows.OfType<SpeakerEditor>().Single(x => x.Owner == owner);
                    try
                    {
                        var name = (TextBox)editor.FindName("SpeakerName");
                        var save = (Button)editor.FindName("SaveButton");
                        name.Text = "Local display name";
                        if (scenario == "cancel") return; // Finally closes an edited dialog without saving.
                        if (scenario == "recording-change") { panel.SetSpeakerContext(store, account.Partition, "meeting-b"); panel.ShowTranscript(transcript); }
                        if (scenario == "account-change") { panel.SetSpeakerContext(store, other.Partition, "meeting-a"); panel.ShowTranscript(transcript); }
                        if (scenario == "clear") panel.Clear();
                        if (scenario == "validation-retry") name.Text = "   ";
                        save.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                        if (!editor.IsVisible || string.IsNullOrWhiteSpace(((TextBlock)editor.FindName("Error")).Text))
                            throw new Exception("Speaker dialog did not retain an actionable error: " + scenario);
                        if (store.Load(account.Partition, "meeting-a").Count != 0 || store.Load(account.Partition, "meeting-b").Count != 0 || store.Load(other.Partition, "meeting-a").Count != 0)
                            throw new Exception("Rejected speaker save wrote profile data: " + scenario);
                        if (scenario == "validation-retry")
                        {
                            name.Text = "Local display name";
                            save.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                            if (editor.IsVisible || store.Load(account.Partition, "meeting-a")["Speaker 1"].Name != name.Text)
                                throw new Exception("Valid speaker edit could not recover after validation error.");
                        }
                    }
                    finally { if (editor.IsVisible) editor.Close(); }
                }, DispatcherPriority.ApplicationIdle);
                // Exercise the production handler and its captured context across ShowDialog's nested dispatcher.
                editButton.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
                await interaction.Task;
                if (scenario == "cancel" && store.Load(account.Partition, "meeting-a").Count != 0)
                    throw new Exception("Closing an edited speaker dialog saved the draft.");
            }
            finally { owner.Close(); }
        }
        Console.WriteLine("PASS production speaker dialog rejects recording/account changes and clear, cancels edited drafts, and permits corrected input after validation failure.");
    }

    private static IEnumerable<DependencyObject> Descendants(DependencyObject root)
    {
        for (var index = 0; index < System.Windows.Media.VisualTreeHelper.GetChildrenCount(root); index++)
        {
            var child = System.Windows.Media.VisualTreeHelper.GetChild(root, index);
            yield return child;
            foreach (var descendant in Descendants(child)) yield return descendant;
        }
    }
}
