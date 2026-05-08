import Foundation
import SwiftUI

struct SpeechLanguageOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let shortTitle: String

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

@MainActor
final class AppConfig: ObservableObject {
    static let shared = AppConfig()

    @AppStorage("backendBaseURL") var backendBaseURL: String = "https://recordmeet.ing"
    @AppStorage("cloudEnabled") var cloudEnabled: Bool = true
    @AppStorage("autoPromptForActiveAudioApps") var autoPromptForActiveAudioApps: Bool = true
    @AppStorage("liveCaptionsDisplayEnabled") var liveCaptionsDisplayEnabled: Bool = true
    @AppStorage("experimentalCodexRealtimeEnabled") var experimentalCodexRealtimeEnabled: Bool = false
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

    private init() {}
}
