import AppKit
import AVFoundation
@preconcurrency import MediaPlayer
import SwiftUI

struct CloudCenterPanel: View {
    @StateObject private var store: CloudLibraryStore
    @ObservedObject private var sessionStore = AuthSessionStore.shared
    @State private var showingDeleteConfirmation = false
    @State private var showingRetranscribeConfirmation = false

    init(store: CloudLibraryStore = CloudLibraryStore()) {
        _store = StateObject(wrappedValue: store)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 1160, height: 760)
        .background(DT.recordingShell)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.window)
        .task {
            await store.loadInitialIfNeeded()
        }
        .confirmationDialog(
            "Delete this cloud recording?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Recording", role: .destructive) {
                Task { await store.deleteSelectedRecording() }
            }
            .accessibilityIdentifier(AccessibilityIDs.Cloud.confirmDeleteButton)

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the remote recording and cannot be undone.")
        }
        .confirmationDialog(
            "Retranscribe this recording?",
            isPresented: $showingRetranscribeConfirmation,
            titleVisibility: .visible
        ) {
            Button("Retranscribe Audio") {
                Task { await store.retranscribeSelectedRecording() }
            }
            .accessibilityIdentifier(AccessibilityIDs.Cloud.confirmRetranscribeButton)

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This starts a new cloud transcription job for the selected audio. The current transcript stays visible until the new one finishes.")
        }
    }

    private var shouldShowBillingSummary: Bool {
        store.billingStatus != nil || store.isLoadingBilling || store.billingErrorMessage != nil
    }

    private var billingSummary: some View {
        CloudSidebarBillingSummary(
            status: store.billingStatus,
            errorMessage: store.billingErrorMessage,
            isLoading: store.billingStatus == nil && store.isLoadingBilling,
            isOpeningBilling: store.isOpeningBilling,
            onOpenBilling: { Task { await store.openBillingPortalOrPlans() } },
            onOpenPlans: store.openPlansPage
        )
    }

    private var header: some View {
        HStack(spacing: 12) {
            LogoTile(size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("Recappi Cloud")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color.dtLabel)
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 24)

            if shouldShowBillingSummary {
                billingSummary
                    .frame(width: 520, height: 34)
            }

            authStatusChip

            Button {
                Task { await store.refresh() }
            } label: {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.75)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(PanelIconButtonStyle())
            .disabled(store.isRefreshing || sessionStore.isAuthBusy)
            .help("Refresh cloud recordings")
            .accessibilityIdentifier(AccessibilityIDs.Cloud.refreshButton)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(
                    LinearGradient(
                        colors: [Color.white.opacity(0.055), Color.white.opacity(0.018)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading:
            loadingView
        case .signedOut:
            authRequiredView(
                title: "Sign in to browse your cloud recordings",
                detail: "Recappi Cloud keeps processed recordings, transcripts, and downloadable audio in one place."
            )
        case .expired:
            authRequiredView(
                title: "Reconnect Recappi Cloud",
                detail: "Your session expired. Reconnect once and the library will refresh automatically."
            )
        case .failed(let message):
            errorView(message)
        case .empty:
            emptyView
        case .loaded:
            libraryView
        }
    }

    private var libraryView: some View {
        HStack(spacing: 0) {
            recordingsList
                .frame(width: 292)

            Divider().overlay(Color.white.opacity(0.08))

            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var recordingsList: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recordings")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .tracking(0.45)
                Spacer(minLength: 0)
                Text("\(store.recordings.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dtLabelTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(store.recordings) { recording in
                        CloudRecordingRow(
                            recording: recording,
                            isSelected: store.selectedRecordingID == recording.id
                        ) {
                            store.select(recording)
                        }
                    }

                    if store.hasMorePages {
                        Button {
                            Task { await store.loadMore() }
                        } label: {
                            HStack(spacing: 8) {
                                if store.isLoadingMore {
                                    ProgressView()
                                        .controlSize(.small)
                                        .scaleEffect(0.72)
                                }
                                Text(store.isLoadingMore ? "Loading…" : "Load more")
                            }
                        }
                        .buttonStyle(PanelPushButtonStyle())
                        .disabled(store.isLoadingMore)
                        .padding(.top, 6)
                        .accessibilityIdentifier(AccessibilityIDs.Cloud.loadMoreButton)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }
            .accessibilityIdentifier(AccessibilityIDs.Cloud.recordingsList)

        }
        .background(Color.black.opacity(0.12))
    }

    @ViewBuilder
    private var detailPane: some View {
        if let recording = store.selectedRecording {
            CloudRecordingDetail(
                recording: recording,
                recordingWebURL: cloudRecordingWebURL(
                    recordingID: recording.id,
                    backendBaseURL: AppConfig.shared.effectiveBackendBaseURL
                ),
                latestJob: store.selectedLatestTranscriptionJob,
                transcript: store.selectedTranscript,
                transcriptErrorMessage: store.transcriptErrorMessage,
                retranscriptionLimitMessage: store.retranscriptionLimitMessage,
                localSessionURL: store.selectedLocalSessionURL,
                playbackAudioURL: store.selectedPlaybackAudioURL,
                playbackSourceDescription: store.selectedPlaybackSourceDescription,
                playbackErrorMessage: store.playbackErrorMessage,
                isTranscriptLoading: store.isSelectedTranscriptLoading,
                isJobHistoryLoading: store.isSelectedJobHistoryLoading,
                isPreparingPlaybackAudio: store.isPreparingPlaybackAudio,
                isDownloading: store.isDownloading,
                isDeleting: store.isDeleting,
                isSyncingToLocal: store.isSyncingToLocal,
                isRetranscribing: store.isRetranscribing,
                hasDownloadedAudio: store.lastDownloadedAudioURL != nil,
                onLoadTranscript: { Task { await store.loadTranscriptForSelection() } },
                onCopyTranscript: store.copySelectedTranscript,
                onRetranscribe: { showingRetranscribeConfirmation = true },
                onPreparePlaybackAudio: { Task { await store.preparePlaybackAudioForSelection() } },
                onRevealLocalSession: store.revealSelectedLocalSession,
                onSyncToLocal: { Task { await store.syncSelectedRecordingToLocal() } },
                onDownloadAudio: { Task { await store.downloadSelectedAudio() } },
                onRevealAudio: store.revealLastDownloadedAudio,
                onDelete: { showingDeleteConfirmation = true }
            )
            .task(id: recording.id) {
                await store.loadTranscriptForSelection()
                await store.loadJobHistoryForSelection()
            }
            .task(id: store.selectedActiveJobPollingKey) {
                await store.pollSelectedActiveJobsUntilTerminal()
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.stack.badge.person.crop")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.dtLabelTertiary)
                Text("Select a recording")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.dtLabel)
                Text("Choose a cloud recording to inspect metadata, preview transcript, or download audio.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var loadingView: some View {
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

    private var emptyView: some View {
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

    private func errorView(_ message: String) -> some View {
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

    private func authRequiredView(title: String, detail: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 34))
                .foregroundStyle(DT.waveformLit)
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
                .buttonStyle(PanelPushButtonStyle(primary: true))
                .disabled(sessionStore.isAuthBusy)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.signInGoogleButton)

                Button {
                    Task { await store.signIn(with: .github) }
                } label: {
                    authButtonLabel(for: .github)
                }
                .buttonStyle(PanelPushButtonStyle())
                .disabled(sessionStore.isAuthBusy)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.signInGitHubButton)
            }
            .frame(width: 300)

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
    private func authButtonLabel(for provider: OAuthProvider) -> some View {
        if sessionStore.authFlowPhase?.activeProvider == provider {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(sessionStore.authFlowPhase?.buttonLabel ?? "Connecting…")
            }
        } else {
            Text("Sign in with \(provider.displayName)")
        }
    }

    private var authStatusChip: some View {
        let chip = statusChipContent
        return HStack(spacing: 6) {
            Circle()
                .fill(chip.color)
                .frame(width: 7, height: 7)
            Text(chip.text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.dtLabelSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Cloud account status")
        .accessibilityValue(chip.text)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.authStatus)
    }

    private var statusChipContent: (text: String, color: Color) {
        if sessionStore.isAuthBusy {
            return ("Connecting", DT.waveformLit)
        }

        switch sessionStore.authStatus {
        case .signedIn(let session):
            return (session.email, DT.systemGreen)
        case .expired:
            return ("Expired", DT.systemOrange)
        case .failed:
            return ("Needs attention", DT.systemOrange)
        case .signedOut, .authenticating:
            return ("Signed out", DT.systemOrange)
        }
    }

    private var headerSubtitle: String {
        if store.isRefreshing {
            if store.lastSuccessfulRefreshAt != nil {
                return updatedText(prefix: "Updated")
            }
            return "Refreshing cloud recordings…"
        }
        if store.lastSuccessfulRefreshAt != nil {
            return updatedText(prefix: "Updated")
        }
        if sessionStore.currentSession != nil {
            return "Manage recordings, transcripts, billing, and limits"
        }
        return "Browse and manage remote recordings after sign-in"
    }

    private var emptyDetailText: String {
        if store.isRefreshing {
            return "Showing the last known empty library while Recappi checks the cloud."
        }
        return "Record a meeting from the main panel. Finished transcripts will appear here."
    }

    private func updatedText(prefix: String) -> String {
        guard let date = store.lastSuccessfulRefreshAt else {
            return prefix
        }
        return "\(prefix) \(date.formatted(date: .omitted, time: .shortened))"
    }

    private func cacheWarning(_ message: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DT.systemOrange)
            Text(message)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.dtLabelSecondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(DT.systemOrange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(DT.systemOrange.opacity(0.20), lineWidth: 1)
        )
    }
}

private struct CloudSidebarBillingSummary: View {
    let status: BillingStatus?
    let errorMessage: String?
    let isLoading: Bool
    let isOpeningBilling: Bool
    let onOpenBilling: () -> Void
    let onOpenPlans: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Text(planText)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(planColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, 7)
                .frame(minWidth: 54)
                .frame(height: 24)
                .background(
                    Capsule(style: .continuous)
                        .fill(planColor.opacity(0.10))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(planColor.opacity(0.16), lineWidth: 0.7)
                )

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 24)

            HStack(spacing: 14) {
                headerUsageMetric(
                    title: "Storage",
                    valueText: status?.storageUsageText ?? "Loading",
                    progress: status?.storageProgress ?? 0,
                    isOverLimit: status?.effectiveIsOverStorage ?? false
                )

                headerUsageMetric(
                    title: "Minutes",
                    valueText: status?.minutesUsageText ?? (errorMessage ?? "Loading"),
                    progress: status?.minutesProgress ?? 0,
                    isOverLimit: status?.effectiveIsOverMinutes ?? false
                )
            }
            .redacted(reason: status == nil && isLoading ? .placeholder : [])

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1, height: 24)

            Button {
                onOpenBilling()
            } label: {
                if isOpeningBilling {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Opening…")
                    }
                } else {
                    Label("Billing", systemImage: "creditcard")
                }
            }
            .buttonStyle(HeaderGlassButtonStyle())
            .frame(width: 82)
            .disabled(isOpeningBilling)
            .accessibilityIdentifier(AccessibilityIDs.Cloud.billingButton)
        }
        .padding(.horizontal, 2)
        .frame(height: 34)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(subtitle)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.billingStatus)
    }

    private func headerUsageMetric(title: String, valueText: String, progress: Double, isOverLimit: Bool) -> some View {
        let clampedProgress = max(0, min(1, progress))

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(isOverLimit ? DT.systemOrange.opacity(0.92) : Color.dtLabelTertiary)
                    .tracking(0.18)

                Text(valueText)
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(isOverLimit ? DT.systemOrange : Color.dtLabelSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }

            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.11))
                Capsule(style: .continuous)
                    .fill(isOverLimit ? DT.systemOrange : DT.waveformLit)
                    .frame(width: 132 * clampedProgress)
            }
            .frame(width: 132, height: 3)
        }
        .frame(width: 142, alignment: .leading)
    }

    private var planText: String {
        if let status {
            return status.tier.displayName
        }
        return isLoading ? "Loading…" : "Unavailable"
    }

    private var planColor: Color {
        if let status {
            return status.effectiveIsOverAnyLimit ? DT.systemOrange : DT.waveformLit
        }
        return isLoading ? Color.dtLabelSecondary : DT.systemOrange
    }

    private var subtitle: String {
        if let errorMessage {
            return errorMessage
        }
        if let status {
            if status.effectiveIsOverAnyLimit {
                return "Limit reached. Delete recordings or upgrade to continue."
            }
            return status.periodEndText.map { "Quota resets \($0)" } ?? "Current billing window"
        }
        return "Checking plan limits"
    }
}

