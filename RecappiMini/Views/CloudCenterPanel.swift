import AppKit
import SwiftUI

struct CloudCenterPanel: View {
    @StateObject private var store: CloudLibraryStore
    @StateObject private var cloudAudioPlayer = CloudMeetingAudioPlayer()
    @ObservedObject private var recorder: AudioRecorder
    @EnvironmentObject private var sessionStore: AuthSessionStore
    @ObservedObject private var appDelegate = AppDelegate.shared
    @State private var showingDeleteConfirmation = false
    @State private var pendingListScrollTargetID: String?
    @State private var pendingProcessingAction: CloudRecordingProcessingAction?

    init(store: CloudLibraryStore = CloudLibraryStore(), recorder: AudioRecorder) {
        _store = StateObject(wrappedValue: store)
        _recorder = ObservedObject(wrappedValue: recorder)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.white.opacity(0.08))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 1160, height: 760)
        // Break out of the vertical safe areas so the custom chrome and
        // docked mini-player sit on the real window edges instead of
        // being pushed inward by the hidden native title bar / content
        // layout reserve.
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .background(DT.recordingShell)
        .preferredColorScheme(.dark)
        .onDisappear {
            cloudAudioPlayer.close()
        }
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
        HStack(spacing: 10) {
            LogoTile(size: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text("Recappi Cloud")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.dtLabel)
                Text(headerSubtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 24)

            if shouldShowBillingSummary {
                billingSummary
                    .frame(width: 520, height: 34)
            }

            if isCurrentMeetingActive {
                Button {
                    appDelegate.setLiveCaptionPanelPresented(!appDelegate.isLiveCaptionPanelPresented)
                } label: {
                    Image(systemName: appDelegate.isLiveCaptionPanelPresented ? "captions.bubble.fill" : "captions.bubble")
                }
                .buttonStyle(PanelIconButtonStyle())
                .help(appDelegate.isLiveCaptionPanelPresented ? "Hide live captions" : "Show live captions")
                .accessibilityLabel(appDelegate.isLiveCaptionPanelPresented ? "Hide live captions" : "Show live captions")
                .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaptionToggleButton)
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

            // The Cloud window hides the macOS traffic-light controls
            // so the SwiftUI header can render flush to the leading
            // edge — surface an in-panel close affordance here so the
            // user keeps an obvious "dismiss" action.
            Button {
                cloudHostWindow?.performClose(nil)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(PanelIconButtonStyle())
            .help("Close Cloud")
            .accessibilityIdentifier(AccessibilityIDs.Cloud.closeWindowButton)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(height: 48)
        .background {
            // `WindowDragHandle` sits behind the visible header chrome
            // and turns every empty pixel into a window-move target,
            // restoring the affordance that the native title bar used
            // to provide. The translucent visual chrome is pushed into
            // an `.allowsHitTesting(false)` overlay so SwiftUI's hit
            // testing falls through to the underlying `NSView`.
            WindowDragHandle()
                .overlay {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .overlay(
                            LinearGradient(
                                colors: [Color.white.opacity(0.055), Color.white.opacity(0.018)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .allowsHitTesting(false)
                }
        }
        .accessibilityElement(children: .contain)
    }

    /// Resolve the host `NSWindow` lazily. The panel does not get a
    /// reference to its window at construction time, but `NSApp` keeps
    /// the list of open windows and `RecappiMiniApp.showCloudCenter`
    /// stamps `"Recappi Cloud"` on the window title. Falling back to
    /// the key window covers cases where the title is briefly empty
    /// during transitions.
    private var cloudHostWindow: NSWindow? {
        if let titled = NSApp.windows.first(where: { $0.title == "Recappi Cloud" }) {
            return titled
        }
        return NSApp.keyWindow
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case .idle, .loading:
            if isCurrentMeetingActive {
                libraryView
            } else {
                loadingView
            }
        case .signedOut:
            if isCurrentMeetingActive {
                libraryView
            } else {
                authRequiredView(
                    title: "Sign in to browse your cloud recordings",
                    detail: "Recappi Cloud keeps processed recordings, transcripts, and downloadable audio in one place."
                )
            }
        case .expired:
            if isCurrentMeetingActive {
                libraryView
            } else {
                authRequiredView(
                    title: "Reconnect Recappi Cloud",
                    detail: "Your session expired. Reconnect once and the library will refresh automatically."
                )
            }
        case .failed(let message):
            if isCurrentMeetingActive {
                libraryView
            } else {
                errorView(message)
            }
        case .empty:
            if isCurrentMeetingActive {
                libraryView
            } else {
                emptyView
            }
        case .loaded:
            libraryView
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
            // Header row sits at the same horizontal inset as the
            // LazyVStack below (10pt — see `.padding(.horizontal, 10)` on
            // the scroll content), so "Recordings" and the per-day section
            // headers ("Apr 30, 2026", etc.) share a clean leading rail.
            // peng-xiao `26485a7a` flagged the previous 14pt header inset
            // as visibly out of column with the date headers below it.
            HStack {
                Text("Recordings")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .tracking(0.45)
                Spacer(minLength: 0)
                Text(recordingsCountText)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dtLabelTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.top, 14)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if isCurrentMeetingActive {
                            CurrentMeetingSidebarRow(
                                recorder: recorder,
                                isCaptionPanelVisible: appDelegate.isLiveCaptionPanelPresented,
                                onToggleCaptions: {
                                    appDelegate.setLiveCaptionPanelPresented(!appDelegate.isLiveCaptionPanelPresented)
                                }
                            )
                                .id(AccessibilityIDs.Cloud.currentMeetingRow)
                        }

                        ForEach(recordingDateSections) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                CloudRecordingDateSectionHeader(
                                    title: section.title,
                                    count: section.recordings.count
                                )

                                ForEach(section.recordings) { recording in
                                    CloudRecordingRow(
                                        recording: recording,
                                        latestJobStatus: store.transcriptionJobsByRecordingID[recording.id]?.first?.status,
                                        isSelected: store.selectedRecordingID == recording.id,
                                        isNowPlaying: cloudAudioPlayer.currentRecordingID == recording.id
                                    ) {
                                        store.select(recording)
                                    }
                                    .id(recording.id)
                                }
                            }
                        }

                        if store.hasMorePages {
                            loadMoreSentinel
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 14)
                }
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
            }

            nowPlayingMiniPane
        }
        .background(Color.black.opacity(0.12))
    }

    @ViewBuilder
    private var nowPlayingMiniPane: some View {
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
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier(AccessibilityIDs.Cloud.nowPlayingDock)
        }
    }

    private var nowPlayingRecording: CloudRecording? {
        guard let id = cloudAudioPlayer.currentRecordingID else { return nil }
        return store.recordings.first(where: { $0.id == id })
    }

    private func selectNowPlayingRecording(_ recording: CloudRecording) {
        store.select(recording)
        pendingListScrollTargetID = recording.id
    }

    private var recordingsCountText: String {
        if let total = store.totalRecordingCount {
            return total == 1 ? "1 total" : "\(total) total"
        }
        if store.hasMorePages {
            return "\(store.recordings.count)+ loaded"
        }
        let count = store.recordings.count
        return count == 1 ? "1 total" : "\(count) total"
    }

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
        .onAppear {
            guard store.hasMorePages, !store.isLoadingMore else { return }
            Task { await store.loadMore() }
        }
        .accessibilityIdentifier(AccessibilityIDs.Cloud.loadMoreButton)
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
            // Brand `LogoTile` instead of a generic SF Symbol so the
            // sign-in surface looks like Recappi rather than a stock
            // contact-empty placeholder. Folds task #32's "central icon
            // should match brand" requirement.
            LogoTile(size: 56)
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Color.dtLabel)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Color.dtLabelSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            // Both sign-in buttons share the neutral panel-push style so
            // the surface looks like one OAuth picker rather than a green
            // "primary" Google CTA next to a grey GitHub fallback. The
            // brand identity comes from the leading provider mark, not
            // from the button background. Fixed width keeps the loading
            // label ("Opening browser…") from squeezing the spinner off
            // the button.
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
            // Mirror `OnboardingView.onboardingAuthLabel` — a shrunken
            // spinner plus an explicitly truncating label so a long
            // phase string ("Continue in browser…") does not push the
            // spinner off the fixed-width button or chop the text in
            // half mid-glyph.
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
            // Pair the brand mark with the text label so the Cloud
            // empty-state sign-in surface matches Onboarding's SignIn
            // step and the Settings Account row (folds the remaining
            // half of #32 — Cloud was the only OAuth surface still
            // shipping a text-only button after v1.0.41).
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
