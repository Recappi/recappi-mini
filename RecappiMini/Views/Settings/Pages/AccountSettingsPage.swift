import AppKit
import SwiftUI

struct AccountSettingsPage: View {
    @EnvironmentObject private var config: AppConfig
    @EnvironmentObject private var sessionStore: AuthSessionStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var billingStatus: BillingStatus?
    @State private var billingErrorMessage: String?
    @State private var isLoadingBilling = false

    /// `DT.waveformLit` (green) was applied to the usage label and
    /// progress bars in both appearances. peng-xiao wants light mode
    /// to read as primary ink instead, so the green stays only in
    /// dark mode where the surrounding card is dark.
    private var usageAccent: Color {
        colorScheme == .dark ? DT.waveformLit : .black
    }

    var body: some View {
        Form {
            Section {
                if let session = sessionStore.currentSession {
                    accountIdentityRow(session: session)
                } else {
                    signedOutAuthRow
                }
            }

            Section {
                Toggle("Cloud transcription", isOn: cloudEnabledBinding)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.cloudToggle)

                billingUsageView
            } footer: {
                Text("With cloud transcription on, audio is uploaded to Recappi Cloud for higher-accuracy transcripts and shared playback. Off keeps everything local.")
                    .foregroundStyle(Palette.labelSecondary)
                    .font(.footnote)
            }

            Section {
                HStack {
                    Button("Open Recappi Cloud", action: openCloudCenter)
                        .disabled(!config.cloudEnabled)
                        .accessibilityIdentifier(AccessibilityIDs.Settings.openCloudButton)
                    Spacer(minLength: 0)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .scrollContentBackground(.hidden)
        .task {
            await refreshBillingStatusIfNeeded()
        }
        .task(id: sessionStore.currentSession?.userId) {
            await refreshBillingStatusIfNeeded()
        }
        .task(id: config.cloudEnabled) {
            await refreshBillingStatusIfNeeded()
        }
    }

    // MARK: - Identity rows

    @ViewBuilder
    private func accountIdentityRow(session: UserSession) -> some View {
        HStack(spacing: 10) {
            AccountAvatar(session: session, size: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(sessionDisplayName(for: session))
                    .font(.body.weight(.medium))
                    .foregroundStyle(Palette.labelPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                accountConnectionRow(for: session)
            }

            Spacer(minLength: 0)

            Text("Active")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(DT.systemGreen)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(DT.systemGreen.opacity(0.14))
                )

            Menu {
                Button(signOutButtonTitle, action: signOut)
                    .disabled(signOutDisabled)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.signOutButton)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.labelSecondary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .disabled(sessionStore.isAuthBusy)
            .accessibilityLabel("Account actions")
            .accessibilityIdentifier(AccessibilityIDs.Settings.accountActionsMenu)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var signedOutAuthRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AccountAvatar(session: nil, size: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text(signedOutTitle)
                        .font(.body.weight(.medium))
                        .foregroundStyle(Palette.labelPrimary)
                    Text(authStatusText)
                        .font(.caption)
                        .foregroundStyle(Palette.labelSecondary)
                        .lineLimit(2)
                        .accessibilityIdentifier(AccessibilityIDs.Settings.authStatusText)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                if shouldShowSignInAgainButton {
                    Button(signInAgainButtonTitle, action: reconnect)
                        .controlSize(.small)
                        .disabled(isAuthActionDisabled)
                        .accessibilityIdentifier(AccessibilityIDs.Settings.reconnectButton)
                }

                signInButton(for: .google)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.signInGoogleButton)

                signInButton(for: .github)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.signInGitHubButton)

                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func signInButton(for provider: OAuthProvider) -> some View {
        Button(action: { signIn(with: provider) }) {
            HStack(spacing: 6) {
                if sessionStore.authFlowPhase?.activeProvider == provider {
                    ProgressView().controlSize(.small)
                    Text(sessionStore.authFlowPhase?.buttonLabel ?? "Connecting…")
                } else {
                    Text(provider.displayName)
                }
            }
        }
        .controlSize(.small)
        .disabled(isAuthActionDisabled)
    }

    @ViewBuilder
    private func accountConnectionRow(for session: UserSession) -> some View {
        HStack(spacing: 4) {
            if let provider = sessionStore.lastOAuthProvider {
                Text("Connected with")
                ProviderInlineMark(provider: provider, size: 12)
                Text(provider.displayName)
            } else {
                Text("Connected")
            }
            if sessionDisplayName(for: session) != session.email {
                Text("· \(session.email)")
                    .truncationMode(.middle)
            }
        }
        .font(.caption)
        .foregroundStyle(Palette.labelSecondary)
        .lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accountConnectionText(for: session))
        .accessibilityIdentifier(AccessibilityIDs.Settings.authStatusText)
    }

    // MARK: - Billing usage

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
                        ZStack {
                            Image(systemName: "arrow.clockwise")
                                .opacity(isLoadingBilling ? 0 : 1)

                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.72)
                                .opacity(isLoadingBilling ? 1 : 0)
                        }
                        .frame(width: 18, height: 18)
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
                            value: storageUsageText(for: billingStatus),
                            progress: storageProgress(for: billingStatus),
                            isOverLimit: billingStatus.effectiveIsOverStorage
                        )
                        usageLine(
                            title: "Minutes",
                            value: minutesUsageText(for: billingStatus),
                            progress: minutesProgress(for: billingStatus),
                            isOverLimit: billingStatus.effectiveIsOverMinutes
                        )
                    }
                } else {
                    Text(billingErrorMessage ?? (isLoadingBilling ? "Loading usage…" : "Usage unavailable"))
                        .font(.caption)
                        .foregroundStyle(Palette.labelSecondary)
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
                .foregroundStyle(Palette.labelSecondary)
                .frame(width: 52, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                    Capsule(style: .continuous)
                        .fill((isOverLimit ? DT.systemOrange : usageAccent).opacity(0.72))
                        .frame(width: proxy.size.width * max(0, min(1, progress)))
                }
            }
            .frame(height: 4)

            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(isOverLimit ? DT.systemOrange : Palette.labelTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(width: 132, alignment: .trailing)
        }
    }

    // MARK: - Bindings

    private var cloudEnabledBinding: Binding<Bool> {
        Binding(
            get: { config.cloudEnabled },
            set: { config.cloudEnabled = $0 }
        )
    }

    // MARK: - Derived text / state

    private var signedOutText: String {
        if let provider = sessionStore.lastOAuthProvider {
            return "Signed out. Last used \(provider.displayName)."
        }
        return "Signed out."
    }

    private var signedOutTitle: String {
        switch sessionStore.authStatus {
        case .expired, .failed:
            return "Sign in again"
        default:
            return "Sign in to Recappi Cloud"
        }
    }

    private var signInAgainButtonTitle: String {
        if let provider = sessionStore.lastOAuthProvider {
            return "Sign in with \(provider.displayName)"
        }
        return "Sign in again"
    }

    private var shouldShowSignInAgainButton: Bool {
        switch sessionStore.authStatus {
        case .expired, .failed:
            return sessionStore.lastOAuthProvider != nil
        default:
            return false
        }
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
        if billingStatus.map({ $0.effectiveIsOverAnyLimit }) == true {
            return "exclamationmark.triangle.fill"
        }
        return "chart.bar.xaxis"
    }

    private var billingUsageTint: Color {
        if billingStatus.map({ $0.effectiveIsOverAnyLimit }) == true || billingErrorMessage != nil {
            return DT.systemOrange
        }
        return usageAccent
    }

    private var isAuthActionDisabled: Bool {
        !config.cloudEnabled || sessionStore.isAuthBusy
    }

    private func sessionDisplayName(for session: UserSession) -> String {
        let trimmedName = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? session.email : trimmedName
    }

    private func accountConnectionText(for session: UserSession) -> String {
        let providerText: String
        if let provider = sessionStore.lastOAuthProvider {
            providerText = "Connected with \(provider.displayName)"
        } else {
            providerText = "Connected"
        }
        if sessionDisplayName(for: session) == session.email {
            return providerText
        }
        return "\(providerText) · \(session.email)"
    }

    private func signedInText(for session: UserSession) -> String {
        let expiresPrefix = session.expiresAt.prefix(10)
        if let provider = sessionStore.lastOAuthProvider {
            return "\(session.email) via \(provider.displayName), expires \(expiresPrefix)."
        }
        return "\(session.email), expires \(expiresPrefix)."
    }

    // MARK: - Actions

    private func signIn(with provider: OAuthProvider) {
        let origin = config.effectiveBackendBaseURL
        Task { @MainActor in
            do {
                _ = try await sessionStore.startOAuth(provider: provider, origin: origin)
                await refreshBillingStatus(force: true)
            } catch {
                DiagnosticsLog.error(
                    "settings",
                    "account.sign_in.failed provider=\(provider.rawValue) \(DiagnosticsLog.errorSummary(error))"
                )
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
                DiagnosticsLog.error("settings", "account.reconnect.failed \(DiagnosticsLog.errorSummary(error))")
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

    // MARK: - Billing API

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
                DiagnosticsLog.warning("settings", "billing.handle_unauthorized.failed \(DiagnosticsLog.errorSummary(error))")
            }
            billingStatus = nil
            billingErrorMessage = nil
        } catch {
            DiagnosticsLog.error("settings", "billing.refresh.failed \(DiagnosticsLog.errorSummary(error))")
            billingStatus = nil
            billingErrorMessage = NetworkErrorPresenter.userFacingMessage(for: error)
        }
        isLoadingBilling = false
    }

    private func storageProgress(for status: BillingStatus) -> Double {
        guard !status.hasUnlimitedStorage else { return 0 }
        guard status.storageCapBytes > 0 else { return 0 }
        return Double(status.storageBytes) / Double(status.storageCapBytes)
    }

    private func minutesProgress(for status: BillingStatus) -> Double {
        guard !status.hasUnlimitedMinutes else { return 0 }
        guard status.minutesCap > 0 else { return 0 }
        return status.minutesUsed / status.minutesCap
    }

    private func storageUsageText(for status: BillingStatus) -> String {
        let used = ByteCountFormatter.string(fromByteCount: status.storageBytes, countStyle: .file)
        guard !status.hasUnlimitedStorage else { return "\(used) used" }
        let cap = ByteCountFormatter.string(fromByteCount: status.storageCapBytes, countStyle: .file)
        return "\(used) / \(cap)"
    }

    private func minutesUsageText(for status: BillingStatus) -> String {
        guard !status.hasUnlimitedMinutes else { return "\(formattedMinutes(status.minutesUsed)) min used" }
        return "\(formattedMinutes(status.minutesUsed)) / \(formattedMinutes(status.minutesCap)) min"
    }

    private func formattedMinutes(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
