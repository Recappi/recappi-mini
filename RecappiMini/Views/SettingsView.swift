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
    @State private var testing = false
    @State private var testResult: TestResult?

    enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

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

                if config.selectedProvider != .none {
                    HStack {
                        Button {
                            runTest()
                        } label: {
                            if testing {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Testing…")
                                }
                            } else {
                                Text("Test Provider")
                            }
                        }
                        .disabled(testing || !canTest)

                        if let result = testResult {
                            Spacer(minLength: 6)
                            testResultLabel(result)
                        }
                    }
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
        .onChange(of: config.selectedProvider) { _, _ in testResult = nil }
    }

    @ViewBuilder
    private func testResultLabel(_ result: TestResult) -> some View {
        switch result {
        case .success(let message):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(message).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        case .failure(let message):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private var canTest: Bool {
        if config.selectedProvider.needsApiKey {
            return !config.currentApiKey.isEmpty
        }
        return true
    }

    private func runTest() {
        testing = true
        testResult = nil
        let provider = createInsightsProvider(config: config)
        Task { @MainActor in
            defer { testing = false }
            do {
                // Short synthetic transcript so the round-trip is cheap.
                let probe = "Alice and Bob agreed to ship the pipeline by Friday. Bob will own rollout."
                let insights = try await provider.extract(transcript: probe)
                let actionCount = insights.actionItems.count
                testResult = .success("OK. Got \(insights.summary.count) chars of summary, \(insights.keyDecisions.count) decisions, \(actionCount) action items.")
            } catch {
                testResult = .failure(error.localizedDescription)
            }
        }
    }

    private var apiKeyBinding: Binding<String> {
        switch config.selectedProvider {
        case .gemini: return $config.geminiApiKey
        case .openai: return $config.openaiApiKey
        case .none, .apple: return .constant("")
        }
    }

    private var providerFooterText: String {
        switch config.selectedProvider {
        case .none:
            return "Saves the audio + transcript only. No summary or action items. Pick a provider to get them."
        case .apple:
            return "Runs on-device with Apple Intelligence. Free, private, no API key. Requires Apple Intelligence enabled in System Settings."
        case .gemini:
            return "Key stored in your app preferences. Get one at aistudio.google.com."
        case .openai:
            return "Key stored in your app preferences. Get one at platform.openai.com."
        }
    }
}
