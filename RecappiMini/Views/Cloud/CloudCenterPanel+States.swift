import AppKit
import SwiftUI

extension CloudCenterPanel {
    // MARK: - Empty / error / loading / auth views

    var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
                .tint(DT.waveformLit)
            Text("Loading Recappi Cloud…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.dtLabel)
            Text("Fetching your remote recordings.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dtLabelSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: store.isRefreshing ? "cloud" : "cloud")
                .font(.system(size: 34))
                .foregroundStyle(DT.waveformLit)
            Text(store.isRefreshing ? "Checking cloud recordings…" : "No cloud recordings yet")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.dtLabel)
            Text(emptyDetailText)
                .font(.system(size: 12))
                .foregroundStyle(Color.dtLabelSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .tint(DT.waveformLit)
            }
            Button("Refresh") {
                Task { await store.refresh() }
            }
            .buttonStyle(PanelPushButtonStyle(primary: true))
            .frame(width: 140)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(DT.systemOrange)
            Text("Couldn’t load Recappi Cloud")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.dtLabel)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(Color.dtLabelSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 10) {
                Button("Reconnect") {
                    Task { await store.reconnect() }
                }
                .buttonStyle(PanelPushButtonStyle())
                Button("Retry") {
                    Task { await store.refresh() }
                }
                .buttonStyle(PanelPushButtonStyle(primary: true))
            }
            .frame(width: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func authRequiredView(title: String, detail: String) -> some View {
        VStack(spacing: 14) {
            LogoTile(size: 56)
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.dtLabel)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Color.dtLabelSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            HStack(spacing: 10) {
                Button {
                    Task { await store.signIn(with: .google) }
                } label: {
                    authButtonLabel(for: .google)
                }
                .buttonStyle(PanelPushButtonStyle())
                .disabled(sessionStore.isAuthBusy)
                .frame(width: 168)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.signInGoogleButton)

                Button {
                    Task { await store.signIn(with: .github) }
                } label: {
                    authButtonLabel(for: .github)
                }
                .buttonStyle(PanelPushButtonStyle())
                .disabled(sessionStore.isAuthBusy)
                .frame(width: 168)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.signInGitHubButton)
            }

            if case .expired = sessionStore.authStatus {
                Button("Reconnect") {
                    Task { await store.reconnect() }
                }
                .buttonStyle(PanelPushButtonStyle())
                .frame(width: 140)
                .disabled(sessionStore.isAuthBusy)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.reconnectButton)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    func authButtonLabel(for provider: OAuthProvider) -> some View {
        if sessionStore.authFlowPhase?.activeProvider == provider {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.75)
                Text(sessionStore.authFlowPhase?.buttonLabel ?? "Connecting…")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
            }
        } else {
            HStack(spacing: 7) {
                Image(nsImage: provider.logoImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
                Text("Sign in with \(provider.displayName)")
                    .lineLimit(1)
            }
        }
    }

    // MARK: - Subtitle text

    var headerSubtitle: String {
        var pieces: [String] = []

        if store.isRefreshing && store.lastSuccessfulRefreshAt == nil {
            pieces.append("Refreshing cloud recordings…")
        } else if store.lastSuccessfulRefreshAt != nil {
            pieces.append(updatedText(prefix: "Updated"))
        } else if sessionStore.currentSession != nil {
            pieces.append("Manage recordings, transcripts, billing, and limits")
        } else {
            pieces.append("Browse and manage remote recordings after sign-in")
        }

        if let totalText = recordingsCountText {
            pieces.append(totalText)
        }

        return pieces.joined(separator: " · ")
    }

    var recordingsCountText: String? {
        if let total = store.totalRecordingCount {
            return total == 1 ? "1 total" : "\(total) total"
        }
        if store.hasMorePages {
            return "\(store.recordings.count)+ loaded"
        }
        let count = store.recordings.count
        if count == 0 { return nil }
        return count == 1 ? "1 total" : "\(count) total"
    }

    var emptyDetailText: String {
        if store.isRefreshing {
            return "Showing the last known empty library while Recappi checks the cloud."
        }
        return "Record a meeting from the main panel. Finished transcripts will appear here."
    }

    func updatedText(prefix: String) -> String {
        guard let date = store.lastSuccessfulRefreshAt else {
            return prefix
        }
        return "\(prefix) \(date.formatted(date: .omitted, time: .shortened))"
    }
}
