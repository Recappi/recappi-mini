using System.Text.Json;

namespace Recappi.Core;

public sealed record DesktopPreferences
{
    public bool OnboardingCompleted { get; init; }
    public int OnboardingStep { get; init; }
    public string Theme { get; init; } = "system";
    public bool AutoUpload { get; init; } = true;
    public bool AutoTranscribe { get; init; } = true;
    public bool CaptionsEnabled { get; init; }
    public bool IncludeMicrophone { get; init; } = true;
    public int LongReminderMinutes { get; init; } = 45;
    public bool InactivityReminders { get; init; } = true;
    public bool RecordingSuggestions { get; init; } = true;
    public int MaxDurationMinutes { get; init; }
    public string TranscriptionLanguage { get; init; } = "auto";
    public string CaptionLanguage { get; init; } = "en";
    public string TranslationLanguage { get; init; } = "";
    public string Scene { get; init; } = "meeting";
    public string ExtraContext { get; init; } = "";
    public string? SourceId { get; init; }
    public string? MicrophoneId { get; init; }
    public string RecordingsRoot { get; init; } = LocalRecordingStore.DefaultRoot;
    public DesktopPreferences Validate()
    {
        if (Theme is not ("system" or "light" or "dark")) throw new ArgumentException("请选择有效主题。");
        if (LongReminderMinutes is < 0 or > 10080 || MaxDurationMinutes is < 0 or > 10080) throw new ArgumentException("提醒间隔和时长上限请输入 0–10080 分钟，0 表示关闭。");
        foreach (var language in new[] { TranscriptionLanguage, CaptionLanguage, TranslationLanguage })
            if (language is null || language.Length > 20 || language.Any(ch => !char.IsAsciiLetter(ch) && ch is not '-' and not '_')) throw new ArgumentException("语言请填写语言代码，例如 zh、en、zh-CN 或 auto。");
        if (Scene is not ("meeting" or "podcast" or "interview" or "casual" or "lecture")) throw new ArgumentException("请选择有效场景。");
        if (ExtraContext is null || ExtraContext.Length > 4000) throw new ArgumentException("额外上下文不能超过 4000 字符。");
        if (string.IsNullOrWhiteSpace(RecordingsRoot) || !Path.IsPathFullyQualified(RecordingsRoot)) throw new ArgumentException("请选择完整的本地录音目录路径。");
        return this with { RecordingsRoot = Path.GetFullPath(RecordingsRoot), TranscriptionLanguage = string.IsNullOrEmpty(TranscriptionLanguage) ? "auto" : TranscriptionLanguage, CaptionLanguage = string.IsNullOrEmpty(CaptionLanguage) ? "en" : CaptionLanguage };
    }
    [System.Text.Json.Serialization.JsonIgnore]
    public ProcessingOptions Processing => new(TranscriptionLanguage, ContextPrompt(), AutoTranscribe);
    [System.Text.Json.Serialization.JsonIgnore]
    public AttentionSettings Attention => new(LongReminderMinutes * 60, InactivityReminders, MaxDurationMinutes * 60);
    private string ContextPrompt()
    {
        var structure = Scene switch
        {
            "podcast" => "episode summary, key topics, notable moments, and follow-up ideas",
            "interview" => "profile, topic evidence, concerns, and follow-up questions",
            "casual" => "highlights and things worth remembering",
            "lecture" => "key concepts, examples, and review points",
            _ => "summary, decisions, action items, and open questions"
        };
        return $"Scene: {Scene}.\nUse this context for transcript terminology and the post-processing summary structure.\nFor summary, prefer {structure}." + (string.IsNullOrWhiteSpace(ExtraContext) ? "" : "\nAdditional context: " + ExtraContext.Trim());
    }
}

public sealed class PreferencesStore(string directory)
{
    private readonly string path = Path.Combine(Path.GetFullPath(directory), "settings.json");
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web) { WriteIndented = true };
    public DesktopPreferences Load() => File.Exists(path) ? (JsonSerializer.Deserialize<DesktopPreferences>(File.ReadAllText(path), Json) ?? new()).Validate() : new();
    public void Save(DesktopPreferences preferences)
    {
        preferences = preferences.Validate(); Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        AtomicJsonFile.Write(path, JsonSerializer.Serialize(preferences, Json));
    }

}