private struct CloudLimitMeter: View {
    let title: String
    let valueText: String
    let progress: Double
    let isOverLimit: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .tracking(0.3)
                Spacer(minLength: 0)
                Text(valueText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isOverLimit ? DT.systemOrange : Color.dtLabelSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.10))
                    Capsule(style: .continuous)
                        .fill(isOverLimit ? DT.systemOrange : DT.waveformLit)
                        .frame(width: proxy.size.width * max(0, min(1, progress)))
                }
            }
            .frame(height: 5)
        }
        .frame(width: 124)
    }
}

private struct HeaderGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.dtLabel)
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.105 : 0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.white.opacity(configuration.isPressed ? 0.22 : 0.12), lineWidth: 0.75)
            )
            .opacity(configuration.isPressed ? 0.86 : 1)
    }
}

private struct CloudRecordingRow: View {
    let recording: CloudRecording
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                CloudSourceIcon(recording: recording, size: 24)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(recording.presentationTitle)
                            .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                            .foregroundStyle(Color.dtLabel)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 0)

                        CloudStatusChip(status: recording.status)
                    }

                    Text(recording.sourceLine)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.dtLabelSecondary)
                        .lineLimit(1)

                    HStack(spacing: 8) {
                        Label(recording.shortDateText, systemImage: "calendar")
                        if let duration = recording.durationText {
                            Label(duration, systemImage: "timer")
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? DT.recordingChip.opacity(0.82) : Color.white.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? DT.statusReady.opacity(0.34) : Color.white.opacity(0.045), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.recordingRowPrefix + recording.id)
    }
}

