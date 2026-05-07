import AppKit
import SwiftUI

struct CloudCenterPanel: View {
    @StateObject private var store: CloudLibraryStore
    @StateObject private var cloudAudioPlayer = CloudMeetingAudioPlayer()
    @ObservedObject private var recorder: AudioRecorder
    @ObservedObject private var sessionStore = AuthSessionStore.shared
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

private struct CloudNowPlayingMiniPane: View {
    let recording: CloudRecording
    let isPlaying: Bool
    let currentTime: Double
    let duration: Double
    let playbackRate: Float
    let onPlayPause: () -> Void
    let onSelectRate: (Float) -> Void
    let onSelectRecording: () -> Void

    @State private var rateSelectionFeedbackID = 0

    private static let rateOptions: [Float] = [0.5, 1.0, 1.5, 2.0, 3.0]

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPlayPause) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(PanelIconButtonStyle(size: 24))
            .help(isPlaying ? "Pause" : "Play")

            Button(action: onSelectRecording) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(recording.presentationTitle)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Color.dtLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text("\(recording.sourceLine) · \(CloudMeetingPlaybackStrip.timeText(currentTime)) / \(duration > 0 ? CloudMeetingPlaybackStrip.timeText(duration) : "--:--")")
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.dtLabelTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .help("Show playing recording")

