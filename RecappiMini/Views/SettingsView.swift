import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var config = AppConfig.shared
    @ObservedObject private var sessionStore = AuthSessionStore.shared
    @State private var manualBearerInput = UITestModeConfiguration.shared.authToken ?? ""
    @State private var capturePermissions = CapturePermissionSnapshot.placeholder
    @State private var permissionsBusy = false

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader()
            Form {
                accountSection
                permissionsSection
                if shouldShowManualAuth {
                    manualAuthSection
                }
                transcriptionSection
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
        .task { refreshPermissionStatus() }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @ViewBuilder private var accountSection: some View {
        Section {
            Toggle("Use Recappi Cloud for transcription", isOn: cloudEnabledBinding)
                .accessibilityIdentifier(AccessibilityIDs.Settings.cloudToggle)

            TextField("Backend URL", text: backendBinding, prompt: Text("https://recordmeet.ing"))
                .disabled(sessionStore.isAuthBusy)
                .accessibilityIdentifier(AccessibilityIDs.Settings.backendField)

            authActions

            statusView
                .accessibilityLabel(authStatusText)
                .accessibilityValue(authStatusText)
                .accessibilityIdentifier(AccessibilityIDs.Settings.authStatus)

            if let currentSession = sessionStore.currentSession {
                accountSummaryCard(session: currentSession)
            }
        } header: {
            Text("Account / Recappi Cloud")
        } footer: {
            Text("Use Google or GitHub to sign in to Recappi Cloud. The app opens a secure system browser sheet, completes the backend PKCE bridge in-session, stores the bearer token in Keychain, and reconnects if the backend returns 401.")
                .foregroundStyle(Color.dtLabelSecondary)
                .font(.footnote)
        }
    }

    @ViewBuilder private var manualAuthSection: some View {
        Section {
            TextField(
                "Paste bearer token or Authorization header",
                text: $manualBearerInput,
                prompt: Text("Bearer …")
            )
            .accessibilityIdentifier(AccessibilityIDs.Settings.manualBearerField)

            HStack(spacing: 10) {
                Button("Import bearer", action: importManualBearer)
                    .disabled(manualBearerInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAuthActionDisabled)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.importBearerButton)

                Spacer(minLength: 0)
            }
        } header: {
            Text("Developer Auth Backdoor")
        } footer: {
            Text("Hidden in release builds. Useful for automation, backend probes, and auth debugging when native OAuth is unavailable on the current machine.")
                .foregroundStyle(Color.dtLabelSecondary)
                .font(.footnote)
        }
    }

    @ViewBuilder private var permissionsSection: some View {
        Section {
            permissionRow(
                title: "Microphone",
                state: capturePermissions.microphone,
                accessibilityID: AccessibilityIDs.Settings.permissionMicrophoneStatus
            )

            permissionRow(
                title: "Screen & system audio",
                state: capturePermissions.screenCapture,
                accessibilityID: AccessibilityIDs.Settings.permissionScreenCaptureStatus
            )

            HStack(spacing: 10) {
                Button("Request microphone", action: requestMicrophonePermission)
                    .disabled(permissionsBusy)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.requestMicrophoneButton)

                Button("Request screen & system audio", action: requestScreenCapturePermission)
                    .disabled(permissionsBusy)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.requestScreenCaptureButton)

                Button("Refresh", action: refreshPermissionStatus)
                    .disabled(permissionsBusy)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.refreshPermissionsButton)

                Spacer(minLength: 0)
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("Use these controls to re-check access or trigger the system permission flow again. If macOS already remembers a denial, the screen & system audio request may send you to System Settings instead of showing an alert.")
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
            Text("Each session keeps recording.m4a, upload.wav, transcript.md, and remote-session.json side by side in ~/Documents/Recappi Mini.")
                .foregroundStyle(Color.dtLabelSecondary)
                .font(.footnote)
        }
    }

    @ViewBuilder private var statusView: some View {
        if let phase = sessionStore.authFlowPhase {
            statusLabel(icon: "arrow.triangle.2.circlepath", color: DT.waveformLit, text: phase.statusText)
        } else {
            switch sessionStore.authStatus {
            case .signedOut:
                statusLabel(icon: "person.crop.circle.badge.xmark", color: DT.systemOrange, text: signedOutText)
            case .authenticating:
                statusLabel(icon: "arrow.triangle.2.circlepath", color: DT.waveformLit, text: "Authenticating with Recappi Cloud…")
            case .signedIn(let session):
                statusLabel(icon: "checkmark.circle.fill", color: DT.systemGreen, text: signedInText(for: session))
            case .expired:
                statusLabel(
                    icon: "clock.arrow.circlepath",
                    color: DT.systemOrange,
                    text: sessionStore.authStatusDetail ?? "Session expired — reconnect to continue."
                )
            case .failed:
                statusLabel(
                    icon: "xmark.circle.fill",
                    color: DT.systemOrange,
                    text: sessionStore.authStatusDetail ?? "Authentication failed — try again or use the developer backdoor."
                )
            }
        }
    }

    @ViewBuilder
    private var authActions: some View {
        HStack(spacing: 10) {
            if sessionStore.currentSession == nil {
                signInButton(for: .google)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.signInGoogleButton)

                signInButton(for: .github)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.signInGitHubButton)
            } else {
                Button(reconnectButtonTitle, action: reconnect)
                    .disabled(isAuthActionDisabled)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.reconnectButton)

                if let alternate = alternateProvider {
                    Button("Use \(alternate.displayName)") {
                        signIn(with: alternate)
                    }
                    .disabled(isAuthActionDisabled)
                }
            }

            Button(signOutButtonTitle, action: signOut)
                .disabled(signOutDisabled)
                .accessibilityIdentifier(AccessibilityIDs.Settings.signOutButton)

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func signInButton(for provider: OAuthProvider) -> some View {
        Button(action: { signIn(with: provider) }) {
            if sessionStore.authFlowPhase?.activeProvider == provider {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(sessionStore.authFlowPhase?.buttonLabel ?? "Connecting…")
                }
            } else {
                Text("Sign in with \(provider.displayName)")
            }
        }
        .disabled(isAuthActionDisabled)
    }

    @ViewBuilder
    private func accountSummaryCard(session: UserSession) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connected account")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.05 * 10.5)
                .textCase(.uppercase)
                .foregroundStyle(Color.dtLabelSecondary)

            Text(session.email)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.dtLabel)

            Text(accountSummaryDetail(for: session))
                .font(.footnote)
                .foregroundStyle(Color.dtLabelSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DT.R.card, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DT.R.card, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var signedOutText: String {
        if let provider = sessionStore.lastOAuthProvider {
            return "Signed out · last used \(provider.displayName)"
        }
        return "Signed out"
    }

    private func signedInText(for session: UserSession) -> String {
        let expiresPrefix = session.expiresAt.prefix(10)
        if let provider = sessionStore.lastOAuthProvider {
            return "\(session.email) · via \(provider.displayName) · expires \(expiresPrefix)"
        }
        return "\(session.email) · expires \(expiresPrefix)"
    }

    private func accountSummaryDetail(for session: UserSession) -> String {
        let providerText = sessionStore.lastOAuthProvider?.displayName ?? "Recappi Cloud"
        return "Signed in via \(providerText). Token refreshes on active use and currently expires on \(session.expiresAt)."
    }

    private var alternateProvider: OAuthProvider? {
        guard let last = sessionStore.lastOAuthProvider else { return nil }
        return OAuthProvider.allCases.first(where: { $0 != last })
    }

    private var reconnectButtonTitle: String {
        if sessionStore.authFlowPhase == .signingOut {
            return "Reconnect"
        }
        if let provider = sessionStore.lastOAuthProvider {
            return "Reconnect with \(provider.displayName)"
        }
        return "Reconnect"
    }

    private var signOutButtonTitle: String {
        if sessionStore.authFlowPhase == .signingOut {
            return "Signing out…"
        }
        return "Sign out"
    }

    private var signOutDisabled: Bool {
        sessionStore.currentSession == nil || sessionStore.isAuthBusy
    }

    private var authStatusText: String {
        if let phase = sessionStore.authFlowPhase {
            return phase.statusText
        }

        switch sessionStore.authStatus {
        case .signedOut:
            return signedOutText
        case .authenticating:
            return "Authenticating"
        case .signedIn(let session):
            return signedInText(for: session)
        case .expired:
            return sessionStore.authStatusDetail ?? "Session expired"
        case .failed:
            return sessionStore.authStatusDetail ?? "Authentication failed"
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

    @ViewBuilder
    private func permissionRow(
        title: String,
        state: CapturePermissionSnapshot.State,
        accessibilityID: String
    ) -> some View {
        LabeledContent(title) {
            Label(state.label, systemImage: state.systemImage)
                .foregroundStyle(state == .authorized ? DT.systemGreen : DT.systemOrange)
                .accessibilityIdentifier(accessibilityID)
        }
    }

    private var isAuthActionDisabled: Bool {
        !config.cloudEnabled || sessionStore.isAuthBusy
    }

    private var shouldShowManualAuth: Bool {
#if DEBUG
        return true
#else
        return UITestModeConfiguration.shared.manualAuthEnabled
#endif
    }

    private func signIn(with provider: OAuthProvider) {
        let origin = config.effectiveBackendBaseURL
        Task { @MainActor in
            do {
                _ = try await sessionStore.startOAuth(provider: provider, origin: origin)
            } catch {
                NSSound.beep()
            }
        }
    }

    private func reconnect() {
        let origin = config.effectiveBackendBaseURL
        Task { @MainActor in
            do {
                _ = try await sessionStore.reconnect(origin: origin)
            } catch {
                NSSound.beep()
            }
        }
    }

    private func signOut() {
        let origin = config.effectiveBackendBaseURL
        Task { @MainActor in
            await sessionStore.signOut(origin: origin)
            manualBearerInput = UITestModeConfiguration.shared.authToken ?? ""
        }
    }

    private func importManualBearer() {
        let raw = manualBearerInput
        let origin = config.effectiveBackendBaseURL
        Task { @MainActor in
            do {
                _ = try await sessionStore.importBearerToken(raw, origin: origin)
            } catch {
                NSSound.beep()
            }
        }
    }

    private func refreshPermissionStatus() {
        capturePermissions = CapturePermissionPrimer.shared.snapshot()
    }

    private func requestMicrophonePermission() {
        Task { @MainActor in
            permissionsBusy = true
            _ = await CapturePermissionPrimer.shared.requestMicrophoneAccess()
            refreshPermissionStatus()
            permissionsBusy = false
        }
    }

    private func requestScreenCapturePermission() {
        permissionsBusy = true
        _ = CapturePermissionPrimer.shared.requestScreenCaptureAccess()
        refreshPermissionStatus()
        permissionsBusy = false
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