private struct CloudRecordingDetail: View {
    @StateObject private var audioPlayer = CloudMeetingAudioPlayer()
    @State private var pendingAutoplayAfterPrepare = false
    @State private var pendingSeekAfterPrepare: Double?
    @State private var pinnedSegmentID: String?
    @State private var pendingPinnedSegmentIDAfterPrepare: String?

    let recording: CloudRecording
    let recordingWebURL: URL?
    let latestJob: TranscriptionJob?
    let transcript: TranscriptResponse?
    let transcriptErrorMessage: String?
    let retranscriptionLimitMessage: String?
    let localSessionURL: URL?
    let playbackAudioURL: URL?
    let playbackSourceDescription: String
    let playbackErrorMessage: String?
    let isTranscriptLoading: Bool
    let isJobHistoryLoading: Bool
    let isPreparingPlaybackAudio: Bool
    let isDownloading: Bool
    let isDeleting: Bool
    let isSyncingToLocal: Bool
    let isRetranscribing: Bool
    let hasDownloadedAudio: Bool
    let onLoadTranscript: () -> Void
    let onCopyTranscript: () -> Void
    let onRetranscribe: () -> Void
    let onPreparePlaybackAudio: () -> Void
    let onRevealLocalSession: () -> Void
    let onSyncToLocal: () -> Void
    let onDownloadAudio: () -> Void
    let onRevealAudio: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            readerPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Color.white.opacity(0.08))

            inspectorPane
                .frame(width: 276)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            audioPlayer.load(url: playbackAudioURL, title: recording.presentationTitle)
        }
        .onChange(of: playbackAudioURL) { _, url in
            audioPlayer.load(url: url, title: recording.presentationTitle)
            if let pendingSeekAfterPrepare, url != nil {
                self.pendingSeekAfterPrepare = nil
                audioPlayer.seek(to: pendingSeekAfterPrepare)
            }
            if let pendingPinnedSegmentIDAfterPrepare, url != nil {
                pinnedSegmentID = pendingPinnedSegmentIDAfterPrepare
                self.pendingPinnedSegmentIDAfterPrepare = nil
            }
            if pendingAutoplayAfterPrepare, url != nil {
                pendingAutoplayAfterPrepare = false
                audioPlayer.play()
            }
        }
        .onChange(of: recording.id) { _, _ in
            pendingAutoplayAfterPrepare = false
            pendingSeekAfterPrepare = nil
            pendingPinnedSegmentIDAfterPrepare = nil
            pinnedSegmentID = nil
            audioPlayer.load(url: playbackAudioURL, title: recording.presentationTitle)
        }
        .onDisappear {
            audioPlayer.close()
        }
    }

    private var readerPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 13) {
                detailHeader
                latestJobStrip
                meetingPlaybackStrip
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider().overlay(Color.white.opacity(0.08))

            VStack(alignment: .leading, spacing: 12) {
                transcriptInsightStack
                segmentsHeader
                transcriptCard
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var transcriptInsightStack: some View {
        if let summaryInsightText {
            transcriptInsightCard(
                title: "Summary",
                systemImage: "text.alignleft",
                accessibilityID: AccessibilityIDs.Cloud.summaryText
            ) {
                Text(summaryInsightText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .lineLimit(5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if !visibleActionItems.isEmpty {
            transcriptInsightCard(
                title: "Action items",
                systemImage: "checklist",
                trailingText: "\(visibleActionItems.count) open",
                accessibilityID: AccessibilityIDs.Cloud.actionItemsText
            ) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(visibleActionItems.enumerated()), id: \.offset) { entry in
                        HStack(alignment: .top, spacing: 8) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .strokeBorder(DT.statusReady.opacity(0.58), lineWidth: 1)
                                .frame(width: 13, height: 13)
                                .padding(.top, 2)
                            Text(entry.element)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.dtLabelSecondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func transcriptInsightCard<Content: View>(
        title: String,
        systemImage: String,
        trailingText: String? = nil,
        accessibilityID: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DT.statusReady)
                    .frame(width: 13)

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .tracking(0.35)

                Spacer(minLength: 0)

                if let trailingText {
                    Text(trailingText)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.dtLabelTertiary)
                }
            }

            content()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.24))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 1)
        )
        .accessibilityIdentifier(accessibilityID)
    }

    private var summaryInsightText: String? {
        guard let summary = transcript?.summary else { return nil }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var visibleActionItems: [String] {
        transcript?.actionItems?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        ?? []
    }

    private var inspectorPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            inspectorSection("Details") {
                CloudInspectorMetric(iconName: "clock", title: "Duration", value: recording.durationText ?? "Unknown")
                CloudInspectorMetric(iconName: "internaldrive", title: "Size", value: recording.sizeText ?? "Unknown")
                CloudInspectorMetric(iconName: "waveform", title: "Audio", value: recording.audioShapeCompactText)
                CloudInspectorMetric(iconName: "doc", title: "Format", value: recording.formatText)
            }

            inspectorSection("Source") {
                CloudInspectorSourceMetric(recording: recording)
                CloudInspectorMetric(iconName: "calendar", title: "Created", value: recording.shortDateText)
                if localSessionURL != nil {
                    localSessionLink
                }
            }

            inspectorSection("Export") {
                if let retranscriptionLimitMessage {
                    inspectorNotice(retranscriptionLimitMessage)
                } else if let transcriptErrorMessage {
                    inspectorNotice(transcriptErrorMessage)
                }

                inspectorButton("Copy transcript", systemImage: "doc.on.doc", action: onCopyTranscript)
                    .disabled(transcript?.text.isEmpty != false)
                    .accessibilityIdentifier(AccessibilityIDs.Cloud.copyTranscriptButton)

                if localSessionURL == nil {
                    syncButton
                }

                Button {
                    if hasDownloadedAudio {
                        onRevealAudio()
                    } else {
                        onDownloadAudio()
                    }
                } label: {
                    inspectorButtonLabel(
                        isBusy: isDownloading,
                        title: hasDownloadedAudio ? "Reveal audio" : "Download audio",
                        busyTitle: "Downloading…",
                        systemImage: hasDownloadedAudio ? "waveform.path.ecg.rectangle" : "arrow.down.circle"
                    )
                }
                .buttonStyle(CloudInspectorButtonStyle())
                .disabled(isDownloading)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.downloadAudioButton)

                Button(action: onRetranscribe) {
                    inspectorButtonLabel(
                        isBusy: isRetranscribing,
                        title: "Retranscribe audio…",
                        busyTitle: "Retranscribing…",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(CloudInspectorButtonStyle(tint: Color.dtLabelTertiary, chrome: .hover))
                .disabled(
                    isRetranscribing ||
                    isTranscriptLoading ||
                    latestJob?.status.isActive == true ||
                    retranscriptionLimitMessage != nil ||
                    !recording.status.allowsTranscriptionRequest
                )
                .help(retranscriptionHelpText)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.retranscribeButton)
            }

            Spacer(minLength: 0)

            Button {
                onDelete()
            } label: {
                inspectorButtonLabel(
                    isBusy: isDeleting,
                    title: "Delete recording",
                    busyTitle: "Deleting…",
                    systemImage: "trash"
                )
            }
            .buttonStyle(CloudInspectorButtonStyle(tint: DT.systemOrange, destructive: true))
            .disabled(isDeleting)
            .accessibilityIdentifier(AccessibilityIDs.Cloud.deleteButton)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Color.black.opacity(0.26))
        }
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.dtLabelSecondary)
                .tracking(0.35)

            VStack(alignment: .leading, spacing: 9) {
                content()
            }
        }
    }

    private var retranscriptionHelpText: String {
        if let retranscriptionLimitMessage {
            return retranscriptionLimitMessage
        }
        if latestJob?.status.isActive == true {
            return "A transcription job is already in progress."
        }
        return "Start a new cloud transcription job"
    }

    private func inspectorButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            inspectorButtonLabel(isBusy: false, title: title, busyTitle: title, systemImage: systemImage)
        }
        .buttonStyle(CloudInspectorButtonStyle())
    }

    private func inspectorNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DT.systemOrange)
                .padding(.top, 1)

            Text(message)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.dtLabelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(DT.systemOrange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(DT.systemOrange.opacity(0.20), lineWidth: 1)
        )
    }

    private func inspectorButtonLabel(
        isBusy: Bool,
        title: String,
        busyTitle: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .medium))
                    .opacity(isBusy ? 0 : 1)
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.68)
                    .opacity(isBusy ? 1 : 0)
            }
            .frame(width: 15)

            Text(isBusy ? busyTitle : title)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 0)
        }
    }

    private var detailHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            CloudSourceIcon(recording: recording, size: 34)

            VStack(alignment: .leading, spacing: 5) {
                Text(recording.presentationTitle)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color.dtLabel)
                    .lineLimit(2)

                Text(recording.createdDateText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.dtLabelTertiary)
            }

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                if let recordingWebURL {
                    Button {
                        NSWorkspace.shared.open(recordingWebURL)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 12.5, weight: .semibold))
                    }
                    .buttonStyle(PanelIconButtonStyle(size: 28))
                    .help("Open in browser")
                    .accessibilityLabel("Open in browser")
                    .accessibilityIdentifier(AccessibilityIDs.Cloud.openRecordingInBrowserButton)
                }

                CloudStatusChip(status: recording.status, prominent: true)
            }
        }
    }

    @ViewBuilder
    private var latestJobStrip: some View {
        if let latestJob {
            HStack(spacing: 9) {
                Image(systemName: latestJob.status.isActive ? "hourglass" : "waveform.badge.checkmark")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(latestJob.status.detailColor)
                    .frame(width: 15)

                Text("Latest transcription")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.dtLabelSecondary)

                CloudJobStatusChip(status: latestJob.status)

                Text(latestJob.providerModelText)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if isJobHistoryLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.68)
                        .tint(latestJob.status.detailColor)
                } else if let error = latestJob.trimmedError {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(DT.systemOrange)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(latestJob.status.detailColor.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(latestJob.status.detailColor.opacity(0.14), lineWidth: 1)
            )
            .accessibilityIdentifier(AccessibilityIDs.Cloud.latestJobStatus)
        }
    }

    private var segmentsHeader: some View {
        HStack {
            Text("Transcript")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.dtLabelTertiary)
                .tracking(0.45)
            if let transcript {
                Text("\(transcript.displaySegmentRows.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule(style: .continuous).fill(Color.white.opacity(0.055)))
            }
            Spacer(minLength: 0)
            ZStack {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
                    .opacity(isTranscriptLoading ? 1 : 0)
            }
            .frame(width: 16, height: 16)
        }
    }

    @ViewBuilder
    private var localSessionLink: some View {
        if let localSessionURL {
            HStack(alignment: .center, spacing: 9) {
                Image(systemName: "folder")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(DT.statusReady)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Linked local session")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Color.dtLabelTertiary)
                        .tracking(0.2)
                    Text(localSessionURL.lastPathComponent)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.dtLabelSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                Button("Open", action: onRevealLocalSession)
                    .buttonStyle(PanelPushButtonStyle())
                    .frame(width: 54)
                    .accessibilityIdentifier(AccessibilityIDs.Cloud.revealLocalSessionButton)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.026))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.04), lineWidth: 1)
            )
        }
    }

    private var syncButton: some View {
        Button {
            if localSessionURL != nil {
                onRevealLocalSession()
            } else {
                onSyncToLocal()
            }
        } label: {
            inspectorButtonLabel(
                isBusy: isSyncingToLocal,
                title: localSessionURL == nil ? "Sync to local" : "Open local",
                busyTitle: "Syncing…",
                systemImage: localSessionURL == nil ? "arrow.down.doc" : "folder"
            )
        }
        .buttonStyle(CloudInspectorButtonStyle())
        .disabled(isSyncingToLocal)
    }

    private var meetingPlaybackStrip: some View {
        CloudMeetingPlaybackStrip(
            isPlaying: audioPlayer.isPlaying,
            currentTime: audioPlayer.currentTime,
            duration: audioPlayer.duration,
            sourceDescription: playbackSourceDescription,
            errorMessage: playbackErrorMessage,
            isPreparingAudio: isPreparingPlaybackAudio,
            hasAudio: playbackAudioURL != nil,
            waveformPeaks: audioPlayer.waveformPeaks,
            isLoadingWaveform: audioPlayer.isLoadingWaveform,
            onPlayPause: handlePlayPause,
            onSeek: audioPlayer.seek(to:)
        )
    }

    private func handlePlayPause() {
        guard playbackAudioURL != nil else {
            pendingAutoplayAfterPrepare = true
            onPreparePlaybackAudio()
            return
        }

        audioPlayer.load(url: playbackAudioURL, title: recording.presentationTitle)
        audioPlayer.togglePlayback()
    }

    private func jumpToSegment(_ row: CloudTranscriptSegmentDisplayRow) {
        guard let milliseconds = row.startMs ?? row.endMs else { return }
        pinnedSegmentID = row.id
        pendingPinnedSegmentIDAfterPrepare = nil
        let seconds = max(0, Double(milliseconds) / 1000.0 + 0.03)
        guard playbackAudioURL != nil else {
            pendingSeekAfterPrepare = seconds
            pendingPinnedSegmentIDAfterPrepare = row.id
            onPreparePlaybackAudio()
            return
        }
        audioPlayer.load(url: playbackAudioURL, title: recording.presentationTitle)
        audioPlayer.seek(to: seconds)
    }

    @ViewBuilder
    private var transcriptCard: some View {
        let segmentRows = transcript?.displaySegmentRows ?? []
        let activeSegmentID = activeSegmentID(in: segmentRows)
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(segmentRows.isEmpty ? 0.18 : 0.24))

            if !segmentRows.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(segmentRows) { row in
                                CloudTranscriptSegmentRow(
                                    row: row,
                                    isActive: row.id == activeSegmentID,
                                    onSelect: { jumpToSegment(row) }
                                )
                                    .id(row.id)
                            }
                        }
                        .padding(12)
                        .textSelection(.enabled)
                        .accessibilityIdentifier(AccessibilityIDs.Cloud.transcriptText)
                    }
                    .onChange(of: activeSegmentID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            } else {
                VStack(spacing: 9) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 23))
                        .foregroundStyle(Color.dtLabelTertiary)
                        .frame(width: 30, height: 30)

                    Text(transcriptPlaceholderText)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dtLabelSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(height: 34)

                    Button("Load transcript") {
                        onLoadTranscript()
                    }
                    .buttonStyle(PanelPushButtonStyle())
                    .frame(width: 150)
                    .disabled(isTranscriptLoading)
                    .accessibilityIdentifier(AccessibilityIDs.Cloud.loadTranscriptButton)
                }
                .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 240, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        )
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private func activeSegmentID(in rows: [CloudTranscriptSegmentDisplayRow]) -> String? {
        let timeMs = Int((audioPlayer.currentTime * 1000).rounded())
        let timedRows = rows.filter { $0.startMs != nil || $0.endMs != nil }
        guard !timedRows.isEmpty else { return pinnedSegmentID }

        if let pinnedSegmentID,
           let pinned = timedRows.first(where: { $0.id == pinnedSegmentID }),
           segment(pinned, contains: timeMs, within: timedRows) {
            return pinnedSegmentID
        }

        return timedRows
            .filter { ($0.startMs ?? $0.endMs ?? Int.max) <= timeMs + 250 }
            .max {
                ($0.startMs ?? $0.endMs ?? 0) < ($1.startMs ?? $1.endMs ?? 0)
            }?
            .id
        ?? timedRows.min {
            abs(($0.startMs ?? $0.endMs ?? 0) - timeMs) < abs(($1.startMs ?? $1.endMs ?? 0) - timeMs)
        }?
        .id
    }

    private func segment(
        _ row: CloudTranscriptSegmentDisplayRow,
        contains timeMs: Int,
        within rows: [CloudTranscriptSegmentDisplayRow]
    ) -> Bool {
        guard let start = row.startMs ?? row.endMs else { return false }
        let nextStart = rows
            .compactMap(\.startMs)
            .filter { $0 > start }
            .min()
        let end = max(row.endMs ?? nextStart ?? (start + 60_000), start + 500)
        return timeMs >= start - 750 && timeMs < end
    }

    private var transcriptPlaceholderText: String {
        return transcriptErrorMessage ?? "Segments are not available for this recording yet."
    }

}

