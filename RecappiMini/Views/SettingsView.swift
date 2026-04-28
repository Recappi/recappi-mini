import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject private var config = AppConfig.shared
    @ObservedObject private var sessionStore = AuthSessionStore.shared
    @ObservedObject private var appUpdater = AppUpdater.shared
    @State private var capturePermissions = CapturePermissionSnapshot.placeholder
    @State private var permissionsBusy = false
    @State private var billingStatus: BillingStatus?
    @State private var billingErrorMessage: String?
    @State private var isLoadingBilling = false

    private static let updateCheckDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            SettingsHeader()
            Form {
                accountSection
                permissionsSection
                recordingAssistSection
                transcriptionSection
                storageSection
                updatesSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
        }
        .background(DT.recordingShell)
        .preferredColorScheme(.dark)
        .containerBackground(DT.recordingShell, for: .window)
        .navigationTitle("Recappi Mini Settings")
        .frame(minWidth: 520, idealWidth: 560, maxWidth: 620)
        .task {
            refreshPermissionStatus()
            await refreshBillingStatusIfNeeded()
        }
        .onChange(of: sessionStore.currentSession?.userId) { _, _ in
            Task { await refreshBillingStatusIfNeeded() }
        }
        .onChange(of: config.cloudEnabled) { _, _ in
            Task { await refreshBillingStatusIfNeeded() }
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section {
            Toggle("Cloud transcription", isOn: cloudEnabledBinding)
                .accessibilityIdentifier(AccessibilityIDs.Settings.cloudToggle)

            statusView
                .accessibilityLabel(authStatusText)
                .accessibilityValue(authStatusText)
                .accessibilityIdentifier(AccessibilityIDs.Settings.authStatus)

            authActions

            if let currentSession = sessionStore.currentSession {
                accountSummary(session: currentSession)
            }

            billingUsageView

            HStack {
                Button("Open Recappi Cloud", action: openCloudCenter)
                    .disabled(!config.cloudEnabled)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.openCloudButton)
                Spacer(minLength: 0)
            }
        } header: {
            Text("Account")
        }
    }

    @ViewBuilder
    private var billingUsageView: some View {
        if config.cloudEnabled, sessionStore.currentSession != nil {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label(billingUsageTitle, systemImage: billingUsageIcon)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(billingUsageTint)

                    Spacer(minLength: 0)

                    Button {
                        Task { await refreshBillingStatus(force: true) }
                    } label: {
                        if isLoadingBilling {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.72)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(isLoadingBilling)
                    .help("Refresh usage")
                    .accessibilityIdentifier(AccessibilityIDs.Settings.billingRefreshButton)
                }

                if let billingStatus {
                    VStack(alignment: .leading, spacing: 6) {
                        usageLine(
                            title: "Storage",
                            value: settingsStorageUsageText(for: billingStatus),
                            progress: settingsStorageProgress(for: billingStatus),
                            isOverLimit: billingStatus.isOverStorage
                        )
                        usageLine(
                            title: "Minutes",
                            value: settingsMinutesUsageText(for: billingStatus),
                            progress: settingsMinutesProgress(for: billingStatus),
                            isOverLimit: billingStatus.isOverMinutes
                        )
                    }
                } else {
                    Text(billingErrorMessage ?? (isLoadingBilling ? "Loading usage…" : "Usage unavailable"))
                        .font(.caption)
                        .foregroundStyle(Color.dtLabelSecondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 2)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityIDs.Settings.billingUsage)
        }
    }

    private func usageLine(
        title: String,
        value: String,
        progress: Double,
        isOverLimit: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.dtLabelSecondary)
                .frame(width: 52, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                    Capsule(style: .continuous)
                        .fill((isOverLimit ? DT.systemOrange : DT.waveformLit).opacity(0.72))
                        .frame(width: proxy.size.width * max(0, min(1, progress)))
                }
            }
            .frame(height: 4)

            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(isOverLimit ? DT.systemOrange : Color.dtLabelTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(width: 132, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var permissionsSection: some View {
        Section {
            permissionRow(
                title: "Microphone",
                state: capturePermissions.microphone,
                statusID: AccessibilityIDs.Settings.permissionMicrophoneStatus,
                requestID: AccessibilityIDs.Settings.requestMicrophoneButton,
                action: requestMicrophonePermission
            )

            permissionRow(
                title: "Screen & system audio",
                state: capturePermissions.screenCapture,
                statusID: AccessibilityIDs.Settings.permissionScreenCaptureStatus,
                requestID: AccessibilityIDs.Settings.requestScreenCaptureButton,
                action: requestScreenCapturePermission
            )

            HStack {
                Button("Refresh", action: refreshPermissionStatus)
                    .disabled(permissionsBusy)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.refreshPermissionsButton)
                Spacer(minLength: 0)
            }
        } header: {
            Text("Permissions")
        }
    }

    @ViewBuilder
    private var recordingAssistSection: some View {
        Section {
            Toggle("Suggest recording when app audio starts", isOn: autoPromptBinding)
                .accessibilityIdentifier(AccessibilityIDs.Settings.autoPromptToggle)
        } header: {
            Text("Recording Assist")
        } footer: {
            Text("When a meeting app or browser meeting tab starts playing audio, Recappi Mini opens the panel and explains which app looks ready to record.")
                .foregroundStyle(Color.dtLabelSecondary)
                .font(.footnote)
        }
    }

    @ViewBuilder
    private var transcriptionSection: some View {
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
            .disabled(!config.cloudEnabled)
        } header: {
            Text("Transcription")
        } footer: {
            Text("Language hint sent with each cloud transcription.")
                .foregroundStyle(Color.dtLabelSecondary)
                .font(.footnote)
        }
    }

    @ViewBuilder
    private var storageSection: some View {
        Section {
            LabeledContent("Recordings folder") {
                Button("Show in Finder", action: openRecordingsFolder)
            }
        } header: {
            Text("Storage")
        } footer: {
            Text("Recordings are saved in ~/Documents/Recappi Mini.")
                .foregroundStyle(Color.dtLabelSecondary)
                .font(.footnote)
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        Section {
            LabeledContent("Current version") {
                Text(appVersionText)
                    .foregroundStyle(Color.dtLabelSecondary)
            }

            LabeledContent("Last checked") {
                Text(lastUpdateCheckText)
                    .foregroundStyle(Color.dtLabelSecondary)
            }

            Toggle(
                "Automatically check for updates",
                isOn: Binding(
                    get: { appUpdater.automaticallyChecksForUpdates },
                    set: { appUpdater.setAutomaticallyChecksForUpdates($0) }
                )
            )

            Toggle(
                "Automatically download updates",
                isOn: Binding(
                    get: { appUpdater.automaticallyDownloadsUpdates },
                    set: { appUpdater.setAutomaticallyDownloadsUpdates($0) }
                )
            )
            .disabled(!appUpdater.automaticallyChecksForUpdates)

            HStack {
                Button("Check for Updates…") {
                    appUpdater.checkForUpdates()
                }
                .disabled(!appUpdater.canCheckForUpdates)
                Spacer(minLength: 0)
            }
        } header: {
            Text("Updates")
        }
    }

    @ViewBuilder
    private var statusView: some View {
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
                    text: sessionStore.authStatusDetail ?? "Session expired. Reconnect to continue."
                )
            case .failed:
                statusLabel(
                    icon: "xmark.circle.fill",
                    color: DT.systemOrange,
                    text: sessionStore.authStatusDetail ?? "Authentication failed. Try signing in again."
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

                Button(signOutButtonTitle, action: signOut)
                    .disabled(signOutDisabled)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.signOutButton)
            }

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
    private func accountSummary(session: UserSession) -> some View {
        LabeledContent("Connected as") {
            Text(session.email)
                .foregroundStyle(Color.dtLabelSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
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
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String,
        state: CapturePermissionSnapshot.State,
        statusID: String,
        requestID: String,
        action: @escaping () -> Void
    ) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Label(state.label, systemImage: state.systemImage)
                    .foregroundStyle(state == .authorized ? DT.systemGreen : DT.systemOrange)
                    .accessibilityIdentifier(statusID)

                if state != .authorized {
                    Button("Allow", action: action)
                        .disabled(permissionsBusy)
                        .accessibilityIdentifier(requestID)
                }
            }
        }
    }

    private var signedOutText: String {
        if let provider = sessionStore.lastOAuthProvider {
            return "Signed out. Last used \(provider.displayName)."
        }
        return "Signed out."
    }

    private func signedInText(for session: UserSession) -> String {
        let expiresPrefix = session.expiresAt.prefix(10)
        if let provider = sessionStore.lastOAuthProvider {
            return "\(session.email) via \(provider.displayName), expires \(expiresPrefix)."
        }
        return "\(session.email), expires \(expiresPrefix)."
    }

    private var billingUsageTitle: String {
        if let billingStatus {
            return "\(billingStatus.tier.displayName) usage"
        }
        if isLoadingBilling {
            return "Loading usage"
        }
        return "Cloud usage"
    }

    private var billingUsageIcon: String {
        if isLoadingBilling {
            return "arrow.triangle.2.circlepath"
        }
        if billingStatus.map(settingsIsOverAnyLimit) == true {
            return "exclamationmark.triangle.fill"
        }
        return "chart.bar.xaxis"
    }

    private var billingUsageTint: Color {
        if billingStatus.map(settingsIsOverAnyLimit) == true || billingErrorMessage != nil {
            return DT.systemOrange
        }
        return DT.waveformLit
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

    private var appVersionText: String {
        let bundle = Bundle.main
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let buildNumber = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        switch (shortVersion, buildNumber) {
        case let (shortVersion?, buildNumber?) where shortVersion != buildNumber:
            return "\(shortVersion) (\(buildNumber))"
        case let (shortVersion?, _):
            return shortVersion
        case let (_, buildNumber?):
            return buildNumber
        default:
            return "Unknown"
        }
    }

    private var lastUpdateCheckText: String {
        guard let date = appUpdater.lastUpdateCheckDate else { return "Not yet" }
        return Self.updateCheckDateFormatter.string(from: date)
    }

    private var isAuthActionDisabled: Bool {
        !config.cloudEnabled || sessionStore.isAuthBusy
    }

    private func signIn(with provider: OAuthProvider) {
        let origin = config.effectiveBackendBaseURL
        Task { @MainActor in
            do {
                _ = try await sessionStore.startOAuth(provider: provider, origin: origin)
                await refreshBillingStatus(force: true)
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
                await refreshBillingStatus(force: true)
            } catch {
                NSSound.beep()
            }
        }
    }

    private func signOut() {
        let origin = config.effectiveBackendBaseURL
        Task { @MainActor in
            await sessionStore.signOut(origin: origin)
            billingStatus = nil
            billingErrorMessage = nil
        }
    }

    private func openCloudCenter() {
        AppDelegate.shared.showCloudCenter()
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

    private func openRecordingsFolder() {
        NSWorkspace.shared.open(RecordingStore.baseDirectory)
    }

    private func refreshBillingStatusIfNeeded() async {
        guard config.cloudEnabled, sessionStore.currentSession != nil else {
            billingStatus = nil
            billingErrorMessage = nil
            isLoadingBilling = false
            return
        }
        guard billingStatus == nil else { return }
        await refreshBillingStatus(force: false)
    }

    private func refreshBillingStatus(force: Bool) async {
        guard config.cloudEnabled, sessionStore.currentSession != nil else {
            billingStatus = nil
            billingErrorMessage = nil
            isLoadingBilling = false
            return
        }
        guard force || billingStatus == nil else { return }

        isLoadingBilling = true
        billingErrorMessage = nil
        do {
            let origin = config.effectiveBackendBaseURL
            _ = try await sessionStore.ensureAuthorized(origin: origin)
            guard let token = sessionStore.bearerToken() else {
                throw RecappiSessionError.notSignedIn
            }
            let client = RecappiAPIClient(origin: origin, bearerToken: token)
            billingStatus = try await client.getBillingStatus()
        } catch let error as RecappiAPIError where error == .unauthorized {
            do {
                let origin = config.effectiveBackendBaseURL
                _ = try await sessionStore.handleUnauthorized(origin: origin)
            } catch {
                // `handleUnauthorized` already updates the visible auth state.
            }
            billingStatus = nil
            billingErrorMessage = nil
        } catch {
            billingStatus = nil
            billingErrorMessage = error.localizedDescription
        }
        isLoadingBilling = false
    }

    private func settingsStorageProgress(for status: BillingStatus) -> Double {
        guard status.storageCapBytes > 0 else { return 0 }
        return Double(status.storageBytes) / Double(status.storageCapBytes)
    }

    private func settingsMinutesProgress(for status: BillingStatus) -> Double {
        guard status.minutesCap > 0 else { return 0 }
        return status.minutesUsed / status.minutesCap
    }

    private func settingsIsOverAnyLimit(_ status: BillingStatus) -> Bool {
        status.isOverStorage || status.isOverMinutes
    }

    private func settingsStorageUsageText(for status: BillingStatus) -> String {
        let used = ByteCountFormatter.string(fromByteCount: status.storageBytes, countStyle: .file)
        let cap = ByteCountFormatter.string(fromByteCount: status.storageCapBytes, countStyle: .file)
        return "\(used) / \(cap)"
    }

    private func settingsMinutesUsageText(for status: BillingStatus) -> String {
        "\(settingsFormattedMinutes(status.minutesUsed)) / \(settingsFormattedMinutes(status.minutesCap)) min"
    }

    private func settingsFormattedMinutes(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { AppConfig.shared.cloudLanguage },
            set: { AppConfig.shared.cloudLanguage = $0 }
        )
    }

    private var cloudEnabledBinding: Binding<Bool> {
        Binding(
            get: { AppConfig.shared.cloudEnabled },
            set: { AppConfig.shared.cloudEnabled = $0 }
        )
    }

    private var autoPromptBinding: Binding<Bool> {
        Binding(
            get: { AppConfig.shared.autoPromptForActiveAudioApps },
            set: { AppConfig.shared.autoPromptForActiveAudioApps = $0 }
        )
    }
}

private struct SettingsHeader: View {
    var body: some View {
        HStack(spacing: 14) {
            LogoTile(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recappi Mini")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.dtLabel)
                Text("Menu-bar meeting recorder")
                    .font(.footnote)
                    .foregroundStyle(Color.dtLabelSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 6)
    }
}
