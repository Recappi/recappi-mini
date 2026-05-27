import Foundation
import SwiftUI

struct SpeechLanguageOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let shortTitle: String

    var shortCode: String {
        switch id {
        case "en-US", "en-GB":
            return "EN"
        case "zh-CN", "zh-TW":
            return "ZH"
        case "ja-JP":
            return "JA"
        case "ko-KR":
            return "KO"
        case "es-ES":
            return "ES"
        case "fr-FR":
            return "FR"
        case "de-DE":
            return "DE"
        default:
            return String(id.prefix(2)).uppercased()
        }
    }

    static let common: [SpeechLanguageOption] = [
        .init(id: "en-US", title: "English (US)", shortTitle: "English"),
        .init(id: "en-GB", title: "English (UK)", shortTitle: "English UK"),
        .init(id: "zh-CN", title: "中文（简体）", shortTitle: "简体中文"),
        .init(id: "zh-TW", title: "中文（繁體）", shortTitle: "繁體中文"),
        .init(id: "ja-JP", title: "日本語", shortTitle: "日本語"),
        .init(id: "ko-KR", title: "한국어", shortTitle: "한국어"),
        .init(id: "es-ES", title: "Español", shortTitle: "Español"),
        .init(id: "fr-FR", title: "Français", shortTitle: "Français"),
        .init(id: "de-DE", title: "Deutsch", shortTitle: "Deutsch"),
    ]

    static func option(for id: String) -> SpeechLanguageOption {
        let normalized = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = common.first(where: { $0.id == normalized }) {
            return exact
        }
        if let base = normalized.split(separator: "-").first,
           let languageMatch = common.first(where: { $0.id.hasPrefix("\(base)-") }) {
            return languageMatch
        }
        return common[0]
    }
}

struct LiveCaptionTranslationTargetLanguageOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let shortTitle: String

    static let common: [LiveCaptionTranslationTargetLanguageOption] = [
        .init(id: "zh", title: "Chinese (zh)", shortTitle: "ZH"),
        .init(id: "en", title: "English (en)", shortTitle: "EN"),
        .init(id: "ja", title: "Japanese (ja)", shortTitle: "JA"),
        .init(id: "ko", title: "Korean (ko)", shortTitle: "KO"),
        .init(id: "fr", title: "French (fr)", shortTitle: "FR"),
        .init(id: "de", title: "German (de)", shortTitle: "DE"),
        .init(id: "es", title: "Spanish (es)", shortTitle: "ES"),
    ]

    static func option(for id: String) -> LiveCaptionTranslationTargetLanguageOption {
        let normalized = normalizedCode(id)
        return common.first(where: { $0.id == normalized }) ?? common[0]
    }

    static func normalizedCode(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "zh-Hans", "zh-CN", "zh-TW":
            return "zh"
        case let trimmed where !trimmed.isEmpty:
            return trimmed
        default:
            return "zh"
        }
    }
}

enum RecordingSceneTemplate: String, CaseIterable, Identifiable, Sendable {
    case meeting
    case podcast
    case interview
    case casual
    case lecture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meeting: return "Meeting"
        case .podcast: return "Podcast"
        case .interview: return "Interview"
        case .casual: return "Casual"
        case .lecture: return "Lecture"
        }
    }

    static func option(for raw: String) -> RecordingSceneTemplate {
        RecordingSceneTemplate(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? .meeting
    }
}

@MainActor
final class AppConfig: ObservableObject {
    static let shared = AppConfig()

    @AppStorage("backendBaseURL") var backendBaseURL: String = "https://recordmeet.ing"
    @AppStorage("cloudEnabled") var cloudEnabled: Bool = true
    @AppStorage("autoPromptForActiveAudioApps") var autoPromptForActiveAudioApps: Bool = true
    @AppStorage("liveCaptionsDisplayEnabled") var liveCaptionsDisplayEnabled: Bool = true
    @AppStorage("backendRealtimeLiveCaptionsEnabled") private var storedBackendRealtimeLiveCaptionsEnabled: Bool = true
    var backendRealtimeLiveCaptionsEnabled: Bool {
        get { true }
        set { storedBackendRealtimeLiveCaptionsEnabled = true }
    }
    /// When true, the backend Realtime live captions session is opened in
    /// translation mode (`mode=translation, includeSourceTranscript=true`),
    /// which streams both the source transcript and a translated transcript on
    /// the same connection. The panel renders both rows.
    @AppStorage("liveCaptionsBilingualEnabled") var liveCaptionsBilingualEnabled: Bool = false
    /// Target language for bilingual translation. Mirrors the OpenAI
    /// translation endpoint's `target_language` field; common values
    /// `zh`, `en`, `ja`, `ko`, `fr`, `de`, `es`. Default mirrors
    /// the source language picker so a fresh user gets a sensible pair.
    @AppStorage("liveCaptionsTranslationTargetLanguage") var liveCaptionsTranslationTargetLanguage: String = "zh"
    @AppStorage("recordingAutoTranscribeAfterUpload") var recordingAutoTranscribeAfterUpload: Bool = true
    @AppStorage("recordingSceneTemplate") var recordingSceneTemplate: String = RecordingSceneTemplate.meeting.rawValue
    @AppStorage("recordingUseExtraPrompt") var recordingUseExtraPrompt: Bool = true
    @AppStorage("recordingExtraPrompt") var recordingExtraPrompt: String = ""
    @AppStorage("recordingIncludeMicrophoneAudio") var recordingIncludeMicrophoneAudio: Bool = true
    @AppStorage("recordingMicrophoneDeviceID") var recordingMicrophoneDeviceID: String = MicrophoneInputDevice.systemDefaultID
    @Published var recordingTemplatePromptExpanded: Bool = false
    @AppStorage("appTheme") var theme: AppTheme = .light

    @AppStorage("speechLanguage") var cloudLanguage: String = "en-US"

    var selectedSpeechLanguage: SpeechLanguageOption {
        SpeechLanguageOption.option(for: cloudLanguage)
    }

    var effectiveBackendBaseURL: String {
        let override = UITestModeConfiguration.shared.backendURL?.trimmingCharacters(in: .whitespaces)
        if let override, !override.isEmpty { return override }
        let trimmed = backendBaseURL.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "https://recordmeet.ing" : trimmed
    }

    var normalizedCloudLanguage: String {
        let trimmed = cloudLanguage.trimmingCharacters(in: .whitespacesAndNewlines)
        if let base = trimmed.split(separator: "-").first, !base.isEmpty {
            return String(base)
        }
        return "en"
    }

    private init() {
        storedBackendRealtimeLiveCaptionsEnabled = true
    }
}