@MainActor
private final class CloudMeetingAudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var waveformPeaks: [Float] = []
    @Published private(set) var isLoadingWaveform = false

    private var player: AVPlayer?
    private var currentURL: URL?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var waveformTask: Task<Void, Never>?
    private var waveformCache: [URL: [Float]] = [:]
    private var currentTitle = "Meeting playback"
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []

    init() {
        configureRemoteCommands()
    }

    func load(url: URL?, title: String) {
        currentTitle = title
        guard currentURL != url else {
            refreshDuration()
            updateNowPlayingInfo()
            return
        }

        removeObservers()
        player?.pause()
        player = nil
        currentURL = url
        currentTime = 0
        duration = 0
        isPlaying = false
        waveformTask?.cancel()
        waveformPeaks = []
        isLoadingWaveform = false
        updateNowPlayingInfo()

        guard let url else { return }

        let item = AVPlayerItem(url: url)
        let nextPlayer = AVPlayer(playerItem: item)
        player = nextPlayer
        refreshDuration()
        loadWaveform(for: url)

        timeObserver = nextPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.18, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                self?.refreshDuration()
                self?.updateNowPlayingInfo()
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isPlaying = false
                self?.seek(to: 0)
                self?.updateNowPlayingInfo()
            }
        }
        updateNowPlayingInfo()
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        refreshDuration()
        updateNowPlayingInfo()
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func close() {
        removeObservers()
        waveformTask?.cancel()
        waveformTask = nil
        player?.pause()
        player = nil
        currentURL = nil
        currentTime = 0
        duration = 0
        isPlaying = false
        waveformPeaks = []
        isLoadingWaveform = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, max(duration, seconds)))
        currentTime = clamped
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlayingInfo()
    }

    private func pause() {
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    private func refreshDuration() {
        let seconds = player?.currentItem?.duration.seconds ?? 0
        if seconds.isFinite, seconds > 0 {
            duration = seconds
        }
    }

    private func updateNowPlayingInfo() {
        guard currentURL != nil else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTitle,
            MPMediaItemPropertyArtist: "Recappi",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true

        remoteCommandTargets = [
            (
                commandCenter.playCommand,
                commandCenter.playCommand.addTarget { [weak self] _ in
                    Task { @MainActor in self?.play() }
                    return .success
                }
            ),
            (
                commandCenter.pauseCommand,
                commandCenter.pauseCommand.addTarget { [weak self] _ in
                    Task { @MainActor in self?.pause() }
                    return .success
                }
            ),
            (
                commandCenter.togglePlayPauseCommand,
                commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
                    Task { @MainActor in self?.togglePlayback() }
                    return .success
                }
            ),
            (
                commandCenter.changePlaybackPositionCommand,
                commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
                    guard let event = event as? MPChangePlaybackPositionCommandEvent else {
                        return .commandFailed
                    }
                    Task { @MainActor in self?.seek(to: event.positionTime) }
                    return .success
                }
            ),
        ]
    }

    private func loadWaveform(for url: URL) {
        if let cached = waveformCache[url] {
            waveformPeaks = cached
            return
        }

        isLoadingWaveform = true
        waveformTask = Task { [url] in
            let peaks = await Task.detached(priority: .utility) {
                (try? PlaybackWaveformExtractor.cachedPeaks(from: url)) ?? []
            }.value
            guard currentURL == url, !Task.isCancelled else { return }
            waveformCache[url] = peaks
            waveformPeaks = peaks
            isLoadingWaveform = false
        }
    }

    private func removeObservers() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
    }
}

