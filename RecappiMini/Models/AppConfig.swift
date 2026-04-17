import Foundation
import SwiftUI

enum LLMProvider: String, CaseIterable, Identifiable {
    case none = "None"
    case gemini = "Gemini"
    case openai = "OpenAI"

    var id: String { rawValue }

    var displayName: String { rawValue }

    var needsApiKey: Bool {
        self != .none
    }
}

@MainActor
final class AppConfig: ObservableObject {
    static let shared = AppConfig()

    @AppStorage("llmProvider") var llmProvider: String = LLMProvider.none.rawValue
    @AppStorage("geminiApiKey") var geminiApiKey: String = ""
    @AppStorage("openaiApiKey") var openaiApiKey: String = ""
    @AppStorage("speechLanguage") var speechLanguage: String = "en-US"

    var selectedProvider: LLMProvider {
        get { LLMProvider(rawValue: llmProvider) ?? .none }
        set { llmProvider = newValue.rawValue }
    }

    var currentApiKey: String {
        switch selectedProvider {
        case .none: return ""
        case .gemini: return geminiApiKey
        case .openai: return openaiApiKey
        }
    }

    var hasValidConfig: Bool {
        if selectedProvider == .none { return true }
        return !currentApiKey.isEmpty
    }

    private init() {}
}
