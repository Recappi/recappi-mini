import AppKit
import SwiftUI

/// Settings scene — sidebar + detail, mirroring macOS System Settings and the
/// `.settings` layout in the design refresh HTML.
struct SettingsView: View {
    @State private var tab: SettingsTab = .general

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 160, ideal: 170, max: 190)
        } detail: {
            detail
        }
        // 580pt window matches System Settings' default width and keeps the
        // horizontal gap between label and control tight. .contentSize in
        // the App's Settings scene lets height track the active pane so
        // short panes (General / Shortcuts / Storage) don't get padded.
        .frame(minWidth: 580, idealWidth: 580, maxWidth: 640)
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $tab) {
            ForEach(SettingsTab.allCases) { item in
                NavigationLink(value: item) {
                    Label {
                        Text(item.title)
                    } icon: {
                        TabTileIcon(tab: item)
                    }
                    .labelStyle(.titleAndIcon)
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch tab {
        case .general: GeneralPane()
        case .aiProviders: AIProvidersPane()
        case .audio: AudioPane()
        case .shortcuts: ShortcutsPane()
        case .storage: StoragePane()
        }
    }
}

// MARK: - Tabs

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general, aiProviders, audio, shortcuts, storage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .aiProviders: return "AI Providers"
        case .audio: return "Audio"
        case .shortcuts: return "Shortcuts"
        case .storage: return "Storage"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape.fill"
        case .aiProviders: return "cpu.fill"
        case .audio: return "speaker.wave.2.fill"
        case .shortcuts: return "command"
        case .storage: return "internaldrive.fill"
        }
    }

    /// Design-defined tile gradient for the sidebar icon.
    var tileGradient: LinearGradient {
        switch self {
        case .general:
            return LinearGradient(colors: [Color(white: 0.56), Color(white: 0.39)], startPoint: .top, endPoint: .bottom)
        case .aiProviders:
            return LinearGradient(colors: [Color(red: 0.66, green: 0.55, blue: 0.98), Color(red: 0.49, green: 0.23, blue: 0.93)], startPoint: .top, endPoint: .bottom)
        case .audio:
            return LinearGradient(colors: [Color(red: 1, green: 0.62, blue: 0.04), Color(red: 1, green: 0.42, blue: 0)], startPoint: .top, endPoint: .bottom)
        case .shortcuts:
            return LinearGradient(colors: [Color(red: 1, green: 0.84, blue: 0.04), Color(red: 1, green: 0.62, blue: 0.04)], startPoint: .top, endPoint: .bottom)
        case .storage:
            return LinearGradient(colors: [Color(red: 0.39, green: 0.82, blue: 1), Color(red: 0, green: 0.48, blue: 1)], startPoint: .top, endPoint: .bottom)
        }
    }
}

/// Small colored-tile icon used in the sidebar nav — System Settings style.
private struct TabTileIcon: View {
    let tab: SettingsTab
    var body: some View {
        Image(systemName: tab.systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tab == .shortcuts ? Color.black.opacity(0.7) : Color.white)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(tab.tileGradient)
            )
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject private var config = AppConfig.shared
    @State private var appearance: Appearance = .auto
    @State private var onFinish: OnFinish = .showSummary
    @State private var saveLocation = "~/Documents/Recappi Mini"
    @State private var keepOriginal = true
    @State private var openAtLogin = true
    @State private var showInDock = false

    enum Appearance: String, CaseIterable, Identifiable { case auto, light, dark; var id: String { rawValue } }
    enum OnFinish: String, CaseIterable, Identifiable { case showSummary, autoClose, doNothing; var id: String { rawValue }
        var label: String { switch self { case .showSummary: return "Show summary"; case .autoClose: return "Auto-close panel"; case .doNothing: return "Do nothing" } } }

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $config.speechLanguage) {
                    Text("English (US)").tag("en-US")
                    Text("English (UK)").tag("en-GB")
                    Text("中文（简体）").tag("zh-CN")
                    Text("日本語").tag("ja-JP")
                    Text("Español").tag("es-ES")
                    Text("Français").tag("fr-FR")
                    Text("Deutsch").tag("de-DE")
                }

                Picker("Appearance", selection: $appearance) {
                    ForEach(Appearance.allCases) { a in
                        Text(a.rawValue.capitalized).tag(a)
                    }
                }
                .pickerStyle(.segmented)

                Picker("On finish", selection: $onFinish) {
                    ForEach(OnFinish.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
            }

            Section {
                LabeledContent("Save recordings to") {
                    HStack(spacing: 8) {
                        TextField("", text: $saveLocation)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") { }
                    }
                }
                Toggle("Keep original audio after transcription", isOn: $keepOriginal)
            }

            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                Toggle("Show Recappi in Dock", isOn: $showInDock)
            } header: {
                Text("Launch")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }
}

// MARK: - AI Providers

private struct AIProvidersPane: View {
    @ObservedObject private var config = AppConfig.shared
    @State private var testing = false
    @State private var testResult: TestResult?

    enum TestResult: Equatable {
        case success(String)
        case failure(String)
    }