private struct CloudMeetingPlaybackStrip: View {
    let isPlaying: Bool
    let currentTime: Double
    let duration: Double
    let sourceDescription: String
    let errorMessage: String?
    let isPreparingAudio: Bool
    let hasAudio: Bool
    let waveformPeaks: [Float]
    let isLoadingWaveform: Bool
    let onPlayPause: () -> Void
    let onSeek: (Double) -> Void

    private var sliderUpperBound: Double {
        max(duration, currentTime, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Button(action: onPlayPause) {
                    ZStack {
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .medium))
                            .opacity(isPreparingAudio ? 0 : 1)
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .opacity(isPreparingAudio ? 1 : 0)
                    }
                    .frame(width: 24, height: 24)
                }
                .buttonStyle(PanelIconButtonStyle(size: 24))
                .disabled(isPreparingAudio)
                .help(hasAudio ? "Play meeting audio" : "Download audio preview")

                VStack(alignment: .leading, spacing: 2) {
                    Text("Meeting playback")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.dtLabel)
                    Text(errorMessage ?? sourceDescription)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(errorMessage == nil ? Color.dtLabelSecondary : DT.systemOrange)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                Text("\(Self.timeText(currentTime)) / \(duration > 0 ? Self.timeText(duration) : "--:--")")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dtLabelTertiary)
            }

            CloudPlaybackWaveformScrubber(
                progress: sliderProgress,
                isEnabled: hasAudio && !isPreparingAudio,
                peaks: waveformPeaks,
                isLoadingPeaks: isLoadingWaveform,
                onSeekProgress: { progress in
                    onSeek(progress * sliderUpperBound)
                }
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.black.opacity(0.24))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.085), lineWidth: 1)
        )
    }

    private var sliderProgress: Double {
        guard sliderUpperBound > 0 else { return 0 }
        return min(max(0, currentTime / sliderUpperBound), 1)
    }

    private static func timeText(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded(.down)))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private struct CloudPlaybackWaveformScrubber: View {
    let progress: Double
    let isEnabled: Bool
    let peaks: [Float]
    let isLoadingPeaks: Bool
    let onSeekProgress: (Double) -> Void

    private let trackHeight: CGFloat = 32
    private let horizontalInset: CGFloat = 7
    private let playheadWidth: CGFloat = 7

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let clampedProgress = min(max(progress, 0), 1)
            let inset = min(horizontalInset, max(width / 2 - 1, 0))
            let contentWidth = max(width - inset * 2, 1)
            let spacing: CGFloat = 2.4
            let barCount = Self.barCount(for: contentWidth)
            let barWidth = Self.barWidth(for: contentWidth, barCount: barCount, spacing: spacing)
            let timelineStartX = inset + barWidth / 2
            let timelineWidth = max(contentWidth - barWidth, 1)
            let playheadX = timelineStartX + timelineWidth * clampedProgress

            ZStack(alignment: .leading) {
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(barColor(index: index, count: barCount))
                            .frame(width: barWidth, height: barHeight(index: index, count: barCount))
                    }
                }
                .frame(width: contentWidth, height: trackHeight, alignment: .center)
                .offset(x: inset)
                .opacity(isEnabled ? (isLoadingPeaks ? 0.58 : 1) : 0.46)

                CloudPlaybackPlayhead(color: playheadColor, isEnabled: isEnabled)
                    .frame(width: playheadWidth, height: trackHeight)
                    .offset(x: playheadX - playheadWidth / 2)
                .allowsHitTesting(false)
            }
            .frame(width: width, height: trackHeight, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        let progress = (value.location.x - timelineStartX) / timelineWidth
                        onSeekProgress(min(max(progress, 0), 1))
                    }
            )
        }
        .frame(height: trackHeight + 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
    }

    private static func barCount(for width: CGFloat) -> Int {
        max(18, min(128, Int(width / 5.2)))
    }

    private static func barWidth(for width: CGFloat, barCount: Int, spacing: CGFloat) -> CGFloat {
        let availableWidth = width - spacing * CGFloat(max(barCount - 1, 0))
        return max(1.8, availableWidth / CGFloat(max(barCount, 1)))
    }

    private var playheadColor: Color {
        Color.white.opacity(0.88)
    }

    private func barColor(index: Int, count: Int) -> Color {
        let playedCount = Int((Double(count) * min(max(progress, 0), 1)).rounded(.down))
        if index < playedCount {
            return DT.waveformLit.opacity(isEnabled ? 0.92 : 0.42)
        }
        return Color.white.opacity(isEnabled ? 0.22 : 0.12)
    }

    private func barHeight(index: Int, count: Int) -> CGFloat {
        let normalizedPeak = peakValue(index: index, count: count)
        let height = 5 + (trackHeight - 5) * CGFloat(normalizedPeak)
        return max(5, min(trackHeight, height))
    }

    private func peakValue(index: Int, count: Int) -> Float {
        guard !peaks.isEmpty else {
            return isLoadingPeaks ? 0.18 : 0.08
        }

        guard peaks.count > 1, count > 1 else {
            return min(max(peaks.first ?? 0, 0), 1)
        }

        let sourcePosition = Double(index) * Double(peaks.count - 1) / Double(count - 1)
        let lowerIndex = min(max(Int(sourcePosition.rounded(.down)), 0), peaks.count - 1)
        let upperIndex = min(lowerIndex + 1, peaks.count - 1)
        let fraction = Float(sourcePosition - Double(lowerIndex))
        let lower = min(max(peaks[lowerIndex], 0), 1)
        let upper = min(max(peaks[upperIndex], 0), 1)
        return lower + ((upper - lower) * fraction)
    }
}

