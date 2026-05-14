import AppKit
import SwiftUI

// MARK: - Sidebar item

enum SettingsItem: Hashable {
    case general
    case account
    case permissions
    case transcription
    case updates
}

// MARK: - Root settings view

struct SettingsView: View {
    @EnvironmentObject private var config: AppConfig
    @EnvironmentObject private var sessionStore: AuthSessionStore
    @EnvironmentObject private var appUpdater: AppUpdater

    @State private var selection: SettingsItem = .general
    @State private var capturePermissions = CapturePermissionSnapshot.placeholder
    @State private var permissionsBusy = false

    let ownsForegroundWindowDemand: Bool

    init(ownsForegroundWindowDemand: Bool = true) {
        self.ownsForegroundWindowDemand = ownsForegroundWindowDemand
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    accountSidebarRow
                        .tag(SettingsItem.account)
                        .accessibilityIdentifier(AccessibilityIDs.Settings.accountSidebarRow)
                }

                Section {
                    SettingsSidebarRow(title: "General", systemImage: "gear", color: .gray)
                        .tag(SettingsItem.general)

                    SettingsSidebarRow(
                        title: "Permissions",
                        systemImage: "lock.shield",
                        color: .orange,
                        statusDot: permissionsStatusDot
                    )
                    .tag(SettingsItem.permissions)

                    SettingsSidebarRow(
                        title: "Transcription",
                        systemImage: "text.bubble",
                        color: .green
                    )
                    .tag(SettingsItem.transcription)
                    .accessibilityIdentifier(AccessibilityIDs.Settings.transcriptionSidebarRow)
                }

                Section {
                    SettingsSidebarRow(
                        title: "Updates",
                        systemImage: "arrow.down.circle",
                        color: .indigo
                    )
                    .tag(SettingsItem.updates)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            detailView
                .containerBackground(Palette.surfaceWindow, for: .window)
        }
        .navigationTitle("Recappi Mini Settings")
        .frame(minWidth: 720, idealWidth: 720, minHeight: 520, idealHeight: 520)
        .task {
            refreshPermissionStatus()
        }
        .onDisappear {
            if ownsForegroundWindowDemand {
                AppDelegate.shared.releaseSettingsSceneForegroundDemand()
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch selection {
        case .general:
            GeneralSettingsPage()
        case .account:
            AccountSettingsPage()
        case .permissions:
            PermissionsSettingsPage(
                snapshot: $capturePermissions,
                permissionsBusy: $permissionsBusy,
                onRefresh: refreshPermissionStatus
            )
        case .transcription:
            TranscriptionSettingsPage()
        case .updates:
            UpdatesSettingsPage()
        }
    }

    // MARK: - Account sidebar row

    /// Apple-Account-style sidebar entry: shows the user's avatar (or a
    /// signed-out placeholder), name + connection state on two lines, and the
    /// existing connected/needs-attention status dot. Placing it at the top of
    /// the sidebar matches macOS System Settings' affordance for Apple Account.
    @ViewBuilder
    private var accountSidebarRow: some View {
        HStack(spacing: 10) {
            AccountAvatar(session: sessionStore.currentSession, size: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text(accountSidebarTitle)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(accountSidebarSubtitle)
                    .font(.caption)
                    .foregroundStyle(Palette.labelSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer()

            if let dot = accountStatusDot {
                Circle()
                    .fill(dot)
                    .frame(width: 8, height: 8)
            }
        }
        .padding(.vertical, 6)
    }

    private var accountSidebarTitle: String {
        if let session = sessionStore.currentSession {
            let name = session.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? session.email : name
        }
        return "Account"
    }

    private var accountSidebarSubtitle: String {
        if let session = sessionStore.currentSession {
            if let provider = sessionStore.lastOAuthProvider {
                return "Recappi Cloud · \(provider.displayName)"
            }
            return session.email
        }
        switch sessionStore.authStatus {
        case .expired:
            return "Session expired"
        case .failed:
            return "Sign in needed"
        default:
            return "Sign in to Recappi Cloud"
        }
    }

    // MARK: - Sidebar status dots

    private var accountStatusDot: Color? {
        if sessionStore.authFlowPhase != nil {
            return DT.waveformLit
        }
        switch sessionStore.authStatus {
        case .signedIn:
            return config.cloudEnabled ? DT.systemGreen : nil
        case .expired, .failed:
            return config.cloudEnabled ? DT.systemOrange : nil
        case .signedOut, .authenticating:
            return nil
        }
    }

    private var permissionsStatusDot: Color? {
        let mic = capturePermissions.microphone == .authorized
        let screen = capturePermissions.screenCapture == .authorized
        switch (mic, screen) {
        case (true, true):
            return DT.systemGreen
        case (false, false):
            return DT.systemOrange
        default:
            return DT.systemOrange
        }
    }

    // MARK: - Permissions snapshot (lifted so the sidebar dot stays in sync with the detail page)

    private func refreshPermissionStatus() {
        capturePermissions = CapturePermissionPrimer.shared.snapshot()
    }
}
