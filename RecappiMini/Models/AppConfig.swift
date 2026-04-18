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

    // Per-provider credentials. BaseURL + Model are overridable so users can
    // point at OpenAI-compatible backends (Ollama, LM Studio, OpenRouter,
    // Groq, Together, DeepSeek, Azure, etc.) without forking the app.
    @AppStorage("geminiApiKey") var geminiApiKey: String = ""
    @AppStorage("geminiBaseUrl") var geminiBaseUrl: String = ""
    @AppStorage("geminiModel") var geminiModel: String = ""

    @AppStorage("openaiApiKey") var openaiApiKey: String = ""
    @AppStorage("openaiBaseUrl") var openaiBaseUrl: String = ""
    @AppStorage("openaiModel") var openaiModel: String = ""

    @AppStorage("speechLanguage") var speechLanguage: String = "en-US"

    // Default endpoints used when the user's field is blank. Kept public so
    // the Settings form can show them as placeholders.
    static let defaultGeminiBaseUrl = "https://generativelanguage.googleapis.com/v1beta"
    static let defaultGeminiModel = "gemini-2.0-flash"
    static let defaultOpenaiBaseUrl = "https://api.openai.com/v1"
    static let defaultOpenaiChatModel = "gpt-4o-mini"
    static let defaultOpenaiTranscribeModel = "whisper-1"

    var effectiveGeminiBaseUrl: String {
        let trimmed = geminiBaseUrl.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.defaultGeminiBaseUrl : trimmed
    }

    var effectiveGeminiModel: String {
        let trimmed = geminiModel.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.defaultGeminiModel : trimmed
    }

    var effectiveOpenaiBaseUrl: String {
        let trimmed = openaiBaseUrl.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.defaultOpenaiBaseUrl : trimmed
    }

    var effectiveOpenaiChatModel: String {
        let trimmed = openaiModel.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.defaultOpenaiChatModel : trimmed
    }

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