private struct CloudPlaybackPlayhead: View {
    let color: Color
    let isEnabled: Bool

    var body: some View {
        VStack(spacing: 0) {
            handleDot
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            color.opacity(lineOpacity * 0.50),
                            color.opacity(lineOpacity),
                            color.opacity(lineOpacity * 0.50),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 1)
                .frame(maxHeight: .infinity)
            handleDot
        }
        .shadow(color: color.opacity(isEnabled ? 0.22 : 0.06), radius: 2.5, y: 0.5)
    }

    private var lineOpacity: Double {
        isEnabled ? 0.72 : 0.30
    }

    private var handleDot: some View {
        ZStack {
            Circle()
                .fill(color.opacity(isEnabled ? 0.92 : 0.40))
            Circle()
                .strokeBorder(Color.black.opacity(isEnabled ? 0.45 : 0.22), lineWidth: 0.8)
        }
        .frame(width: 5, height: 5)
    }
}

private struct CloudTranscriptSegmentDisplayRow: Identifiable {
    let id: String
    let marker: String
    let startMs: Int?
    let endMs: Int?
    let speaker: String?
    let text: String
}

private struct CloudTranscriptSegmentRow: View {
    let row: CloudTranscriptSegmentDisplayRow
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                Capsule(style: .continuous)
                    .fill(isActive ? DT.waveformLit : Color.white.opacity(0.055))
                    .frame(width: 3)
                    .padding(.vertical, 2)

