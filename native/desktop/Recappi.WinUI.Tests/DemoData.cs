namespace Recappi.WinUI.Tests;

// Store and marketing screenshots (RECAPPI_PREVIEW_DEMO=1): a believable work meeting instead of the
// test fixture. Same ids as the fixture so the preview's audio route still answers.
internal static class DemoData
{
    public static bool Enabled => Environment.GetEnvironmentVariable("RECAPPI_PREVIEW_DEMO") == "1";
    public const string Email = "lin.wang@example.com";
    public const string Session = """{"session":{},"user":{"id":"a","email":"lin.wang@example.com","name":"王琳"}}""";

    public const string Recordings = """
        {"items":[
          {"id":"hike","title":"Q4 产品规划周会","status":"completed","durationMs":2880000,"createdAt":"2026-10-20T02:00:00Z"},
          {"id":"design","title":"客户访谈 · 华东区渠道","status":"completed","durationMs":1860000,"createdAt":"2026-10-19T06:30:00Z"},
          {"id":"review","title":"设计评审：录音库改版","status":"completed","durationMs":2340000,"createdAt":"2026-10-17T07:00:00Z"},
          {"id":"standup","title":"工程站会","status":"completed","durationMs":900000,"createdAt":"2026-10-16T01:30:00Z"},
          {"id":"podcast","title":"播客：AI 工具如何改变工作流","status":"completed","durationMs":3420000,"createdAt":"2026-10-14T12:00:00Z"},
          {"id":"retro","title":"Q3 季度复盘","status":"completed","durationMs":4020000,"createdAt":"2026-10-10T08:00:00Z"}
        ],"nextCursor":null}
        """;

    public const string Transcript = """
        {"text":"我们把公测定在 11 月 18 日。","summary":"会议确定了 Q4 的三项重点：录音库改版、实时字幕多语言和团队空间。公测版定于 11 月 18 日发布，发布前一周冻结功能并完成回归测试。","summaryInsights":{"keyPoints":["录音库改版优先级最高，目标是让回顾一次会议的时间缩短一半。","实时字幕新增日语和韩语，翻译延迟控制在两秒以内。","团队空间进入设计阶段，本季度只做内部试用。"],"decisions":["公测版 11 月 18 日发布，11 月 11 日起功能冻结。","团队空间推迟到明年 Q1 对外开放。"],"actionItems":[{"who":"王珊","what":"周五前更新发布排期并同步给销售"},{"who":"李然","what":"完成字幕延迟压测，输出报告"},{"who":"陈默","what":"整理团队空间的权限方案"}]},"summaryStatus":"completed","segments":[
          {"text":"先过一下 Q4 的重点。录音库改版放在第一位，大家回顾会议的时间还是太长了。","speaker":"王珊","startMs":0,"endMs":7000},
          {"text":"同意。字幕这边日语和韩语已经能跑通，翻译延迟现在大概一点五秒。","speaker":"李然","startMs":7200,"endMs":14500},
          {"text":"那我们把公测定在 11 月 18 日，前一周冻结功能，留出回归测试的时间。","speaker":"王珊","startMs":14800,"endMs":22000},
          {"text":"团队空间我建议先内部试用，权限模型还需要再梳理一轮。","speaker":"陈默","startMs":22300,"endMs":29000}
        ]}
        """;

    public const string Question = "公测定在什么时候？";
    public const string Citation = """{"segmentId":"meeting","startMs":14800,"endMs":22000,"snippet":"把公测定在 11 月 18 日，前一周冻结功能。"}""";
    public const string Answer = "公测版定于 11 月 18 日发布，11 月 11 日起冻结功能，留出一周做回归测试。";
}
