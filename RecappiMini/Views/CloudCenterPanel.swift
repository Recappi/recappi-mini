import AppKit
import AVFoundation
import SwiftUI

struct CloudCenterPanel: View {
    @StateObject private var store = CloudLibraryStore()
    @ObservedObject private var sessionStore = AuthSessionStore.shared
    @State private var showingDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            if shouldShowBillingSummary {
                billingSummary
                Divider().overlay(Color.white.opacity(0.08))
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 920, height: 760)
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
    }

    private var shouldShowBillingSummary: Bool {
        sessionStore.currentSession != nil &&
            (store.billingStatus != nil || store.isLoadingBilling || store.billingErrorMessage != nil)
    }

    private var billingSummary: some View {
        CloudBillingSummary(
            status: store.billingStatus,
            errorMessage: store.billingErrorMessage,
            isLoading: store.isLoadingBilling,
            isOpeningBilling: store.isOpeningBilling,
            onOpenBilling: { Task { await store.openBillingPortalOrPlans() } },
            onOpenPlans: store.openPlansPage
        )
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var header: some View {
        HStack(spacing: 12) {
            LogoTile(size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text("Recappi Cloud")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.dtLabel)
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

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
                .frame(width: 300)

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
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .textCase(.uppercase)
                    .tracking(1.2)
                Spacer(minLength: 0)
                Text("\(store.recordings.count)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dtLabelTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)

            ScrollView {
                LazyVStack(spacing: 7) {
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
                transcript: store.selectedTranscript,
                transcriptErrorMessage: store.transcriptErrorMessage,
                localSessionURL: store.selectedLocalSessionURL,
                playbackAudioURL: store.selectedPlaybackAudioURL,
                playbackSourceDescription: store.selectedPlaybackSourceDescription,
                playbackErrorMessage: store.playbackErrorMessage,
                isTranscriptLoading: store.isTranscriptLoading,
                isPreparingPlaybackAudio: store.isPreparingPlaybackAudio,
                isDownloading: store.isDownloading,
                isDeleting: store.isDeleting,
                isSyncingToLocal: store.isSyncingToLocal,
                hasDownloadedAudio: store.lastDownloadedAudioURL != nil,
                onLoadTranscript: { Task { await store.loadTranscriptForSelection() } },
                onCopyTranscript: store.copySelectedTranscript,
                onPreparePlaybackAudio: { Task { await store.preparePlaybackAudioForSelection() } },
                onRevealLocalSession: store.revealSelectedLocalSession,
                onSyncToLocal: { Task { await store.syncSelectedRecordingToLocal() } },
                onDownloadAudio: { Task { await store.downloadSelectedAudio() } },
                onRevealAudio: store.revealLastDownloadedAudio,
                onDelete: { showingDeleteConfirmation = true }
            )
            .task(id: recording.id) {
                await store.loadTranscriptForSelection()
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.stack.badge.person.crop")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.dtLabelTertiary)
                Text("Select a recording")
                    .font(.system(size: 15, weight: .semibold))
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
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.dtLabel)
            Text("Fetching your remote recordings.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dtLabelSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "cloud")
                .font(.system(size: 34))
                .foregroundStyle(DT.waveformLit)
            Text("No cloud recordings yet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.dtLabel)
            Text("Record a meeting from the main panel. Finished transcripts will appear here.")
                .font(.system(size: 12))
                .foregroundStyle(Color.dtLabelSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
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
                .font(.system(size: 16, weight: .semibold))
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
                .font(.system(size: 16, weight: .semibold))
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
                .font(.system(size: 11, weight: .semibold))
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
        if sessionStore.currentSession != nil {
            return "Manage recordings, transcripts, billing, and limits"
        }
        return "Browse and manage remote recordings after sign-in"
    }
}

private struct CloudBillingSummary: View {
    let status: BillingStatus?
    let errorMessage: String?
    let isLoading: Bool
    let isOpeningBilling: Bool
    let onOpenBilling: () -> Void
    let onOpenPlans: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text("Plan")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.dtLabelTertiary)
                        .textCase(.uppercase)
                        .tracking(1.1)

                    if let status {
                        Text(status.tier.displayName)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(status.isOverAnyLimit ? DT.systemOrange : DT.waveformLit)
                    } else if isLoading {
                        Text("Loading…")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.dtLabelSecondary)
                    } else {
                        Text("Unavailable")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(DT.systemOrange)
                    }
                }

                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 180, alignment: .leading)

            if let status {
                CloudLimitMeter(
                    title: "Storage",
                    valueText: status.storageUsageText,
                    progress: status.storageProgress,
                    isOverLimit: status.isOverStorage
                )
                CloudLimitMeter(
                    title: "Minutes",
                    valueText: status.minutesUsageText,
                    progress: status.minutesProgress,
                    isOverLimit: status.isOverMinutes
                )
            } else {
                CloudLimitMeter(title: "Storage", valueText: "Loading limits", progress: 0, isOverLimit: false)
                    .redacted(reason: isLoading ? .placeholder : [])
                CloudLimitMeter(title: "Minutes", valueText: errorMessage ?? "Loading limits", progress: 0, isOverLimit: false)
                    .redacted(reason: isLoading ? .placeholder : [])
            }

            Spacer(minLength: 0)

            VStack(spacing: 7) {
                Button {
                    onOpenBilling()
                } label: {
                    if isOpeningBilling {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Opening…")
                        }
                    } else {
                        Text("Billing")
                    }
                }
                .buttonStyle(PanelPushButtonStyle(primary: true))
                .disabled(isOpeningBilling)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.billingButton)

                Button("Plans", action: onOpenPlans)
                    .buttonStyle(PanelPushButtonStyle())
                    .accessibilityIdentifier(AccessibilityIDs.Cloud.plansButton)
            }
            .frame(width: 112)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.075), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Cloud billing and limits")
        .accessibilityIdentifier(AccessibilityIDs.Cloud.billingStatus)
    }

    private var subtitle: String {
        if let errorMessage {
            return errorMessage
        }
        if let status {
            if status.isOverAnyLimit {
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
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .textCase(.uppercase)
                    .tracking(0.8)
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
        .frame(width: 150)
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
                            .font(.system(size: 13, weight: .semibold))
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
                    .fill(isSelected ? DT.recordingChip.opacity(0.92) : Color.white.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? DT.waveformLit.opacity(0.42) : Color.white.opacity(0.055), lineWidth: 1)
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
    let transcript: TranscriptResponse?
    let transcriptErrorMessage: String?
    let localSessionURL: URL?
    let playbackAudioURL: URL?
    let playbackSourceDescription: String
    let playbackErrorMessage: String?
    let isTranscriptLoading: Bool
    let isPreparingPlaybackAudio: Bool
    let isDownloading: Bool
    let isDeleting: Bool
    let isSyncingToLocal: Bool
    let hasDownloadedAudio: Bool
    let onLoadTranscript: () -> Void
    let onCopyTranscript: () -> Void
    let onPreparePlaybackAudio: () -> Void
    let onRevealLocalSession: () -> Void
    let onSyncToLocal: () -> Void
    let onDownloadAudio: () -> Void
    let onRevealAudio: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                detailHeader
                metadataStrip
                contextAndPlayback
                segmentsHeader
                transcriptCard
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider().overlay(Color.white.opacity(0.08))

            actionBar
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .background(Color.black.opacity(0.10))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            audioPlayer.load(url: playbackAudioURL)
        }
        .onChange(of: playbackAudioURL) { _, url in
            audioPlayer.load(url: url)
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
            audioPlayer.load(url: playbackAudioURL)
        }
        .onDisappear {
            audioPlayer.close()
        }
    }

    private var detailHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            CloudSourceIcon(recording: recording, size: 44)

            VStack(alignment: .leading, spacing: 5) {
                Text(recording.presentationTitle)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.dtLabel)
                    .lineLimit(2)

                HStack(spacing: 7) {
                    Image(systemName: recording.sourceIconName)
                        .font(.system(size: 10, weight: .semibold))
                    Text(recording.sourceLine)
                        .lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.dtLabelSecondary)

                Text(recording.createdDateText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.dtLabelTertiary)
            }

            Spacer(minLength: 0)

            CloudStatusChip(status: recording.status, prominent: true)
        }
    }

    private var metadataStrip: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                CloudMetadataPill(iconName: "clock", title: "Duration", value: recording.durationText ?? "Unknown")
                CloudMetadataPill(iconName: "internaldrive", title: "Size", value: recording.sizeText ?? "Unknown")
                CloudMetadataPill(iconName: "waveform", title: "Audio", value: recording.audioShapeCompactText)
                CloudMetadataPill(iconName: "doc", title: "Format", value: recording.formatText)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                CloudMetadataPill(iconName: "clock", title: "Duration", value: recording.durationText ?? "Unknown")
                CloudMetadataPill(iconName: "internaldrive", title: "Size", value: recording.sizeText ?? "Unknown")
                CloudMetadataPill(iconName: "waveform", title: "Audio", value: recording.audioShapeCompactText)
                CloudMetadataPill(iconName: "doc", title: "Format", value: recording.formatText)
            }
        }
    }

    private var contextAndPlayback: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                if localSessionURL != nil {
                    localSessionLink
                        .frame(maxWidth: .infinity)
                }
                meetingPlaybackStrip
                    .frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 12) {
                if localSessionURL != nil {
                    localSessionLink
                }
                meetingPlaybackStrip
            }
        }
    }

    private var segmentsHeader: some View {
        HStack {
            Text("Segments")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dtLabelSecondary)
                .textCase(.uppercase)
                .tracking(1.2)
            if let transcript {
                Text("\(transcript.displaySegmentRows.count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
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
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DT.waveformLit)
                    .frame(width: 14)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Linked local session")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.dtLabelTertiary)
                        .textCase(.uppercase)
                        .tracking(0.7)
                    Text(localSessionURL.lastPathComponent)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.dtLabelSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                Button("Open folder", action: onRevealLocalSession)
                    .buttonStyle(PanelPushButtonStyle())
                    .frame(width: 92)
                    .accessibilityIdentifier(AccessibilityIDs.Cloud.revealLocalSessionButton)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.055), lineWidth: 1)
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
            if isSyncingToLocal {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Syncing…")
                }
            } else {
                Text(localSessionURL == nil ? "Sync to local" : "Open local")
            }
        }
        .buttonStyle(PanelPushButtonStyle())
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

        audioPlayer.load(url: playbackAudioURL)
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
        audioPlayer.load(url: playbackAudioURL)
        audioPlayer.seek(to: seconds)
    }

    @ViewBuilder
    private var transcriptCard: some View {
        let segmentRows = transcript?.displaySegmentRows ?? []
        let activeSegmentID = activeSegmentID(in: segmentRows)
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(segmentRows.isEmpty ? 0.18 : 0.22))

            if !segmentRows.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
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
                    ZStack {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 23))
                            .foregroundStyle(Color.dtLabelTertiary)
                            .opacity(isTranscriptLoading ? 0 : 1)

                        ProgressView()
                            .controlSize(.regular)
                            .scaleEffect(0.82)
                            .opacity(isTranscriptLoading ? 1 : 0)
                    }
                    .frame(width: 30, height: 30)

                    Text(transcriptPlaceholderText)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.dtLabelSecondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .frame(height: 34)

                    Button(isTranscriptLoading ? "Loading…" : "Load transcript") {
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
                .strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
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
        if isTranscriptLoading {
            return "Loading transcript…"
        }

        return transcriptErrorMessage ?? "Segments are not available for this recording yet."
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button("Copy transcript", action: onCopyTranscript)
                .buttonStyle(PanelPushButtonStyle())
                .disabled(transcript?.text.isEmpty != false)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.copyTranscriptButton)

            syncButton

            Button {
                if hasDownloadedAudio {
                    onRevealAudio()
                } else {
                    onDownloadAudio()
                }
            } label: {
                if isDownloading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Downloading…")
                    }
                } else {
                    Text(hasDownloadedAudio ? "Reveal audio" : "Download audio")
                }
            }
            .buttonStyle(PanelPushButtonStyle())
            .disabled(isDownloading)
            .accessibilityIdentifier(AccessibilityIDs.Cloud.downloadAudioButton)

            Button {
                onDelete()
            } label: {
                if isDeleting {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Deleting…")
                    }
                } else {
                    Text("Delete")
                }
            }
            .buttonStyle(PanelPushButtonStyle(primary: false))
            .disabled(isDeleting)
            .accessibilityIdentifier(AccessibilityIDs.Cloud.deleteButton)
        }
    }
}