                Text(row.marker)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isActive ? DT.waveformLit : Color.dtLabelTertiary)
                    .frame(width: 64, alignment: .leading)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    if let speaker = row.speaker {
                        Text(speaker)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(isActive ? DT.statusReady : Color.dtLabelSecondary)
                            .lineLimit(1)
                    }

                    Text(row.text)
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(Color.dtLabel)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? DT.waveformLit.opacity(0.105) : Color.white.opacity(0.012))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isActive ? DT.statusReady.opacity(0.24) : Color.white.opacity(0.018), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(row.startMs == nil && row.endMs == nil ? "No timing for this segment" : "Jump audio to this segment")
        .disabled(row.startMs == nil && row.endMs == nil)
    }
}

private struct CloudInspectorMetric: View {
    let iconName: String
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: iconName)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.dtLabelTertiary)
                .frame(width: 14)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .tracking(0.2)
                    .lineLimit(1)

                Text(value)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

private struct CloudInspectorSourceMetric: View {
    let recording: CloudRecording

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            CloudSourceIcon(recording: recording, size: 16)
                .opacity(0.92)
                .frame(width: 14, height: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text("Captured from")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .tracking(0.2)
                    .lineLimit(1)

                Text(recording.sourceLine)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Captured from: \(recording.sourceLine)")
    }
}

func cloudRecordingWebURL(recordingID: String, backendBaseURL: String) -> URL? {
    let trimmedID = recordingID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedID.isEmpty else { return nil }

    let rawBaseURL = backendBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !rawBaseURL.isEmpty, var components = URLComponents(string: rawBaseURL) else {
        return nil
    }

    components.path = "/recordings/\(trimmedID)"
    components.query = nil
    components.fragment = nil
    return components.url
}

private struct CloudInspectorButtonStyle: ButtonStyle {
    enum Chrome {
        case always
        case hover
    }

    var tint: Color = DT.waveformLit
    var destructive = false
    var chrome: Chrome = .always
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        let showChrome = chrome == .always || isHovered || configuration.isPressed
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(destructive ? tint : Color.dtLabel)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(backgroundOpacity(isPressed: configuration.isPressed, showChrome: showChrome))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(showChrome ? borderColor : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(DT.ease(0.10), value: configuration.isPressed)
            .animation(DT.ease(0.12), value: isHovered)
            .onHover { hovering in
                isHovered = hovering
            }
    }

    private func backgroundOpacity(isPressed: Bool, showChrome: Bool) -> Color {
        guard showChrome else { return Color.clear }
        if destructive {
            return tint.opacity(isPressed ? 0.16 : 0.08)
        }
        return Color.white.opacity(isPressed ? 0.11 : 0.055)
    }

    private var borderColor: Color {
        destructive ? tint.opacity(0.18) : Color.white.opacity(0.065)
    }
}

private struct CloudStatusChip: View {
    let status: CloudRecordingStatus
    var prominent: Bool = false

    var body: some View {
        Text(status.displayName)
            .font(.system(size: prominent ? 11 : 9, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, prominent ? 9 : 6)
            .padding(.vertical, prominent ? 5 : 3)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.13))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(color.opacity(0.22), lineWidth: 0.5)
            )
    }

    private var color: Color {
        switch status {
        case .ready:
            return DT.statusReady
        case .uploading:
            return DT.statusUploading
        case .failed, .aborted:
            return DT.statusWarning
        case .unknown:
            return Color.dtLabelTertiary
        }
    }
}

private struct CloudJobStatusChip: View {
    let status: RemoteJobStatus

    var body: some View {
        Text(status.displayName)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(status.detailColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule(style: .continuous)
                    .fill(status.detailColor.opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(status.detailColor.opacity(0.22), lineWidth: 0.5)
            )
    }
}

private extension RemoteJobStatus {
    var displayName: String {
        switch self {
        case .queued:
            return "Queued"
        case .running:
            return "Running"
        case .succeeded:
            return "Completed"
        case .failed:
            return "Failed"
        }
    }

    var detailColor: Color {
        switch self {
        case .queued:
            return DT.waveformLit
        case .running:
            return DT.statusUploading
        case .succeeded:
            return DT.statusReady
        case .failed:
            return DT.systemOrange
        }
    }
}

private extension TranscriptionJob {
    var providerModelText: String {
        [provider, model, language]
            .compactMap { value in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed?.isEmpty == false ? trimmed : nil
            }
            .joined(separator: " · ")
    }

    var trimmedError: String? {
        let trimmed = error?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

private struct CloudSourceIcon: View {
    let recording: CloudRecording
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(DT.statusReady.opacity(0.10))

            if let icon = recording.sourceAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.72, height: size * 0.72)
            } else {
                Image(systemName: recording.sourceIconName)
                    .font(.system(size: size * 0.42, weight: .medium))
                    .foregroundStyle(DT.statusReady)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}

private extension TranscriptResponse {
    var displaySegmentRows: [CloudTranscriptSegmentDisplayRow] {
        let decodedRows = segments.enumerated().compactMap { index, segment -> CloudTranscriptSegmentDisplayRow? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }

            return CloudTranscriptSegmentDisplayRow(
                id: "segment-\(index)-\(segment.startMs ?? -1)-\(segment.endMs ?? -1)",
                marker: Self.timeMarker(startMs: segment.startMs, endMs: segment.endMs) ?? "#\(index + 1)",
                startMs: segment.startMs,
                endMs: segment.endMs,
                speaker: segment.speaker,
                text: text
            )
        }

        if !decodedRows.isEmpty {
            return decodedRows
        }

        return text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { index, line in
                CloudTranscriptSegmentDisplayRow(
                    id: "line-\(index)",
                    marker: "#\(index + 1)",
                    startMs: nil,
                    endMs: nil,
                    speaker: nil,
                    text: line
                )
            }
    }

    private static func timeMarker(startMs: Int?, endMs: Int?) -> String? {
        switch (startMs, endMs) {
        case (.some(let start), .some(let end)):
            return "\(timecode(start))-\(timecode(end))"
        case (.some(let start), .none):
            return timecode(start)
        case (.none, .some(let end)):
            return timecode(end)
        case (.none, .none):
            return nil
        }
    }

