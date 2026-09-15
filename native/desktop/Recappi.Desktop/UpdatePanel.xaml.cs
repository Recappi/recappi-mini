using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using Recappi.Core;

namespace Recappi.Desktop;

public partial class UpdatePanel : UserControl
{
    private readonly Func<DesktopUpdates> createClient;
    private readonly string currentVersion;
    private readonly string runtime;
    private CancellationTokenSource? operation;
    private DesktopRelease? available;
    private string? downloaded;
    public static string CurrentVersion => typeof(UpdatePanel).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion.Split('+')[0]
        ?? typeof(UpdatePanel).Assembly.GetName().Version?.ToString(3) ?? "0.0.0";

    public UpdatePanel() : this(() => new DesktopUpdates(), CurrentVersion, RuntimeInformation.ProcessArchitecture == Architecture.Arm64 ? "win-arm64" : "win-x64") { }
    public UpdatePanel(Func<DesktopUpdates> createClient, string currentVersion, string runtime)
    {
        InitializeComponent(); this.createClient = createClient; this.currentVersion = currentVersion; this.runtime = runtime;
        Unloaded += (_, _) => operation?.Cancel();
    }
    private void SetBusy(bool value)
    {
        CheckButton.IsEnabled = !value;
        DownloadButton.IsEnabled = !value && available is not null;
        CancelButton.Visibility = value ? Visibility.Visible : Visibility.Collapsed;
    }
    private async void Check(object sender, RoutedEventArgs e) => await CheckAsync();
    public async Task CheckAsync()
    {
        if (operation is not null) return;
        using var cancellation = new CancellationTokenSource(); operation = cancellation;
        available = null; SetBusy(true); UpdateStatus.Text = "正在检查官方发布…";
        try
        {
            using var client = createClient();
            var result = await client.CheckAsync(currentVersion, runtime, cancellation.Token);
            if (cancellation.IsCancellationRequested) return;
            available = result.Update;
            UpdateStatus.Text = available is { } release ? $"发现 {release.Version}（{release.Size / 1024d / 1024d:F1} MB）。当前 {currentVersion}。"
                : result.HasCompatibleRelease ? "没有找到更新的可验证 Windows 包。" : "官方发布源暂未提供适合本机的可验证 Windows 包。";
        }
        catch (OperationCanceledException) { UpdateStatus.Text = cancellation.IsCancellationRequested ? "检查已取消。" : "检查超时，请重试。"; }
        catch (Exception) { UpdateStatus.Text = "无法检查更新，请稍后重试或打开官方发布页。"; }
        finally { operation = null; SetBusy(false); }
    }
    private async void Download(object sender, RoutedEventArgs e)
    {
        if (available is null || operation is not null) return;
        var dialog = new SaveFileDialog { Title = "保存 Windows 更新包", FileName = available.FileName, Filter = "ZIP 更新包|*.zip", AddExtension = true, OverwritePrompt = true };
        if (dialog.ShowDialog(Window.GetWindow(this)) == true) await DownloadAsync(dialog.FileName);
    }
    public async Task DownloadAsync(string destination)
    {
        if (available is null || operation is not null) return;
        using var cancellation = new CancellationTokenSource(); operation = cancellation;
        SetBusy(true); DownloadProgress.Value = 0; DownloadProgress.Visibility = Visibility.Visible;
        UpdateStatus.Text = "正在下载并验证更新包…";
        try
        {
            using var client = createClient();
            var progress = new Progress<double>(value => { if (operation == cancellation && !cancellation.IsCancellationRequested) DownloadProgress.Value = value; });
            downloaded = await client.DownloadAsync(available, destination, progress, cancellation.Token);
            OpenPackageButton.Visibility = Visibility.Visible;
            UpdateStatus.Text = "更新包已下载并通过完整性校验，尚未安装。请结束录音并退出应用，将 ZIP 解压到新目录后启动；原目录和录音文件可保留。";
        }
        catch (OperationCanceledException) { UpdateStatus.Text = cancellation.IsCancellationRequested ? "下载已取消，原文件保留。" : "下载超时，原文件保留，请重试。"; }
        catch (Exception) { UpdateStatus.Text = "下载或校验失败，原文件保留，请重试。"; }
        finally { operation = null; SetBusy(false); DownloadProgress.Visibility = Visibility.Collapsed; }
    }
    private void Cancel(object sender, RoutedEventArgs e) => operation?.Cancel();
    private void OpenRelease(object sender, RoutedEventArgs e)
    {
        try { Process.Start(new ProcessStartInfo((available?.Page ?? DesktopUpdates.ReleasesPage).AbsoluteUri) { UseShellExecute = true }); }
        catch (Exception) { UpdateStatus.Text = "无法打开浏览器，请稍后重试。"; }
    }
    private void OpenPackage(object sender, RoutedEventArgs e)
    {
        if (downloaded is null) return;
        try { Process.Start(new ProcessStartInfo(Path.GetDirectoryName(downloaded)!) { UseShellExecute = true }); }
        catch (Exception) { UpdateStatus.Text = "无法打开下载目录，请在保存时选择的目录查找更新包。"; }
    }
}