@MainActor
private final class CloudMeetingAudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0

    private var player: AVPlayer?
    private var currentURL: URL?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    func load(url: URL?) {
        guard currentURL != url else {
            refreshDuration()
            return
        }

        removeObservers()
        player?.pause()
        player = nil
        currentURL = url
        currentTime = 0
        duration = 0
        isPlaying = false

        guard let url else { return }

        let item = AVPlayerItem(url: url)
        let nextPlayer = AVPlayer(playerItem: item)
        player = nextPlayer
        refreshDuration()

        timeObserver = nextPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.18, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                self?.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                self?.refreshDuration()
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
            }
        }
    }

    func play() {
        guard let player else { return }
        player.play()
        isPlaying = true
        refreshDuration()
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
        player?.pause()
        player = nil
        currentURL = nil
        currentTime = 0
        duration = 0
        isPlaying = false
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, max(duration, seconds)))
        currentTime = clamped
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func pause() {
        player?.pause()
        isPlaying = false
    }

    private func refreshDuration() {
        let seconds = player?.currentItem?.duration.seconds ?? 0
        if seconds.isFinite, seconds > 0 {
            duration = seconds
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
                            .font(.system(size: 12, weight: .bold))
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
                        .font(.system(size: 11, weight: .semibold))
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

            Slider(
                value: Binding(
                    get: { min(max(0, currentTime), sliderUpperBound) },
                    set: { value in onSeek(value) }
                ),
                in: 0...sliderUpperBound
            )
            .tint(DT.waveformLit)
            .disabled(!hasAudio || isPreparingAudio)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.18))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.065), lineWidth: 1)
        )
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
                Text(row.marker)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isActive ? DT.waveformLit : Color.dtLabelTertiary)
                    .frame(width: 70, alignment: .leading)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    if let speaker = row.speaker {
                        Text(speaker)
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(DT.waveformLit)
                            .lineLimit(1)
                    }

                    Text(row.text)
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color.dtLabel)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isActive ? DT.waveformLit.opacity(0.12) : Color.white.opacity(0.032))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isActive ? DT.waveformLit.opacity(0.34) : Color.white.opacity(0.035), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(row.startMs == nil && row.endMs == nil ? "No timing for this segment" : "Jump audio to this segment")
        .disabled(row.startMs == nil && row.endMs == nil)
    }
}

