import AppKit
import SwiftUI

struct CloudCenterPanel: View {
    @StateObject private var store: CloudLibraryStore
    @StateObject private var cloudAudioPlayer = CloudMeetingAudioPlayer()
    @ObservedObject private var recorder: AudioRecorder
    @EnvironmentObject private var sessionStore: AuthSessionStore
    @EnvironmentObject private var appDelegate: AppDelegate
    @State private var showingDeleteConfirmation = false
    @State private var pendingListScrollTargetID: String?
    @State private var pendingProcessingAction: CloudRecordingProcessingAction?

    init(store: CloudLibraryStore = CloudLibraryStore(), recorder: AudioRecorder) {
        _store = StateObject(wrappedValue: store)
        _recorder = ObservedObject(wrappedValue: recorder)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("Recappi Cloud")
        .navigationSubtitle(headerSubtitle)
        .toolbar { toolbarContent }
        .containerBackground(DT.recordingShell, for: .window)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.window)
        .onDisappear {
            cloudAudioPlayer.close()
        }
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
            pendingProcessingAction?.confirmationTitle ?? "Process this recording?",
            isPresented: processingConfirmationBinding,
            titleVisibility: .visible
        ) {
            if let action = pendingProcessingAction {
                Button(action.confirmationButtonTitle) {
                    pendingProcessingAction = nil
                    Task { await store.processSelectedRecording(action) }
                }
                .accessibilityIdentifier(action.confirmAccessibilityIdentifier)
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingProcessingAction?.confirmationMessage ?? "")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            if isCurrentMeetingActive {
                Button {
                    appDelegate.setLiveCaptionPanelPresented(!appDelegate.isLiveCaptionPanelPresented)
                } label: {
                    Label(
                        appDelegate.isLiveCaptionPanelPresented ? "Hide Captions" : "Show Captions",
                        systemImage: appDelegate.isLiveCaptionPanelPresented ? "captions.bubble.fill" : "captions.bubble"
                    )
                }
                .help(appDelegate.isLiveCaptionPanelPresented ? "Hide live captions" : "Show live captions")
                .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaptionToggleButton)
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await store.refresh() }
            } label: {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(store.isRefreshing || sessionStore.isAuthBusy)
            .help("Refresh cloud recordings")
            .accessibilityIdentifier(AccessibilityIDs.Cloud.refreshButton)
        }
    }

    private var processingConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingProcessingAction != nil },
            set: { isPresented in
                if !isPresented {
                    pendingProcessingAction = nil
                }
            }
        )
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { store.selectedRecordingID },
            set: { newID in
                guard let id = newID,
                      let rec = store.recordings.first(where: { $0.id == id }) else { return }
                store.select(rec)
            }
        )
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollViewReader { proxy in
            List(selection: selectionBinding) {
                if shouldShowBillingSummary {
                    Section {
                        CloudSidebarBillingSummaryCompact(
                            status: store.billingStatus,
                            errorMessage: store.billingErrorMessage,
                            isLoading: store.billingStatus == nil && store.isLoadingBilling,
                            isOpeningBilling: store.isOpeningBilling,
                            onOpenBilling: { Task { await store.openBillingPortalOrPlans() } },
                            onOpenPlans: store.openPlansPage
                        )
                        .listRowInsets(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }

                ForEach(recordingDateSections) { section in
                    Section(section.title) {
                        ForEach(section.recordings) { recording in
                            CloudRecordingRow(
                                recording: recording,
                                latestJobStatus: store.transcriptionJobsByRecordingID[recording.id]?.first?.status,
                                isSelected: store.selectedRecordingID == recording.id,
                                isNowPlaying: cloudAudioPlayer.currentRecordingID == recording.id
                            )
                            .tag(recording.id)
                            .id(recording.id)
                            .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                            .listRowSeparator(.hidden)
                        }
                    }
                }

                if store.hasMorePages {
                    loadMoreSentinel
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
            .accessibilityIdentifier(AccessibilityIDs.Cloud.recordingsList)
            .onChange(of: pendingListScrollTargetID) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
                DispatchQueue.main.async {
                    pendingListScrollTargetID = nil
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sidebarBottomBar
            }
        }
    }

    @ViewBuilder
    private var sidebarBottomBar: some View {
        VStack(spacing: 8) {
            if let current = nowPlayingRecording,
               cloudAudioPlayer.currentRecordingID != store.selectedRecordingID {
                CloudNowPlayingMiniPane(
                    recording: current,
                    isPlaying: cloudAudioPlayer.isPlaying,
                    currentTime: cloudAudioPlayer.currentTime,
                    duration: cloudAudioPlayer.duration,
                    playbackRate: cloudAudioPlayer.playbackRate,
                    onPlayPause: cloudAudioPlayer.togglePlayback,
                    onSelectRate: cloudAudioPlayer.setPlaybackRate(_:),
                    onSelectRecording: { selectNowPlayingRecording(current) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier(AccessibilityIDs.Cloud.nowPlayingDock)
            }

            HStack {
                authStatusChip
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.thinMaterial)
        .overlay(alignment: .top) {
            Divider().opacity(0.6)
        }
    }

    // MARK: - Detail content

    @ViewBuilder
    private var detailContent: some View {
        switch store.state {
        case .idle, .loading:
            if isCurrentMeetingActive {
                detailPane
            } else {
                loadingView
            }
        case .signedOut:
            if isCurrentMeetingActive {
                detailPane
            } else {
                authRequiredView(
                    title: "Sign in to browse your cloud recordings",
                    detail: "Recappi Cloud keeps processed recordings, transcripts, and downloadable audio in one place."
                )
            }
        case .expired:
            if isCurrentMeetingActive {
                detailPane
            } else {
                authRequiredView(
                    title: "Reconnect Recappi Cloud",
                    detail: "Your session expired. Reconnect once and the library will refresh automatically."
                )
            }
        case .failed(let message):
            if isCurrentMeetingActive {
                detailPane
            } else {
                errorView(message)
            }
        case .empty:
            if isCurrentMeetingActive {
                detailPane
            } else {
                emptyView
            }
        case .loaded:
            detailPane
        }
    }

    private var isCurrentMeetingActive: Bool {
        switch recorder.state {
        case .starting, .recording:
            true
        default:
            false
        }
    }

    private var shouldShowBillingSummary: Bool {
        store.billingStatus != nil || store.isLoadingBilling || store.billingErrorMessage != nil
    }

    // MARK: - Detail pane

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
                audioPlayer: cloudAudioPlayer,
                isTranscriptLoading: store.isSelectedTranscriptLoading,
                isJobHistoryLoading: store.isSelectedJobHistoryLoading,
                isPreparingPlaybackAudio: store.isPreparingPlaybackAudio,
                isDownloading: store.isDownloading,
                isDeleting: store.isDeleting,
                isSyncingToLocal: store.isSyncingToLocal,
                processingAction: store.activeRecordingProcessingAction,
                hasDownloadedAudio: store.lastDownloadedAudioURL != nil,
                hasNewerVersion: store.hasNewerVersionForSelection,
                onLoadTranscript: { Task { await store.loadTranscriptForSelection() } },
                onCopyTranscript: store.copySelectedTranscript,
                onProcessRecording: { pendingProcessingAction = $0 },
                onPreparePlaybackAudio: { Task { await store.preparePlaybackAudioForSelection() } },
                onRevealLocalSession: store.revealSelectedLocalSession,
                onSyncToLocal: { Task { await store.syncSelectedRecordingToLocal() } },
                onDownloadAudio: { Task { await store.downloadSelectedAudio() } },
                onRevealAudio: store.revealLastDownloadedAudio,
                onDelete: { showingDeleteConfirmation = true },
                onAcknowledgeNewerVersion: { Task { await store.acknowledgeNewerVersion() } }
            )
            // Recording details own transient reading UI state: scroll
            // position, active jump chip, and pinned segment. Give each
            // selected recording a distinct identity so SwiftUI does not
            // recycle the previous detail page's scroll/focus state when the
            // sidebar selection changes. Playback lives one level up so
            // browsing another recording no longer tears down the audio.
            .id(recording.id)
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

    // MARK: - Now Playing helpers

    private var nowPlayingRecording: CloudRecording? {
        guard let id = cloudAudioPlayer.currentRecordingID else { return nil }
        return store.recordings.first(where: { $0.id == id })
    }

    private func selectNowPlayingRecording(_ recording: CloudRecording) {
        store.select(recording)
        pendingListScrollTargetID = recording.id
    }

    // MARK: - Section grouping

    private var recordingDateSections: [CloudRecordingDateSection] {
        var sections: [CloudRecordingDateSection] = []
        for recording in store.recordings {
            let bucket = recordingDateBucket(for: recording.createdAt)
            if sections.last?.id == bucket.id {
                sections[sections.count - 1].recordings.append(recording)
            } else {
                sections.append(
                    CloudRecordingDateSection(
                        id: bucket.id,
                        title: bucket.title,
                        recordings: [recording]
                    )
                )
            }
        }
        return sections
    }

    private func recordingDateBucket(for date: Date?) -> (id: String, title: String) {
        guard let date else {
            return ("unknown", "Unknown date")
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: Date())

        if startOfDay == today {
            return ("today", "Today")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), startOfDay == yesterday {
            return ("yesterday", "Yesterday")
        }

        let idFormatter = DateFormatter()
        idFormatter.calendar = calendar
        idFormatter.locale = .current
        idFormatter.dateFormat = "yyyy-MM-dd"

        let titleFormatter = DateFormatter()
        titleFormatter.calendar = calendar
        titleFormatter.locale = .current
        titleFormatter.dateStyle = .medium
        titleFormatter.timeStyle = .none

        return (idFormatter.string(from: startOfDay), titleFormatter.string(from: startOfDay))
    }

    private var loadMoreSentinel: some View {
        HStack {
            Spacer(minLength: 0)

            if store.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
                    .tint(DT.waveformLit)
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
            }

            Spacer(minLength: 0)
        }
        .frame(height: store.isLoadingMore ? 24 : 8)
        .padding(.top, 4)
        .task {
            guard store.hasMorePages, !store.isLoadingMore else { return }
            await store.loadMore()
        }
        .accessibilityIdentifier(AccessibilityIDs.Cloud.loadMoreButton)
    }

    // MARK: - Empty / error / loading / auth views

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
    private func authButtonLabel(for provider: OAuthProvider) -> some View {
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

    // MARK: - Auth chip (sidebar bottom)

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
                .truncationMode(.middle)
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

    // MARK: - Subtitle text

    private var headerSubtitle: String {
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

    private var recordingsCountText: String? {
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
}

extension CloudRecordingProcessingAction {
    var title: String {
        "Re-Transcribe"
    }

    var busyTitle: String {
        "Processing…"
    }

    var systemImage: String {
        "sparkles.rectangle.stack"
    }

    var helpText: String {
        "Run a fresh cloud transcription pass."
    }

    var confirmationTitle: String {
        "Re-transcribe this recording?"
    }

    var confirmationButtonTitle: String {
        "Re-Transcribe"
    }

    var confirmationMessage: String {
        "This starts a fresh cloud transcription job. Summary will be generated automatically when the transcript is ready."
    }

    var accessibilityIdentifier: String {
        AccessibilityIDs.Cloud.retranscribeButton
    }

    var confirmAccessibilityIdentifier: String {
        AccessibilityIDs.Cloud.confirmRetranscribeButton
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

extension TranscriptionJob {
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

extension BillingStatus {
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
