import AppKit
import SwiftUI

/// Top-level settings scene. Uses the standard macOS Preferences layout —
/// tab bar with Apple-style icons across the top, Form-based detail view
/// for each tab. Fixed width matches Apple's system Preferences sizing.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            ProvidersSettingsTab()
                .tabItem {
                    Label("AI Providers", systemImage: "cpu")
                }
        }
        .scenePadding()
        .frame(width: 480, height: 280)
        // Settings panel temporarily flips the app to .regular activation so
        // the window can come to the foreground (see RecordingPanel.presentSettings).
        // When it's dismissed we drop back to .accessory so we're a menu-bar
        // utility again and don't linger in the Dock.
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @ObservedObject private var config = AppConfig.shared

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $config.speechLanguage) {
                    Text("English (US)").tag("en-US")
                    Text("中文 (简体)").tag("zh-CN")
                    Text("日本語").tag("ja-JP")
                }
            } header: {
                Text("Transcription")
            } footer: {
                Text("Used by the on-device Apple Speech recognizer. Remote providers detect language automatically.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - AI Providers (BYOK)

private struct ProvidersSettingsTab: View {
    @ObservedObject private var config = AppConfig.shared

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $config.llmProvider) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider.rawValue)
                    }
                }

                if config.selectedProvider.needsApiKey {
                    SecureField("API Key", text: apiKeyBinding)
                        .textFieldStyle(.roundedBorder)
                }
            } header: {
                Text("Transcription & Summary")
            } footer: {
                Text(providerFooterText)
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        }
        .formStyle(.grouped)
    }

    private var apiKeyBinding: Binding<String> {
        switch config.selectedProvider {
        case .gemini: return $config.geminiApiKey
        case .openai: return $config.openaiApiKey
        case .none: return .constant("")
        }
    }

    private var providerFooterText: String {
        switch config.selectedProvider {
        case .none:
            return "No key needed — Apple Speech runs on-device. Add a remote provider for higher-quality transcripts and meeting summaries."
        case .gemini:
            return "Key stored in your app preferences. Get one at aistudio.google.com."
        case .openai:
            return "Key stored in your app preferences. Get one at platform.openai.com."
        }
    }
}
