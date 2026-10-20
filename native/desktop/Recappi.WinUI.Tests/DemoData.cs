namespace Recappi.WinUI.Tests;

// Store and marketing screenshots (RECAPPI_PREVIEW_DEMO=1): a believable work meeting instead of the
// test fixture. Same ids as the fixture so the preview's audio route still answers.
internal static class DemoData
{
    // RECAPPI_PREVIEW_DEMO=1 → Chinese meeting content; =en → English content for the en-US listing.
    public static bool Enabled => Environment.GetEnvironmentVariable("RECAPPI_PREVIEW_DEMO") is "1" or "en";
    public static bool English => Environment.GetEnvironmentVariable("RECAPPI_PREVIEW_DEMO") == "en";
    public const string Email = "lin.wang@example.com";
    private const string SessionZh = """{"session":{},"user":{"id":"a","email":"lin.wang@example.com","name":"王琳"}}""";

    private const string RecordingsZh = """
        {"items":[
          {"id":"hike","title":"Q4 产品规划周会","status":"completed","durationMs":2880000,"createdAt":"2026-10-20T02:00:00Z"},
          {"id":"design","title":"客户访谈 · 华东区渠道","status":"completed","durationMs":1860000,"createdAt":"2026-10-19T06:30:00Z"},
          {"id":"review","title":"设计评审：录音库改版","status":"completed","durationMs":2340000,"createdAt":"2026-10-17T07:00:00Z"},
          {"id":"standup","title":"工程站会","status":"completed","durationMs":900000,"createdAt":"2026-10-16T01:30:00Z"},
          {"id":"podcast","title":"播客：AI 工具如何改变工作流","status":"completed","durationMs":3420000,"createdAt":"2026-10-14T12:00:00Z"},
          {"id":"retro","title":"Q3 季度复盘","status":"completed","durationMs":4020000,"createdAt":"2026-10-10T08:00:00Z"}
        ],"nextCursor":null}
        """;

    private const string TranscriptZh = """
        {"text":"我们把公测定在 11 月 18 日。","summary":"会议确定了 Q4 的三项重点：录音库改版、实时字幕多语言和团队空间。公测版定于 11 月 18 日发布，发布前一周冻结功能并完成回归测试。","summaryInsights":{"keyPoints":["录音库改版优先级最高，目标是让回顾一次会议的时间缩短一半。","实时字幕新增日语和韩语，翻译延迟控制在两秒以内。","团队空间进入设计阶段，本季度只做内部试用。"],"decisions":["公测版 11 月 18 日发布，11 月 11 日起功能冻结。","团队空间推迟到明年 Q1 对外开放。"],"actionItems":[{"who":"王珊","what":"周五前更新发布排期并同步给销售"},{"who":"李然","what":"完成字幕延迟压测，输出报告"},{"who":"陈默","what":"整理团队空间的权限方案"}]},"summaryStatus":"completed","segments":[
          {"text":"先过一下 Q4 的重点。录音库改版放在第一位，大家回顾会议的时间还是太长了。","speaker":"王珊","startMs":0,"endMs":7000},
          {"text":"同意。字幕这边日语和韩语已经能跑通，翻译延迟现在大概一点五秒。","speaker":"李然","startMs":7200,"endMs":14500},
          {"text":"那我们把公测定在 11 月 18 日，前一周冻结功能，留出回归测试的时间。","speaker":"王珊","startMs":14800,"endMs":22000},
          {"text":"团队空间我建议先内部试用，权限模型还需要再梳理一轮。","speaker":"陈默","startMs":22300,"endMs":29000}
        ]}
        """;

    private const string QuestionZh = "公测定在什么时候？";
    private const string CitationZh = """{"segmentId":"meeting","startMs":14800,"endMs":22000,"snippet":"把公测定在 11 月 18 日，前一周冻结功能。"}""";
    private const string AnswerZh = "公测版定于 11 月 18 日发布，11 月 11 日起冻结功能，留出一周做回归测试。";

    public static string Session => English ? SessionEn : SessionZh;
    public static string Recordings => English ? RecordingsEn : RecordingsZh;
    public static string Transcript => English ? TranscriptEn : TranscriptZh;
    public static string Question => English ? "When is the public beta?" : QuestionZh;
    public static string Citation => English ? CitationEn : CitationZh;
    public static string Answer => English ? "The public beta ships on November 18, with a feature freeze from November 11 to leave a week for regression testing." : AnswerZh;

    private const string SessionEn = """{"session":{},"user":{"id":"a","email":"maya.chen@example.com","name":"Maya Chen"}}""";
    private const string RecordingsEn = """
        {"items":[
          {"id":"hike","title":"Q4 Product Planning","status":"completed","durationMs":2880000,"createdAt":"2026-10-20T02:00:00Z"},
          {"id":"design","title":"Customer Interview · Retail Partners","status":"completed","durationMs":1860000,"createdAt":"2026-10-19T06:30:00Z"},
          {"id":"review","title":"Design Review: Library Redesign","status":"completed","durationMs":2340000,"createdAt":"2026-10-17T07:00:00Z"},
          {"id":"standup","title":"Engineering Stand-up","status":"completed","durationMs":900000,"createdAt":"2026-10-16T01:30:00Z"},
          {"id":"podcast","title":"Podcast: How AI Tools Change Work","status":"completed","durationMs":3420000,"createdAt":"2026-10-14T12:00:00Z"},
          {"id":"retro","title":"Q3 Retrospective","status":"completed","durationMs":4020000,"createdAt":"2026-10-10T08:00:00Z"}
        ],"nextCursor":null}
        """;
    private const string TranscriptEn = """
        {"text":"Let's lock the public beta for November 18.","summary":"The team agreed on three Q4 priorities: the library redesign, more live-caption languages, and team spaces. The public beta ships on November 18, with a feature freeze one week earlier for regression testing.","summaryInsights":{"keyPoints":["The library redesign comes first: reviewing a meeting should take half the time.","Live captions add Japanese and Korean, with translation under two seconds.","Team spaces move into design and stay internal this quarter."],"decisions":["Public beta on November 18; feature freeze from November 11.","Team spaces open to customers in Q1 next year."],"actionItems":[{"who":"Maya","what":"Update the release plan and share it with sales by Friday"},{"who":"Leo","what":"Load-test caption latency and write up the results"},{"who":"Sam","what":"Draft the permission model for team spaces"}]},"summaryStatus":"completed","segments":[
          {"text":"Let's start with Q4. The library redesign comes first — reviewing a meeting still takes too long.","speaker":"Maya","startMs":0,"endMs":7000},
          {"text":"Agreed. Japanese and Korean captions already work, and translation is at about one and a half seconds.","speaker":"Leo","startMs":7200,"endMs":14500},
          {"text":"Then let's lock the public beta for November 18 and freeze features a week before for regression testing.","speaker":"Maya","startMs":14800,"endMs":22000},
          {"text":"For team spaces I'd keep it internal first; the permission model needs another pass.","speaker":"Sam","startMs":22300,"endMs":29000}
        ]}
        """;
    private const string CitationEn = """{"segmentId":"meeting","startMs":14800,"endMs":22000,"snippet":"Lock the public beta for November 18 and freeze features a week before."}""";
}