            playbackRateMenu
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(DT.waveformLit.opacity(0.18), lineWidth: 1)
        )
    }

    private var playbackRateMenu: some View {
        Menu {
            ForEach(Self.rateOptions, id: \.self) { rate in
                Button {
                    onSelectRate(rate)
                    rateSelectionFeedbackID += 1
                } label: {
                    if rate == playbackRate {
                        Label(Self.rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(Self.rateLabel(rate))
                    }
                }
            }
        } label: {
            PlaybackRatePillLabel(
                text: Self.rateLabel(playbackRate),
                isActive: playbackRate != 1.0,
                isEnabled: true,
                feedbackID: rateSelectionFeedbackID
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Playback speed")
    }

    private static func rateLabel(_ rate: Float) -> String {
        if rate == rate.rounded() {
            return "\(Int(rate))×"
        }
        return String(format: "%.1f×", rate)
    }
}

private extension CloudRecordingProcessingAction {
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

private struct CloudRecordingDetail: View {
    @StateObject private var detailWaveform = CloudRecordingWaveformPreview()
    @State private var pendingAutoplayAfterPrepare = false
    @State private var pendingSeekAfterPrepare: Double?
    @State private var pinnedSegmentID: String?
    @State private var pendingPinnedSegmentIDAfterPrepare: String?
    @State private var isShowingRecordingInfo = false
    @State private var pendingScrollTarget: CloudDetailSection?
    @State private var activeDetailSection: CloudDetailSection = .summary
    @State private var suppressOffsetDrivenSectionUpdates = false

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
    @ObservedObject var audioPlayer: CloudMeetingAudioPlayer
    let isTranscriptLoading: Bool
    let isJobHistoryLoading: Bool
    let isPreparingPlaybackAudio: Bool
    let isDownloading: Bool
    let isDeleting: Bool
    let isSyncingToLocal: Bool
    let processingAction: CloudRecordingProcessingAction?
    let hasDownloadedAudio: Bool
    let hasNewerVersion: Bool
    let onLoadTranscript: () -> Void
    let onCopyTranscript: () -> Void
    let onProcessRecording: (CloudRecordingProcessingAction) -> Void
    let onPreparePlaybackAudio: () -> Void
    let onRevealLocalSession: () -> Void
    let onSyncToLocal: () -> Void
    let onDownloadAudio: () -> Void
    let onRevealAudio: () -> Void
    let onDelete: () -> Void
    let onAcknowledgeNewerVersion: () -> Void

    var body: some View {
        readerPane
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            detailWaveform.load(url: playbackAudioURL)
            refreshPlayerMetadataIfNeeded()
        }
        .onChange(of: playbackAudioURL) { _, url in
            detailWaveform.load(url: url)
            if let pendingSeekAfterPrepare, url != nil {
                self.pendingSeekAfterPrepare = nil
                audioPlayer.load(
                    recordingID: recording.id,
                    url: url,
                    title: recording.presentationTitle,
                    artwork: recording.nowPlayingArtwork
                )
                audioPlayer.seek(to: pendingSeekAfterPrepare)
            }
            if let pendingPinnedSegmentIDAfterPrepare, url != nil {
                pinnedSegmentID = pendingPinnedSegmentIDAfterPrepare
                self.pendingPinnedSegmentIDAfterPrepare = nil
            }
            if pendingAutoplayAfterPrepare, url != nil {
                pendingAutoplayAfterPrepare = false
                audioPlayer.load(
                    recordingID: recording.id,
                    url: url,
                    title: recording.presentationTitle,
                    artwork: recording.nowPlayingArtwork
                )
                audioPlayer.play()
            }
            refreshPlayerMetadataIfNeeded()
        }
        .onChange(of: recording.id) { _, _ in
            pendingAutoplayAfterPrepare = false
            pendingSeekAfterPrepare = nil
            pendingPinnedSegmentIDAfterPrepare = nil
            pinnedSegmentID = nil
            refreshPlayerMetadataIfNeeded()
        }
    }

    private var readerPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            CloudDetailHeaderSection {
                detailHeader
            } latestJob: {
                latestJobStrip
            } newerVersion: {
                newerVersionStrip
            } navigation: {
                detailNavigationRow
            }

            Divider().overlay(Color.white.opacity(0.08))

            CloudDetailScrollableSections(
                hasSummarySection: hasSummarySection,
                activeSegmentID: activeSegmentID(in: transcript?.displaySegmentRows ?? []),
                isPlaybackActive: audioPlayer.isPlaying,
                pendingScrollTarget: $pendingScrollTarget,
                activeDetailSection: $activeDetailSection,
                onUpdateOffsets: updateActiveDetailSection(with:)
            ) {
                transcriptInsightStack
            } transcriptHeader: {
                segmentsHeader
            } transcriptCard: {
                transcriptCard
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Color.white.opacity(0.08))

            CloudDetailPlaybackSection {
                bottomPlaybackBar
            }
        }
    }

    private var hasSummarySection: Bool {
        structuredSummaryInsights != nil
            || summaryInsightText != nil
            || summaryStatusMessage != nil
            || shouldShowStandaloneActionItems
    }

    private var detailNavigationRow: some View {
        // Segmented-control nav. peng-xiao `430c2cf6` rejected both the
        // capsule-tag version ("looks like static metadata") and the
        // underline version ("looks like a webpage nav line, ugly").
        // Final design (Mini `32cfa104`): one rounded container holding
        // both options side-by-side, active segment filled, inactive
        // segment transparent. macOS-style segmented picker, compact
        // height, low ornament.
        HStack(alignment: .center, spacing: 10) {
            detailJumpBar

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Text(recording.createdDateText)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                CloudStatusChip(status: recording.status, latestJobStatus: latestJob?.status, prominent: true)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var detailJumpBar: some View {
        HStack(spacing: 2) {
            detailJumpSegment(
                title: "Summary",
                systemImage: "text.alignleft",
                section: .summary,
                accessibilityID: AccessibilityIDs.Cloud.jumpToSummaryButton,
                isDisabled: !hasSummarySection
            )

            detailJumpSegment(
                title: "Transcript",
                systemImage: "text.quote",
                section: .transcript,
                accessibilityID: AccessibilityIDs.Cloud.jumpToTranscriptButton,
                isDisabled: false
            )
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    private func detailJumpSegment(
        title: String,
        systemImage: String,
        section: CloudDetailSection,
        accessibilityID: String,
        isDisabled: Bool
    ) -> some View {
        let isActive = activeDetailSection == section
        return Button {
            pendingScrollTarget = section
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: isActive ? .semibold : .medium))
            }
            .foregroundStyle(isActive ? Color.dtLabel : Color.dtLabelSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isActive ? Color.white.opacity(0.13) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .accessibilityIdentifier(accessibilityID)
    }

    private func updateActiveDetailSection(with offsets: [CloudDetailSection: CGFloat]) {
        guard pendingScrollTarget == nil else { return }
        guard !suppressOffsetDrivenSectionUpdates else { return }
        if let transcriptOffset = offsets[.transcript], transcriptOffset < 88 {
            activeDetailSection = .transcript
        } else if hasSummarySection {
            activeDetailSection = .summary
        } else {
            activeDetailSection = .transcript
        }
    }

    private func acknowledgeNewerVersionWithoutSectionFlicker() {
        let sectionBeforeRefresh = activeDetailSection
        suppressOffsetDrivenSectionUpdates = true
        onAcknowledgeNewerVersion()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            activeDetailSection = sectionBeforeRefresh
            suppressOffsetDrivenSectionUpdates = false
        }
    }

    @ViewBuilder
    private var transcriptInsightStack: some View {
        if let structuredSummaryInsights {
            transcriptInsightCard(
                title: "Summary",
                systemImage: "text.alignleft",
                accessibilityID: AccessibilityIDs.Cloud.summaryText
            ) {
                structuredSummaryContent(structuredSummaryInsights)
            }
        } else if let summaryInsightText {
            transcriptInsightCard(
                title: "Summary",
                systemImage: "text.alignleft",
                accessibilityID: AccessibilityIDs.Cloud.summaryText
            ) {
                Text(summaryInsightText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let summaryStatusMessage {
            transcriptInsightCard(
                title: "Summary",
                systemImage: summaryStatusIconName,
                accessibilityID: AccessibilityIDs.Cloud.summaryText
            ) {
                Text(summaryStatusMessage)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        if shouldShowStandaloneActionItems {
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
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func structuredSummaryContent(_ insights: TranscriptSummaryInsights) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let tldr = insights.summaryText {
                summaryCalloutBlock(title: "TL;DR", text: tldr)
            }

            summaryBulletSection(title: "Key points", systemImage: "sparkles", items: insights.keyPoints, accent: DT.statusReady)
            summaryTopicSection(items: insights.topics)
            summaryBulletSection(title: "Decisions", systemImage: "checkmark.seal", items: insights.decisions, accent: DT.systemBlue)
            summaryBulletSection(title: "Action items", systemImage: "checklist", items: insights.actionItemTexts, accent: DT.systemOrange)
            summaryQuoteSection(items: insights.quoteTexts)
        }
    }

    @ViewBuilder
    private func summaryCalloutBlock(title: String, text: String) -> some View {
        summarySectionBlock(title: title, systemImage: "quote.opening", accent: DT.statusReady) {
            markdownText(text)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Color.dtLabel)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func summaryBulletSection(title: String, systemImage: String, items: [String], accent: Color) -> some View {
        if !items.isEmpty {
            summarySectionBlock(title: title, systemImage: systemImage, accent: accent) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(items.enumerated()), id: \.offset) { entry in
                        HStack(alignment: .top, spacing: 7) {
                            Circle()
                                .fill(accent.opacity(0.86))
                                .frame(width: 5, height: 5)
                                .padding(.top, 6.5)
                            markdownText(entry.element)
                                .font(.system(size: 12.5))
                                .foregroundStyle(Color.dtLabelSecondary)
                                .lineSpacing(1.5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func summaryTopicSection(items: [String]) -> some View {
        if !items.isEmpty {
            let topicAccent = DT.statusUploading
            summarySectionBlock(title: "Topics", systemImage: "tag", accent: topicAccent) {
                FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { entry in
                        summaryTopicChip(entry.element, accent: topicAccent)
                    }
                }
            }
        }
    }

    private func summaryTopicChip(_ text: String, accent: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.dtLabelSecondary)
            .lineLimit(nil)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(accent.opacity(0.07)))
            .overlay(Capsule(style: .continuous).strokeBorder(accent.opacity(0.10), lineWidth: 1))
    }

    @ViewBuilder
    private func summaryQuoteSection(items: [String]) -> some View {
        if !items.isEmpty {
            summarySectionBlock(title: "Notable quotes", systemImage: "quote.bubble", accent: Color.white.opacity(0.42)) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(items.enumerated()), id: \.offset) { entry in
                        markdownText(entry.element)
                            .font(.system(size: 12.5))
                            .italic()
                            .foregroundStyle(Color.dtLabelSecondary)
                            .lineSpacing(1.5)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 9)
                            .overlay(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 1, style: .continuous)
                                    .fill(Color.white.opacity(0.14))
                                    .frame(width: 2)
                            }
                    }
                }
            }
        }
    }

    private func summarySectionBlock<Content: View>(
        title: String,
        systemImage: String,
        accent: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 14)

                Text(title.uppercased())
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .tracking(0.9)
            }

            content()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(accent.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(accent.opacity(0.10), lineWidth: 1)
        )
    }

    private func markdownText(_ text: String) -> Text {
        if let attributed = try? AttributedString(markdown: text) {
            return Text(attributed)
        }
        return Text(text)
    }

    private func transcriptInsightCard<Content: View>(
        title: String,
        systemImage: String,
        trailingText: String? = nil,
        maxContentHeight: CGFloat? = nil,
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

            if let maxContentHeight {
                ScrollView {
                    content()
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: maxContentHeight)
            } else {
                content()
            }
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

    private var summaryStatusMessage: String? {
        guard structuredSummaryInsights == nil, summaryInsightText == nil else {
            return nil
        }
        switch transcript?.summaryStatus {
        case .pending:
            return "Summary generation has not started yet. It should begin automatically after transcription finishes."
        case .queued:
            return "Summary is queued and will appear here shortly."
        case .running:
            return "Summary is being generated. This usually takes a few moments."
        case .failed:
            return "Summary generation failed. Run Re-Transcribe again after the backend issue is fixed."
        case .skipped:
            return "Summary was skipped because this transcript is too short."
        case .succeeded, .none:
            return nil
        }
    }

    private var summaryStatusIconName: String {
        switch transcript?.summaryStatus {
        case .failed:
            return "exclamationmark.triangle"
        case .skipped:
            return "minus.circle"
        case .pending, .queued, .running:
            return "hourglass"
        case .succeeded, .none:
            return "text.alignleft"
        }
    }

    private var structuredSummaryInsights: TranscriptSummaryInsights? {
        guard let insights = transcript?.summaryInsights, !insights.isEmpty else {
            return nil
        }
        return insights
    }

    private var visibleActionItems: [String] {
        transcript?.actionItems?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        ?? []
    }

    private var shouldShowStandaloneActionItems: Bool {
        guard !visibleActionItems.isEmpty else { return false }
        guard let structuredSummaryInsights else { return true }
        return structuredSummaryInsights.actionItemTexts.isEmpty
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

            inspectorSection("AI Processing") {
                if let retranscriptionLimitMessage {
                    inspectorNotice(retranscriptionLimitMessage)
                } else if let transcriptErrorMessage {
                    inspectorNotice(transcriptErrorMessage)
                } else if let summaryStatusMessage {
                    inspectorNotice(summaryStatusMessage)
                }

                ForEach(CloudRecordingProcessingAction.allCases) { action in
                    processingButton(for: action)
                }
            }

            inspectorSection("Export") {
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

    private func processingButton(for action: CloudRecordingProcessingAction) -> some View {
        Button {
            onProcessRecording(action)
        } label: {
            inspectorButtonLabel(
                isBusy: processingAction == action,
                title: action.title,
                busyTitle: action.busyTitle,
                systemImage: action.systemImage
            )
        }
        .buttonStyle(
            CloudInspectorButtonStyle(
                tint: DT.statusReady,
                chrome: .always
            )
        )
        .disabled(isProcessingActionDisabled(action))
        .help(processingHelpText(for: action))
        .accessibilityIdentifier(action.accessibilityIdentifier)
    }

    private func isProcessingActionDisabled(_ action: CloudRecordingProcessingAction) -> Bool {
        if processingAction != nil || isTranscriptLoading {
            return true
        }
        return latestJob?.status.isActive == true
            || retranscriptionLimitMessage != nil
            || !recording.status.allowsTranscriptionRequest
    }

    private func processingHelpText(for action: CloudRecordingProcessingAction) -> String {
        if let retranscriptionLimitMessage {
            return retranscriptionLimitMessage
        }
        if processingAction != nil {
            return "A cloud processing action is already running."
        }
        if isTranscriptLoading {
            return "Transcript details are still loading."
        }
        if latestJob?.status.isActive == true {
            return "A transcription job is already in progress."
        }
        return action.helpText
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
        HStack(alignment: .center, spacing: 12) {
            CloudSourceIcon(recording: recording, size: 34)

            Text(recording.presentationTitle)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Color.dtLabel)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .frame(minWidth: 0)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                headerLocalActionButton

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

                Button {
                    isShowingRecordingInfo.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .buttonStyle(PanelIconButtonStyle(size: 28))
                .help(recordingInfoHelpText)
                .popover(isPresented: $isShowingRecordingInfo, arrowEdge: .top) {
                    recordingInfoPopover
                }
                .accessibilityLabel("Recording details")
                .accessibilityIdentifier(AccessibilityIDs.Cloud.recordingInfoButton)

                recordingActionsMenu
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var headerLocalActionButton: some View {
        Button {
            if localSessionURL == nil {
                onSyncToLocal()
            } else {
                onRevealLocalSession()
            }
        } label: {
            ZStack {
                Image(systemName: localSessionURL == nil ? "arrow.down.doc" : "folder")
                    .font(.system(size: 12.5, weight: .semibold))
                    .opacity(isSyncingToLocal ? 0 : 1)

                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.62)
                    .opacity(isSyncingToLocal ? 1 : 0)
            }
        }
        .buttonStyle(PanelIconButtonStyle(size: 28))
        .disabled(isSyncingToLocal)
        .help(localSessionURL == nil ? "Sync to local" : "Open local session")
        .accessibilityLabel(localSessionURL == nil ? "Sync to local" : "Open local session")
        .accessibilityIdentifier(localSessionURL == nil ? AccessibilityIDs.Cloud.syncToLocalButton : AccessibilityIDs.Cloud.revealLocalSessionButton)
    }

    private var recordingActionsMenu: some View {
        Menu {
            Button("Copy transcript", systemImage: "doc.on.doc", action: onCopyTranscript)
                .disabled(transcript?.text.isEmpty != false)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.copyTranscriptButton)

            Button(
                isDownloading ? "Downloading…" : (hasDownloadedAudio ? "Reveal audio" : "Download audio"),
                systemImage: hasDownloadedAudio ? "waveform.path.ecg.rectangle" : "arrow.down.circle",
                action: hasDownloadedAudio ? onRevealAudio : onDownloadAudio
            )
            .disabled(isDownloading)
            .accessibilityIdentifier(AccessibilityIDs.Cloud.downloadAudioButton)

            Button("About Recappi Mini", systemImage: "info.circle") {
                AppDelegate.shared.showAboutPanel()
            }

            Divider()

            ForEach(CloudRecordingProcessingAction.allCases) { action in
                Button(processingAction == action ? action.busyTitle : action.title, systemImage: action.systemImage) {
                    onProcessRecording(action)
                }
                .disabled(isProcessingActionDisabled(action))
                .help(processingHelpText(for: action))
                .accessibilityIdentifier(action.accessibilityIdentifier)
            }

            Divider()

            Button("Delete recording", systemImage: "trash", role: .destructive, action: onDelete)
                .disabled(isDeleting)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.deleteButton)
        } label: {
            MenuIconLabel(systemName: "ellipsis", size: 28)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 28, height: 28)
        .help("More actions")
        .accessibilityLabel("More actions")
        .accessibilityIdentifier(AccessibilityIDs.Cloud.moreActionsButton)
    }

    private var recordingInfoHelpText: String {
        [
            "Duration: \(recording.durationText ?? "Unknown")",
            "Size: \(recording.sizeText ?? "Unknown")",
            "Audio: \(recording.audioShapeCompactText)",
            "Format: \(recording.formatText)",
            "Source: \(recording.sourceLine)",
            "Created: \(recording.shortDateText)",
        ].joined(separator: "\n")
    }

    private var recordingInfoPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recording details")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.dtLabel)

            VStack(alignment: .leading, spacing: 8) {
                recordingInfoRow("Duration", recording.durationText ?? "Unknown", systemImage: "clock")
                recordingInfoRow("Size", recording.sizeText ?? "Unknown", systemImage: "internaldrive")
                recordingInfoRow("Audio", recording.audioShapeCompactText, systemImage: "waveform")
                recordingInfoRow("Format", recording.formatText, systemImage: "doc")
                recordingInfoRow("Source", recording.sourceLine, systemImage: recording.sourceIconName)
                recordingInfoRow("Created", recording.shortDateText, systemImage: "calendar")
                if let latestJob {
                    recordingInfoRow("Model", latestJob.providerModelText, systemImage: "cpu")
                }
            }

            if let localSessionURL {
                Divider().overlay(Color.white.opacity(0.08))

                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(DT.statusReady)
                        .frame(width: 14)
                    Text(localSessionURL.lastPathComponent)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.dtLabelSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(14)
        .frame(width: 270, alignment: .leading)
        .background(DT.recordingShell)
    }

    private func recordingInfoRow(_ title: String, _ value: String, systemImage: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.dtLabelTertiary)
                .frame(width: 14)

            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Color.dtLabelTertiary)
                .frame(width: 58, alignment: .leading)

            Text(value)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.dtLabelSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var newerVersionStrip: some View {
        if hasNewerVersion {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DT.systemBlue)
                    .frame(width: 13)

                Text("Newer version available")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.dtLabel)

                Text("Cloud has a newer transcript than the one you're viewing.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)

                Button(action: acknowledgeNewerVersionWithoutSectionFlicker) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("Refresh")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .foregroundStyle(DT.systemBlue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(DT.systemBlue.opacity(0.16))
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh to load newer cloud version")
                .accessibilityIdentifier(AccessibilityIDs.Cloud.newerVersionRefreshButton)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DT.systemBlue.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(DT.systemBlue.opacity(0.18), lineWidth: 1)
            )
            .accessibilityIdentifier(AccessibilityIDs.Cloud.newerVersionBanner)
        }
    }

    @ViewBuilder
    private var latestJobStrip: some View {
        if let latestJob {
            switch latestJob.status {
            case .succeeded:
                EmptyView()
            case .queued, .running, .failed:
                HStack(spacing: 8) {
                    Image(systemName: latestJob.status.detailIconName)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(latestJob.status.detailColor)
                        .frame(width: 13)

                    Text("Transcription")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.dtLabelSecondary)

                    CloudJobStatusChip(status: latestJob.status, compact: true)

                    if latestJob.status.isActive || isJobHistoryLoading {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.58)
                            .tint(latestJob.status.detailColor)
                    }

                    if let error = latestJob.trimmedError, latestJob.status == .failed {
                        Text(error)
                            .font(.system(size: 10.5))
                            .foregroundStyle(DT.systemOrange)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(latestJob.status.detailColor.opacity(latestJob.status == .failed ? 0.10 : 0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(latestJob.status.detailColor.opacity(latestJob.status == .failed ? 0.20 : 0.12), lineWidth: 1)
                )
                .accessibilityIdentifier(AccessibilityIDs.Cloud.latestJobStatus)
            }
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

    private var bottomPlaybackBar: some View {
        let isViewingLoadedAudio = audioPlayer.currentRecordingID == recording.id
        let displayDuration = isViewingLoadedAudio ? audioPlayer.duration : (recording.durationSeconds ?? 0)
        return CloudMeetingPlaybackStrip(
            isPlaying: isViewingLoadedAudio && audioPlayer.isPlaying,
            currentTime: isViewingLoadedAudio ? audioPlayer.currentTime : 0,
            duration: displayDuration,
            sourceDescription: playbackSourceDescription,
            errorMessage: playbackErrorMessage,
            isPreparingAudio: isPreparingPlaybackAudio,
            hasAudio: playbackAudioURL != nil,
            isViewingLoadedAudio: true,
            hasLocalSession: localSessionURL != nil,
            waveformPeaks: isViewingLoadedAudio ? audioPlayer.waveformPeaks : detailWaveform.waveformPeaks,
            isLoadingWaveform: isViewingLoadedAudio ? audioPlayer.isLoadingWaveform : detailWaveform.isLoadingWaveform,
            playbackRate: audioPlayer.playbackRate,
            onPlayPause: handlePlayPause,
            onSeek: handlePlaybackSeek(_:),
            onSelectRate: audioPlayer.setPlaybackRate(_:)
        )
    }

    private func handlePlayPause() {
        guard let playbackAudioURL else {
            pendingAutoplayAfterPrepare = true
            onPreparePlaybackAudio()
            return
        }

        if audioPlayer.currentRecordingID == recording.id,
           audioPlayer.currentURL == playbackAudioURL {
            audioPlayer.togglePlayback()
            return
        }

        audioPlayer.load(
            recordingID: recording.id,
            url: playbackAudioURL,
            title: recording.presentationTitle,
            artwork: recording.nowPlayingArtwork
        )
        audioPlayer.togglePlayback()
    }

    private func handlePlaybackSeek(_ seconds: Double) {
        guard let playbackAudioURL else {
            pendingSeekAfterPrepare = seconds
            onPreparePlaybackAudio()
            return
        }
        audioPlayer.load(
            recordingID: recording.id,
            url: playbackAudioURL,
            title: recording.presentationTitle,
            artwork: recording.nowPlayingArtwork
        )
        audioPlayer.seek(to: seconds)
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
        handlePlaybackSeek(seconds)
    }

    private func refreshPlayerMetadataIfNeeded() {
        guard audioPlayer.currentRecordingID == recording.id else { return }
        let resolvedURL = playbackAudioURL ?? audioPlayer.currentURL
        audioPlayer.load(
            recordingID: recording.id,
            url: resolvedURL,
            title: recording.presentationTitle,
            artwork: recording.nowPlayingArtwork
        )
    }

    private func computeSegmentRowsWithPerfLogging() -> [CloudTranscriptSegmentDisplayRow] {
        let segmentCount = transcript?.segments.count ?? 0
        let rows = PerfLog.measure("displaySegmentRows", extra: "segments=\(segmentCount)") {
            transcript?.displaySegmentRows ?? []
        }
        PerfLog.event("transcriptCard.render", extra: "rows=\(rows.count)")
        PerfLog.end("select.until.firstRender", extra: "rows=\(rows.count)")
        return rows
    }

    @ViewBuilder
    private var transcriptCard: some View {
        let segmentRows = computeSegmentRowsWithPerfLogging()
        let activeSegmentID = activeSegmentID(in: segmentRows)
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(segmentRows.isEmpty ? 0.18 : 0.24))

            if !segmentRows.isEmpty {
                // `LazyVStack` (vs `VStack`): only the segments inside the
                // viewport are laid out. For long recordings (~150-500 rows)
                // this drops per-render layout work by an order of magnitude
                // and is the main fix for the perceived lag when switching
                // between recordings — the eager `VStack` was re-laying out
                // every row each time SwiftUI re-evaluated this view.
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
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.transcriptText)
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
        .frame(minHeight: 240)
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

private struct CloudDetailHeaderSection<Header: View, LatestJob: View, NewerVersion: View, Navigation: View>: View {
    private let header: Header
    private let latestJob: LatestJob
    private let newerVersion: NewerVersion
    private let navigation: Navigation

    init(
        @ViewBuilder header: () -> Header,
        @ViewBuilder latestJob: () -> LatestJob,
        @ViewBuilder newerVersion: () -> NewerVersion,
        @ViewBuilder navigation: () -> Navigation
    ) {
        self.header = header()
        self.latestJob = latestJob()
        self.newerVersion = newerVersion()
        self.navigation = navigation()
    }

    var body: some View {
        // peng-xiao `04644a8a` flagged the detail pane top whitespace
        // as wasteful. Keep the condensed header chrome centralized so
        // CloudRecordingDetail can compose sections without owning the
        // padding/spacing trivia inline.
        VStack(alignment: .leading, spacing: 9) {
            header
            // Failed/processing transcription banner (orange) sits above
            // the newer-version banner (blue) so terminal errors stay
            // closer to the header than informational refresh prompts.
            latestJob
            newerVersion
            navigation
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
}

private struct CloudDetailScrollableSections<Summary: View, TranscriptHeader: View, TranscriptCard: View>: View {
    let hasSummarySection: Bool
    let activeSegmentID: String?
    let isPlaybackActive: Bool
    @Binding var pendingScrollTarget: CloudDetailSection?
    @Binding var activeDetailSection: CloudDetailSection
    let onUpdateOffsets: ([CloudDetailSection: CGFloat]) -> Void

    private let summary: Summary
    private let transcriptHeader: TranscriptHeader
    private let transcriptCard: TranscriptCard

    init(
        hasSummarySection: Bool,
        activeSegmentID: String?,
        isPlaybackActive: Bool,
        pendingScrollTarget: Binding<CloudDetailSection?>,
        activeDetailSection: Binding<CloudDetailSection>,
        onUpdateOffsets: @escaping ([CloudDetailSection: CGFloat]) -> Void,
        @ViewBuilder summary: () -> Summary,
        @ViewBuilder transcriptHeader: () -> TranscriptHeader,
        @ViewBuilder transcriptCard: () -> TranscriptCard
    ) {
        self.hasSummarySection = hasSummarySection
        self.activeSegmentID = activeSegmentID
        self.isPlaybackActive = isPlaybackActive
        self._pendingScrollTarget = pendingScrollTarget
        self._activeDetailSection = activeDetailSection
        self.onUpdateOffsets = onUpdateOffsets
        self.summary = summary()
        self.transcriptHeader = transcriptHeader()
        self.transcriptCard = transcriptCard()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    CloudDetailSummarySection(
                        isVisible: hasSummarySection,
                        offsetReader: { sectionOffsetReader(.summary) }
                    ) {
                        summary
                    }

                    CloudDetailTranscriptSection(
                        offsetReader: { sectionOffsetReader(.transcript) },
                        header: { transcriptHeader },
                        card: { transcriptCard }
                    )
                }
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .coordinateSpace(name: "cloudDetailScroll")
            .onChange(of: activeSegmentID) { _, id in
                // Loading or switching recordings can make the active
                // segment move from nil to the first row before the user
                // has interacted with playback. Do not let that derived
                // state yank the detail scroll away from the top; only
                // auto-follow transcript rows while playback is advancing.
                guard isPlaybackActive, let id else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: pendingScrollTarget) { _, target in
                guard let target else { return }
                activeDetailSection = target
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(target, anchor: .top)
                }
                // Hold `pendingScrollTarget` past the scroll animation
                // duration so offset-driven updates cannot retoggle the
                // segmented control mid-flight.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    pendingScrollTarget = nil
                }
            }
            .onPreferenceChange(CloudDetailSectionOffsetPreferenceKey.self) { offsets in
                onUpdateOffsets(offsets)
            }
        }
    }

    private func sectionOffsetReader(_ section: CloudDetailSection) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: CloudDetailSectionOffsetPreferenceKey.self,
                value: [section: proxy.frame(in: .named("cloudDetailScroll")).minY]
            )
        }
    }
}

private struct CloudDetailSummarySection<Content: View, OffsetReader: View>: View {
    let isVisible: Bool
    private let offsetReader: OffsetReader
    private let content: Content

    init(
        isVisible: Bool,
        @ViewBuilder offsetReader: () -> OffsetReader,
        @ViewBuilder content: () -> Content
    ) {
        self.isVisible = isVisible
        self.offsetReader = offsetReader()
        self.content = content()
    }

    var body: some View {
        if isVisible {
            content
                .id(CloudDetailSection.summary)
                .background(offsetReader)
        }
    }
}

private struct CloudDetailTranscriptSection<OffsetReader: View, Header: View, Card: View>: View {
    private let offsetReader: OffsetReader
    private let header: Header
    private let card: Card

    init(
        @ViewBuilder offsetReader: () -> OffsetReader,
        @ViewBuilder header: () -> Header,
        @ViewBuilder card: () -> Card
    ) {
        self.offsetReader = offsetReader()
        self.header = header()
        self.card = card()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            card
        }
        .id(CloudDetailSection.transcript)
        .background(offsetReader)
    }
}

private struct CloudDetailPlaybackSection<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
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
                    .fill(isActive ? DT.waveformLit.opacity(0.9) : Color.white.opacity(0.055))
                    .frame(width: isActive ? 2 : 3)
                    .padding(.vertical, 2)

                Text(row.marker)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isActive ? Color.dtLabelSecondary : Color.dtLabelTertiary)
                    .frame(width: 64, alignment: .leading)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    if let speaker = row.speaker {
                        Text(speaker)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.dtLabelSecondary)
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
                    .fill(isActive ? Color.white.opacity(0.035) : Color.white.opacity(0.012))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isActive ? Color.white.opacity(0.05) : Color.white.opacity(0.018), lineWidth: 1)
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
