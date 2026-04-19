import AppKit
import SwiftUI

/// Single-pane Settings — only the controls that are actually wired to
/// `AppConfig` / `RecordingStore`. Placeholder fake controls (appearance
/// picker, fake mic list, fake storage stats, unimplemented global hotkeys)
/// would lie to the user about what Recappi can do, so they're out.
struct SettingsView: View {
    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader()
            Form {
                transcriptionSection
                aiProviderSection
                storageSection
            }
            .formStyle(.grouped)
            // Hide Form's default grouped material so our charcoal bg paints
            // edge-to-edge; without this the Form paints a lighter gray
            // behind the sections.
            .scrollContentBackground(.hidden)
        }
        .background(DT.recordingShell)
        // Force dark on every SwiftUI control (Picker, SecureField, TextField,
        // Section header) so we don't have to restyle each one.
        .preferredColorScheme(.dark)
        // Covers the title-bar area on macOS 26 — without this there's a
        // strip of system-gray above the header.
        .containerBackground(DT.recordingShell, for: .window)
        .navigationTitle("Recappi Mini Settings")
        .frame(minWidth: 520, idealWidth: 540, maxWidth: 600)
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @ViewBuilder private var transcriptionSection: some View {
        Section {
            Picker("Language", selection: languageBinding) {
                Text("English (US)").tag("en-US")
                Text("English (UK)").tag("en-GB")
                Text("中文（简体）").tag("zh-CN")
                Text("日本語").tag("ja-JP")
                Text("Español").tag("es-ES")
                Text("Français").tag("fr-FR")
                Text("Deutsch").tag("de-DE")
            }
        } header: {
            Text("Transcription")
        } footer: {
            Text("Language Apple Speech uses when transcribing the recording.")
                .foregroundStyle(Color.dtLabelSecondary)
                .font(.footnote)
        }
    }

    @ViewBuilder private var aiProviderSection: some View {
        AIProviderSection()
    }

    @ViewBuilder private var storageSection: some View {
        Section {
            LabeledContent("Recordings folder") {
                Button("Show in Finder") {
                    NSWorkspace.shared.open(RecordingStore.baseDirectory)
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Recordings live at ~/Documents/Recappi Mini/. Each session has its own folder with the audio, transcript, and summary side by side.")
                .foregroundStyle(Color.dtLabelSecondary)
                .font(.footnote)
        }
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { AppConfig.shared.speechLanguage },
            set: { AppConfig.shared.speechLanguage = $0 }
        )
    }
}

// MARK: - Brand header

/// Logo tile + app name/tagline row that anchors the top of the Settings
/// window so the app identity is visible beyond the menu-bar icon.
private struct SettingsHeader: View {
    var body: some View {
        HStack(spacing: 14) {
            LogoTile(size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recappi Mini")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.dtLabel)
                Text("Menu-bar meeting recorder")
                    .font(.footnote)
                    .foregroundStyle(Color.dtLabelSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
    }
}

// MARK: - AI Provider section

/// Split into its own view so the state (`testing`, `testResult`) lives
/// close to the UI that drives it, keeping SettingsView itself flat.
private struct AIProviderSection: View {
    @ObservedObject private var config = AppConfig.shared
    @State private var testing = false
    @State private var testResult: TestResult?

    enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    var body: some View {
        Section {
            Picker("Provider", selection: $config.llmProvider) {
                ForEach(LLMProvider.allCases) { p in
                    Text(p.displayName).tag(p.rawValue)
                }
            }

            if config.selectedProvider.needsApiKey {
                SecureField("API Key", text: apiKeyBinding, prompt: Text(apiKeyPlaceholder))
                TextField("Base URL", text: baseUrlBinding, prompt: Text(baseUrlPlaceholder))
                TextField("Model", text: modelBinding, prompt: Text(modelPlaceholder))
            }

            if config.selectedProvider != .none {
                HStack(spacing: 10) {
                    Button(action: runTest) {
                        if testing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Testing…")
                            }
                        } else {
                            Text("Test provider")
                        }
                    }
                    .disabled(testing || !canTest)

                    if let r = testResult { testResultLabel(r) }

                    Spacer(minLength: 0)
                }
            }
        } header: {
            Text("AI Provider")
        } footer: {
            Text(footerText)
                .foregroundStyle(Color.dtLabelSecondary)
                .font(.footnote)
        }
        .onChange(of: config.selectedProvider) { _, _ in testResult = nil }
    }

    private var apiKeyBinding: Binding<String> {
        switch config.selectedProvider {
        case .gemini: return $config.geminiApiKey
        case .openai: return $config.openaiApiKey
        case .none, .apple: return .constant("")
        }
    }

    private var baseUrlBinding: Binding<String> {
        switch config.selectedProvider {
        case .gemini: return $config.geminiBaseUrl
        case .openai: return $config.openaiBaseUrl
        case .none, .apple: return .constant("")
        }
    }

    private var modelBinding: Binding<String> {
        switch config.selectedProvider {
        case .gemini: return $config.geminiModel
        case .openai: return $config.openaiModel
        case .none, .apple: return .constant("")
        }
    }

    private var apiKeyPlaceholder: String {
        switch config.selectedProvider {
        case .gemini: return "AIza…"
        case .openai: return "sk-…"
        default: return ""
        }
    }

    private var baseUrlPlaceholder: String {
        switch config.selectedProvider {
        case .gemini: return AppConfig.defaultGeminiBaseUrl
        case .openai: return AppConfig.defaultOpenaiBaseUrl
        default: return ""
        }
    }

    private var modelPlaceholder: String {
        switch config.selectedProvider {
        case .gemini: return AppConfig.defaultGeminiModel
        case .openai: return AppConfig.defaultOpenaiChatModel
        default: return ""
        }
    }

    private var footerText: String {
        switch config.selectedProvider {
        case .none:
            return "Saves audio + transcript only. No summary or action items."
        case .apple:
            return "Runs on-device with Apple Intelligence. Requires Apple Intelligence enabled in System Settings."
        case .gemini:
            return "Leave Base URL / Model blank for defaults. Custom Base URL supports Gemini-compatible proxies."
        case .openai:
            return "Leave Base URL / Model blank for defaults. Custom Base URL supports any OpenAI-compatible endpoint — Ollama, LM Studio, OpenRouter, Groq, Together, DeepSeek, Azure, etc."
        }
    }

    @ViewBuilder
    private func testResultLabel(_ r: TestResult) -> some View {
        HStack(spacing: 5) {
            switch r {
            case .success(let msg):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(DT.systemGreen)
                Text(msg).font(.footnote).foregroundStyle(Color.dtLabelSecondary).lineLimit(2)
            case .failure(let msg):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DT.systemOrange)
                Text(msg).font(.footnote).foregroundStyle(Color.dtLabelSecondary).lineLimit(2)
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
                let probe = "Alice and Bob agreed to ship the pipeline by Friday. Bob will own rollout."
                let insights = try await provider.extract(transcript: probe)
                testResult = .success("OK — \(insights.summary.count) chars, \(insights.keyDecisions.count) decisions, \(insights.actionItems.count) action items.")
            } catch {
                testResult = .failure(error.localizedDescription)
            }
        }
    }
}