    @State private var storeInKeychain: Bool = true
    @State private var deleteAudioAfter: Bool = false

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: $config.llmProvider) {
                    ForEach(LLMProvider.allCases) { p in
                        Text(p.displayName).tag(p.rawValue)
                    }
                }

                if config.selectedProvider.needsApiKey {
                    SecureField("API Key", text: apiKeyBinding, prompt: Text(apiKeyPlaceholder))
                        .textFieldStyle(.roundedBorder)

                    TextField(
                        "Base URL",
                        text: baseUrlBinding,
                        prompt: Text(baseUrlPlaceholder)
                    )
                    .textFieldStyle(.roundedBorder)

                    TextField(
                        "Model",
                        text: modelBinding,
                        prompt: Text(modelPlaceholder)
                    )
                    .textFieldStyle(.roundedBorder)
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

                        if let r = testResult {
                            testResultLabel(r)
                        }

                        Spacer(minLength: 0)
                    }
                } else {
                    Text("Summaries will be disabled. Recappi still saves the audio file — pick a provider any time to re-enable them.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Transcription & Summary")
            } footer: {
                Text(footerText)
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }

            Section("Privacy") {
                Toggle("Store API keys in Keychain", isOn: $storeInKeychain)
                Toggle("Delete audio after summary", isOn: $deleteAudioAfter)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("AI Providers")
        .onChange(of: config.selectedProvider) { _, _ in testResult = nil }
    }

    // MARK: - Bindings + placeholders

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
            return "Runs on-device with Apple Intelligence. Free, private, no API key. Requires Apple Intelligence enabled in System Settings."
        case .gemini:
            return "Leave Base URL / Model blank for defaults. Custom Base URL supports Gemini-compatible proxies."
        case .openai:
            return "Leave Base URL / Model blank for defaults. Custom Base URL supports any OpenAI-compatible endpoint — Ollama, LM Studio, OpenRouter, Groq, Together, DeepSeek, Azure, etc."
        }
    }

    // MARK: - Test

    @ViewBuilder
    private func testResultLabel(_ r: TestResult) -> some View {
        HStack(spacing: 5) {
            switch r {
            case .success(let msg):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(DT.systemGreen)
                Text(msg).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            case .failure(let msg):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DT.systemOrange)
                Text(msg).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
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
                testResult = .success("OK — \(insights.summary.count) chars of summary, \(insights.keyDecisions.count) decisions, \(insights.actionItems.count) action items.")
            } catch {
                testResult = .failure(error.localizedDescription)
            }
        }
    }
}

// MARK: - Audio

private struct AudioPane: View {
    @State private var micDevice = "System Default"
    @State private var format: Format = .aac32
    @State private var sampleRate: SampleRate = .sr16

    enum Format: String, CaseIterable, Identifiable { case aac32, aac64, wav; var id: String { rawValue }
        var label: String { switch self { case .aac32: return "AAC 32 kbps"; case .aac64: return "AAC 64 kbps"; case .wav: return "WAV" } } }
    enum SampleRate: String, CaseIterable, Identifiable { case sr16, sr441, sr48; var id: String { rawValue }
        var label: String { switch self { case .sr16: return "16 kHz"; case .sr441: return "44.1 kHz"; case .sr48: return "48 kHz" } } }

    var body: some View {
        Form {
            Section {
                Picker("Microphone", selection: $micDevice) {
                    Text("System Default").tag("System Default")
                    Text("MacBook Pro Microphone").tag("MacBook Pro Microphone")
                    Text("AirPods Pro").tag("AirPods Pro")
                }

                Picker("Format", selection: $format) {
                    ForEach(Format.allCases) { f in Text(f.label).tag(f) }
                }
                .pickerStyle(.segmented)

                Picker("Sample rate", selection: $sampleRate) {
                    ForEach(SampleRate.allCases) { r in Text(r.label).tag(r) }
                }
            } footer: {
                Text("Recappi currently outputs single-track 16 kHz mono 32 kbps AAC — voice-grade, ~14 MB/hour. Higher fidelity options are placeholders for now.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Audio")
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Start / stop recording") { shortcutChip("⌘⇧R") }
                LabeledContent("Show panel") { shortcutChip("⌥⌘P") }
                LabeledContent("Open last recording") { shortcutChip("⌥⌘O") }
            } footer: {
                Text("Global hotkeys are informational for now — wire up via Carbon RegisterEventHotKey or MAS shortcuts to make them active outside the panel.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Shortcuts")
    }

    @ViewBuilder
    private func shortcutChip(_ combo: String) -> some View {
        Text(combo)
            .font(.system(size: 11, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(white: 0.95))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.black.opacity(0.15), lineWidth: 0.5)
            )
    }
}

// MARK: - Storage

private struct StoragePane: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("This month") { Text("— recordings").foregroundStyle(.secondary) }
                LabeledContent("All time") { Text("— recordings").foregroundStyle(.secondary) }

                LabeledContent("Location") {
                    HStack(spacing: 8) {
                        Button("Show in Finder") {
                            NSWorkspace.shared.open(RecordingStore.baseDirectory)
                        }
                        Button("Delete older than…") { }
                    }
                }
            } footer: {
                Text("Recordings are stored at ~/Documents/Recappi Mini/. Transcripts, summaries, and action items sit next to each recording.")
                    .foregroundStyle(.secondary)
                    .font(.footnote)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Storage")
    }
}
