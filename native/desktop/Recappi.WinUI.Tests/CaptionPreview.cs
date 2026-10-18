using Microsoft.UI.Xaml;
using Recappi.Core;

namespace Recappi.WinUI.Tests;

internal static class CaptionPreview
{
    public static async Task Run()
    {
        var complete = new TaskCompletionSource();
        var fixture = new DesktopWindow("Recappi WinUI · 字幕验证", 600, 290);
        var captions = new CaptionWindow(() => Task.CompletedTask);
        fixture.Body.Children.Add(Ui.Text("受控字幕样本 · 使用生产 WinUI 窗口；不连接云服务。"));
        fixture.Body.Children.Add(Ui.Button("双语短句", () =>
        {
            captions.Reset(true); captions.SetStatus("实时字幕");
            captions.Update(new("a", "source", "Keep recording while the panel is hidden.", true, new("preview", 0)));
            captions.Update(new("a", "translation", "隐藏面板后，录音仍会继续。", true, new("preview", 0)));
            captions.ShowWithoutActivation(); return Task.CompletedTask;
        }, fixture));
        fixture.Body.Children.Add(Ui.Button("长句与失败", () =>
        {
            captions.Reset(true); captions.SetStatus("连接恢复中 · 本机录音继续");
            captions.Update(new("long", "source", string.Join(" ", Enumerable.Repeat("A long sentence must wrap and remain readable in the compact caption panel.", 6)), true, new("preview", 0)));
            captions.Update(new("long", "translation", string.Concat(Enumerable.Repeat("长字幕应当换行，紧凑面板也必须保留可读内容，不能把最后一行裁掉。", 6)), true, new("preview", 0)));
            captions.Update(new("failed", "source", "Partial sentence", true, new("preview", 1), IsFailed: true));
            captions.ShowWithoutActivation(); return Task.CompletedTask;
        }, fixture));
        fixture.Body.Children.Add(Ui.Button("前驱顺序与历史", () =>
        {
            captions.Reset(true); captions.SetStatus("实时字幕 · 已按前驱顺序修复");
            captions.Update(new("b", "source", "Bravo", true, new("preview", 0)));
            captions.Update(new("a", "source", "Alpha", true, new("preview", 1)));
            captions.UpdateBatch([new("a", "source", "Alpha", true, new("preview", 0)), new("b", "source", "Bravo", true, new("preview", 1)), new("c", "source", "Charlie", true, new("preview", 2))]);
            captions.Update(new("t", "translation", "甲、乙、丙：按原句顺序展示。", true, new("preview", 2)));
            captions.ShowWithoutActivation(); return Task.CompletedTask;
        }, fixture));
        fixture.Closed += (_, _) => complete.TrySetResult();
        fixture.Show(); captions.ShowWithoutActivation();
        var finished = await Task.WhenAny(complete.Task, Task.Delay(TimeSpan.FromMinutes(8)));
        captions.Close();
        if (finished != complete.Task) fixture.Close();
    }
}