private struct CloudMetadataPill: View {
    let iconName: String
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DT.waveformLit.opacity(0.85))
                .frame(width: 12)
            Text(value)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.dtLabelSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityLabel("\(title): \(value)")
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
    }
}

private struct CloudStatusChip: View {
    let status: CloudRecordingStatus
    var prominent: Bool = false

    var body: some View {
        Text(status.displayName)
            .font(.system(size: prominent ? 11 : 9, weight: .bold))
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
            return DT.waveformLit
        case .uploading:
            return DT.systemBlue
        case .failed, .aborted:
            return DT.systemOrange
        case .unknown:
            return Color.dtLabelTertiary
        }
    }
}

private struct CloudSourceIcon: View {
    let recording: CloudRecording
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(DT.waveformLit.opacity(0.14))

            if let icon = recording.sourceAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * 0.72, height: size * 0.72)
            } else {
                Image(systemName: recording.sourceIconName)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(DT.waveformLit)
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
        guard storageCapBytes > 0 else { return 0 }
        return Double(storageBytes) / Double(storageCapBytes)
    }

    var minutesProgress: Double {
        guard minutesCap > 0 else { return 0 }
        return minutesUsed / minutesCap
    }

    var isOverAnyLimit: Bool {
        isOverStorage || isOverMinutes
    }

    var storageUsageText: String {
        let used = ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file)
        let cap = ByteCountFormatter.string(fromByteCount: storageCapBytes, countStyle: .file)
        return "\(used) / \(cap)"
    }

    var minutesUsageText: String {
        "\(formattedMinutes(minutesUsed)) / \(formattedMinutes(minutesCap)) min"
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
