using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace Recappi.Desktop;

public partial class AudioPlayer : UserControl
{
    private readonly MediaPlayer player = new();
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private bool playing;
    private double? pendingSeek;
    public event Action<double?>? PlaybackPositionChanged;
    public double? PlaybackSeconds => Position.IsEnabled ? player.Position.TotalSeconds : null;
    public AudioPlayer()
    {
        InitializeComponent();
        player.MediaOpened += (_, _) =>
        {
            Position.Maximum = player.NaturalDuration.HasTimeSpan ? player.NaturalDuration.TimeSpan.TotalSeconds : 1;
            Position.IsEnabled = true; PlayButton.IsEnabled = true; Status.Text = "";
            if (pendingSeek is { } seconds) { SeekTo(seconds); pendingSeek = null; }
            PlaybackPositionChanged?.Invoke(PlaybackSeconds);
        };
        player.MediaEnded += (_, _) => { Pause(); PlaybackPositionChanged?.Invoke(null); };
        player.MediaFailed += (_, _) => { Pause(); PlayButton.IsEnabled = false; Position.IsEnabled = false; PlaybackPositionChanged?.Invoke(null); Status.Text = "无法播放此音频格式。"; };
        timer.Tick += (_, _) => { if (!Position.IsMouseCaptureWithin && !Position.IsKeyboardFocusWithin) Position.Value = player.Position.TotalSeconds; Time.Text = player.Position.ToString(@"hh\:mm\:ss"); PlaybackPositionChanged?.Invoke(PlaybackSeconds); };
    }
    public void Open(string path, double? seconds = null)
    {
        Clear(); pendingSeek = seconds; Status.Text = "正在打开音频…"; player.Open(new Uri(path));
    }
    public void Clear()
    {
        Pause(); player.Close(); pendingSeek = null; PlayButton.IsEnabled = false; Position.IsEnabled = false; Position.Value = 0; Time.Text = "00:00:00"; Status.Text = "";
        PlaybackPositionChanged?.Invoke(null);
    }
    public void SeekTo(double seconds)
    {
        if (!double.IsFinite(seconds)) return;
        if (!Position.IsEnabled) { pendingSeek = seconds; return; }
        player.Position = TimeSpan.FromSeconds(Math.Clamp(seconds, 0, Position.Maximum)); Position.Value = player.Position.TotalSeconds; Time.Text = player.Position.ToString(@"hh\:mm\:ss");
        PlaybackPositionChanged?.Invoke(PlaybackSeconds);
    }
    private void Pause() { playing = false; timer.Stop(); PlayButton.Content = "播放"; player.Pause(); }
    private void Toggle(object sender, RoutedEventArgs e)
    {
        if (playing) Pause();
        else { player.Play(); playing = true; timer.Start(); PlayButton.Content = "暂停"; }
    }
    private void ChangeSpeed(object sender, SelectionChangedEventArgs e) => player.SpeedRatio = new[] { .75, 1, 1.25, 1.5, 2 }[Math.Clamp(Speed.SelectedIndex, 0, 4)];
    private void SeekMouse(object sender, MouseButtonEventArgs e) => SeekTo(Position.Value);
    private void SeekKey(object sender, KeyEventArgs e) => SeekTo(Position.Value);
}