    private static func timecode(_ milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private extension CloudRecording {
    var presentationTitle: String {
        if let summaryTitle = clean(summaryTitle) {
            return summaryTitle
        }

        if let title = clean(title), !Self.isTimestampTitle(title) {
            return title
        }

        if let sourceTitle = clean(sourceTitle), sourceTitle != "All system audio" {
            return sourceTitle
        }

        if let appName = clean(sourceAppName) {
            return "\(appName) recording"
        }

        if let createdAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "Meeting at \(formatter.string(from: createdAt))"
        }

        return "Untitled recording"
    }

    var sourceLine: String {
        if let appName = clean(sourceAppName) {
            return appName
        }

        if let inferred = inferredSource {
            return inferred.displayName
        }

        if let sourceTitle = clean(sourceTitle), sourceTitle != presentationTitle {
            return sourceTitle
        }

        if let title = clean(title), title == "Audio recording" {
            return "All system audio"
        }

        return "Source unknown"
    }

    var sourceIconName: String {
        if sourceLine == "All system audio" {
            return "speaker.wave.2.fill"
        }
        if inferredSource != nil || clean(sourceAppName) != nil || clean(sourceAppBundleID) != nil {
            return "app.fill"
        }
        return "waveform"
    }

    var sourceAppIcon: NSImage? {
        guard let bundleID = clean(sourceAppBundleID) ?? inferredSource?.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }

    private var inferredSource: CloudRecordingSource? {
        let candidates = [
            sourceTitle,
            title,
        ].compactMap(clean)

        for candidate in candidates {
            if let source = Self.knownSources.first(where: { $0.matches(candidate) }) {
                return source
            }
        }

        return nil
    }

    var durationText: String? {
        guard let durationMs, durationMs > 0 else { return nil }
        let totalSeconds = Int((Double(durationMs) / 1000.0).rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var sizeText: String? {
        guard let sizeBytes, sizeBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var audioShapeText: String {
        let rate = sampleRate.map { "\($0) Hz" } ?? "unknown rate"
        let channelText: String
        switch channels {
        case 1:
            channelText = "mono"
        case 2:
            channelText = "stereo"
        case let channels?:
            channelText = "\(channels) ch"
        case nil:
            channelText = "unknown channels"
        }
        return "\(rate), \(channelText)"
    }

    var audioShapeCompactText: String {
        let rate = sampleRate.map(Self.compactSampleRate) ?? "unknown rate"
        return "\(rate) · \(channelCompactText)"
    }

    var formatText: String {
        guard let contentType = clean(contentType) else { return "Unknown" }
        switch contentType.lowercased() {
        case "audio/wav", "audio/x-wav":
            return "WAV"
        case "audio/mpeg", "audio/mp3":
            return "MP3"
        case "audio/mp4", "audio/m4a", "video/mp4":
            return "M4A"
        case "audio/aiff", "audio/x-aiff":
            return "AIFF"
        case "audio/aac":
            return "AAC"
        case "audio/ogg":
            return "OGG"
        case "audio/flac", "audio/x-flac":
            return "FLAC"
        default:
            return contentType
                .replacingOccurrences(of: "audio/", with: "")
                .uppercased()
        }
    }

    private var channelCompactText: String {
        switch channels {
        case 1:
            return "mono"
        case 2:
            return "stereo"
        case let channels?:
            return "\(channels) ch"
        case nil:
            return "unknown"
        }
    }

    private static func compactSampleRate(_ sampleRate: Int) -> String {
        guard sampleRate >= 1000 else { return "\(sampleRate) Hz" }
        if sampleRate % 1000 == 0 {
            return "\(sampleRate / 1000) kHz"
        }
        return String(format: "%.1f kHz", Double(sampleRate) / 1000.0)
    }

    var shortDateText: String {
        guard let date = createdAt else { return "Unknown date" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var createdDateText: String {
        guard let date = createdAt else { return "Created date unknown" }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func clean(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    private static func isTimestampTitle(_ title: String) -> Bool {
        title.range(
            of: #"^\d{4}-\d{2}-\d{2}_\d{6}$"#,
            options: .regularExpression
        ) != nil
    }

    private static let knownSources: [CloudRecordingSource] = [
        CloudRecordingSource(displayName: "Google Chrome", bundleID: "com.google.Chrome", aliases: ["chrome", "google chrome"]),
        CloudRecordingSource(displayName: "Safari", bundleID: "com.apple.Safari", aliases: ["safari"]),
        CloudRecordingSource(displayName: "Zoom", bundleID: "us.zoom.xos", aliases: ["zoom"]),
        CloudRecordingSource(displayName: "Microsoft Teams", bundleID: "com.microsoft.teams2", aliases: ["teams", "microsoft teams"]),
        CloudRecordingSource(displayName: "Slack", bundleID: "com.tinyspeck.slackmacgap", aliases: ["slack", "huddle"]),
        CloudRecordingSource(displayName: "Discord", bundleID: "com.hnc.Discord", aliases: ["discord"]),
        CloudRecordingSource(displayName: "FaceTime", bundleID: "com.apple.FaceTime", aliases: ["facetime", "face time"]),
        CloudRecordingSource(displayName: "Arc", bundleID: "company.thebrowser.Browser", aliases: ["arc"]),
        CloudRecordingSource(displayName: "Microsoft Edge", bundleID: "com.microsoft.edgemac", aliases: ["edge", "microsoft edge"]),
        CloudRecordingSource(displayName: "Firefox", bundleID: "org.mozilla.firefox", aliases: ["firefox"]),
    ]
}

private struct CloudRecordingSource {
    let displayName: String
    let bundleID: String
    let aliases: [String]

    func matches(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return aliases.contains { alias in
            normalized.contains(alias)
        }
    }
}

private extension BillingStatus {
    var storageProgress: Double {
        guard !hasUnlimitedStorage else { return 0 }
        guard storageCapBytes > 0 else { return 0 }
        return Double(storageBytes) / Double(storageCapBytes)
    }

    var minutesProgress: Double {
        guard !hasUnlimitedMinutes else { return 0 }
        guard minutesCap > 0 else { return 0 }
        return minutesUsed / minutesCap
    }

    var isOverAnyLimit: Bool {
        effectiveIsOverAnyLimit
    }

    var storageUsageText: String {
        let used = ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file)
        guard !hasUnlimitedStorage else { return "\(used) used" }
        let cap = ByteCountFormatter.string(fromByteCount: storageCapBytes, countStyle: .file)
        return "\(used) / \(cap)"
    }

    var minutesUsageText: String {
        guard !hasUnlimitedMinutes else { return "\(formattedMinutes(minutesUsed)) min used" }
        return "\(formattedMinutes(minutesUsed)) / \(formattedMinutes(minutesCap)) min"
    }

    var periodEndText: String? {
        guard let periodEnd else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: periodEnd)
    }

    private func formattedMinutes(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.1f", value)
    }
}
