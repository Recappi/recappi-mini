using System;
using System.Windows;
using Recappi.Core;

namespace Recappi.Desktop;

public partial class SpeakerEditor : Window
{
    private readonly Action<SpeakerProfile> save;
    public SpeakerEditor(SpeakerProfile profile, Action<SpeakerProfile> save)
    {
        DesktopTheme.EnsureResources();
        InitializeComponent(); this.save = save;
        SpeakerName.Text = profile.Name; Emoji.Text = profile.Emoji; Note.Text = profile.Note ?? "";
        Loaded += (_, _) => { SpeakerName.Focus(); SpeakerName.SelectAll(); };
    }
    private void Save(object sender, RoutedEventArgs e)
    {
        try { save(new SpeakerProfile(SpeakerName.Text, Emoji.Text, Note.Text)); DialogResult = true; }
        catch (ArgumentException error) { Error.Text = error.Message; }
        catch (Exception) { Error.Text = "保存失败，请检查本地存储后重试。"; }
    }
}
