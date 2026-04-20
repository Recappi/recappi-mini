import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var config = AppConfig.shared
    @ObservedObject private var sessionStore = CookieSessionStore.shared
    @State private var cookieInput = UITestModeConfiguration.shared.cookieValue ?? ""

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader()
            Form {
                accountSection
                transcriptionSection
                summaryProviderSection
                storageSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .background(DT.recordingShell)
        .preferredColorScheme(.dark)
        .containerBackground(DT.recordingShell, for: .window)
        .navigationTitle("Recappi Mini Settings")
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 660)
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @ViewBuilder private var accountSection: some View {
        Section {
            Toggle("Use Recappi Cloud for transcription", isOn: cloudEnabledBinding)
                .accessibilityIdentifier(AccessibilityIDs.Settings.cloudToggle)

            TextField("Backend URL", text: backendBinding, prompt: Text("https://recordmeet.ing"))
                .accessibilityIdentifier(AccessibilityIDs.Settings.backendField)

            TextField(
                "Paste Better Auth cookie or raw value",
                text: $cookieInput,
                prompt: Text("__Secure-better-auth.session_token=…")
            )
            .accessibilityIdentifier(AccessibilityIDs.Settings.cookieField)

            HStack(spacing: 10) {
                Button(action: verifyCookie) {
                    if case .verifying = sessionStore.authStatus {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Verifying…")
                        }
                    } else {
                        Text("Verify Session")
                    }
                }
                .disabled(cookieInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !config.cloudEnabled)
                .accessibilityIdentifier(AccessibilityIDs.Settings.verifyButton)

                Button("Clear Session", action: clearSession)
                    .disabled(sessionStore.currentSession == nil && cookieInput.isEmpty)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.clearButton)

                Spacer(minLength: 0)
            }

            statusView
                .accessibilityLabel(authStatusText)
                .accessibilityValue(authStatusText)
                .accessibilityIdentifier(AccessibilityIDs.Settings.authStatus)
        } header: {
            Text("Account / Recappi Cloud")
        } footer: {
            Text("Sign in on recordmeet.ing, then paste the Better Auth session cookie here. The app normalizes the value and sends it as __Secure-better-auth.session_token on each request.")
                .foregroundStyle(Color.dtLabelSecondary)
                .font(.footnote)
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
            Text("Language hint sent to the Recappi backend for transcription. Regional variants are normalized before upload, for example en-US becomes en.")
                .foregroundStyle(Color.dtLabelSecondary)
                .font(.footnote)
        }
    }

    @ViewBuilder private var summaryProviderSection: some View {
        SummaryProviderSection()
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
            Text("Each session keeps recording.m4a, upload.wav, transcript.md, and any summary files side by side in ~/Documents/Recappi Mini.")
                .foregroundStyle(Color.dtLabelSecondary)
                .font(.footnote)
        }
    }

    @ViewBuilder private var statusView: some View {
        switch sessionStore.authStatus {
        case .signedOut:
            statusLabel(icon: "person.crop.circle.badge.xmark", color: DT.systemOrange, text: "Signed out")
        case .verifying:
            statusLabel(icon: "arrow.triangle.2.circlepath", color: DT.waveformLit, text: "Verifying session…")
        case .signedIn(let session):
            statusLabel(icon: "checkmark.circle.fill", color: DT.systemGreen, text: "\(session.email) · expires \(session.expiresAt.prefix(10))")
        case .expired:
            statusLabel(icon: "clock.arrow.circlepath", color: DT.systemOrange, text: "Session expired — paste a fresh cookie.")
        case .invalidCookie:
            statusLabel(icon: "xmark.circle.fill", color: DT.systemOrange, text: "Cookie invalid — paste a fresh Better Auth session cookie.")
        }
    }

    private var authStatusText: String {
        switch sessionStore.authStatus {
        case .signedOut:
            return "Signed out"
        case .verifying:
            return "Verifying session"
        case .signedIn(let session):
            return "\(session.email) expires \(session.expiresAt.prefix(10))"
        case .expired:
            return "Session expired"
        case .invalidCookie:
            return "Cookie invalid"
        }
    }

    @ViewBuilder
    private func statusLabel(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.footnote)
                .foregroundStyle(Color.dtLabelSecondary)
                .lineLimit(2)
                .accessibilityIdentifier(AccessibilityIDs.Settings.authStatusText)
        }
    }

    private func verifyCookie() {
        let raw = cookieInput
        let origin = config.effectiveBackendBaseURL
        Task { @MainActor in
            do {
                _ = try await sessionStore.verifySession(using: raw, origin: origin)
            } catch {
                NSSound.beep()
            }
        }
    }

    private func clearSession() {
        sessionStore.clearSession()
        cookieInput = UITestModeConfiguration.shared.cookieValue ?? ""
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { AppConfig.shared.cloudLanguage },
            set: { AppConfig.shared.cloudLanguage = $0 }
        )
    }

    private var backendBinding: Binding<String> {
        Binding(
            get: { AppConfig.shared.backendBaseURL },
            set: { AppConfig.shared.backendBaseURL = $0 }
        )
    }

    private var cloudEnabledBinding: Binding<Bool> {
        Binding(
            get: { AppConfig.shared.cloudEnabled },
            set: { AppConfig.shared.cloudEnabled = $0 }
        )
    }
}

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

private struct SummaryProviderSection: View {
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
                ForEach(LLMProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider.rawValue)
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
                            Text("Test summary provider")
                        }
                    }
                    .disabled(testing || !canTest)

                    if let result = testResult { testResultLabel(result) }

                    Spacer(minLength: 0)
                }
            }
        } header: {
            Text("Summary Provider")
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
            return "Skip summary and action items. Transcript generation still runs through Recappi Cloud."
        case .apple:
            return "Runs on-device with Apple Intelligence after the transcript comes back from Recappi Cloud."
        case .gemini:
            return "Leave Base URL / Model blank for defaults. Custom Base URL supports Gemini-compatible proxies."
        case .openai:
            return "Leave Base URL / Model blank for defaults. Custom Base URL supports OpenAI-compatible endpoints."
        }
    }

    @ViewBuilder
    private func testResultLabel(_ result: TestResult) -> some View {
        HStack(spacing: 5) {
            switch result {
            case .success(let message):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(DT.systemGreen)
                Text(message).font(.footnote).foregroundStyle(Color.dtLabelSecondary).lineLimit(2)
            case .failure(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(DT.systemOrange)
                Text(message).font(.footnote).foregroundStyle(Color.dtLabelSecondary).lineLimit(2)
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
