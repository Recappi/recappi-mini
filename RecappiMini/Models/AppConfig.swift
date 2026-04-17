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
    @AppStorage("speechLanguage") var speechLanguage: String = "en-US"
    @AppStorage("summaryPrompt") var summaryPrompt: String = AppConfig.defaultSummaryPrompt

    static let defaultSummaryPrompt = """
    Given this meeting transcript, produce a concise meeting summary in markdown format with:
    ## Key Points
    ## Action Items
    ## Decisions Made

    Keep it brief and actionable.
    """

    // API keys live in the Keychain. Views bind to these published mirrors so
    // SettingsView can still use a simple Binding<String>; every write is
    // mirrored to Keychain via the explicit setters below.
    @Published private(set) var geminiApiKey: String = ""
    @Published private(set) var openaiApiKey: String = ""

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

    func setGeminiApiKey(_ value: String) {
        geminiApiKey = value
        Keychain.set(value, for: Self.geminiAccount)
    }

    func setOpenaiApiKey(_ value: String) {
        openaiApiKey = value
        Keychain.set(value, for: Self.openaiAccount)
    }

    private static let geminiAccount = "geminiApiKey"
    private static let openaiAccount = "openaiApiKey"

    private init() {
        // Load any existing keys from Keychain; fall back to a one-shot
        // migration from the pre-Keychain UserDefaults storage.
        let defaults = UserDefaults.standard

        let kcGemini = Keychain.get(Self.geminiAccount)
        let kcOpenai = Keychain.get(Self.openaiAccount)
        let defGemini = defaults.string(forKey: "geminiApiKey") ?? ""
        let defOpenai = defaults.string(forKey: "openaiApiKey") ?? ""

        geminiApiKey = !kcGemini.isEmpty ? kcGemini : defGemini
        openaiApiKey = !kcOpenai.isEmpty ? kcOpenai : defOpenai

        // Migrate plaintext defaults into Keychain, then scrub them.
        if kcGemini.isEmpty && !defGemini.isEmpty {
            Keychain.set(defGemini, for: Self.geminiAccount)
        }
        if kcOpenai.isEmpty && !defOpenai.isEmpty {
            Keychain.set(defOpenai, for: Self.openaiAccount)
        }
        if !defGemini.isEmpty { defaults.removeObject(forKey: "geminiApiKey") }
        if !defOpenai.isEmpty { defaults.removeObject(forKey: "openaiApiKey") }
    }
}
