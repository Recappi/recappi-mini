import Foundation
import SwiftUI

enum LLMProvider: String, CaseIterable, Identifiable {
    /// Transcript only — no summarization step runs.
    case none = "None"
    /// Apple Intelligence (Foundation Models, macOS 26+). Free, on-device.
    case apple = "Apple"
    case gemini = "Gemini"
    case openai = "OpenAI"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None (transcript only)"
        case .apple: return "Apple Intelligence (on-device)"
        case .gemini: return "Gemini"
        case .openai: return "OpenAI"
        }
    }

    var needsApiKey: Bool {
        self == .gemini || self == .openai
    }
}

@MainActor
final class AppConfig: ObservableObject {
    static let shared = AppConfig()

    @AppStorage("llmProvider") var llmProvider: String = LLMProvider.apple.rawValue
    @AppStorage("geminiApiKey") var geminiApiKey: String = ""
    @AppStorage("openaiApiKey") var openaiApiKey: String = ""
    @AppStorage("speechLanguage") var speechLanguage: String = "en-US"

    var selectedProvider: LLMProvider {
        get { LLMProvider(rawValue: llmProvider) ?? .apple }
        set { llmProvider = newValue.rawValue }
    }

    var currentApiKey: String {
        switch selectedProvider {
        case .none, .apple: return ""
        case .gemini: return geminiApiKey
        case .openai: return openaiApiKey
        }
    }

    var hasValidConfig: Bool {
        if !selectedProvider.needsApiKey { return true }
        return !currentApiKey.isEmpty
    }

    private init() {}
}
