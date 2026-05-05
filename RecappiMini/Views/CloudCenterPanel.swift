import AppKit
import AVFoundation
@preconcurrency import MediaPlayer
import SwiftUI

struct CloudCenterPanel: View {
    @StateObject private var store: CloudLibraryStore
    @StateObject private var cloudAudioPlayer = CloudMeetingAudioPlayer()
    @ObservedObject private var sessionStore = AuthSessionStore.shared
    @State private var showingDeleteConfirmation = false
    @State private var pendingListScrollTargetID: String?
    @State private var pendingProcessingAction: CloudRecordingProcessingAction?

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

private struct FlowLayout: Layout {
    var horizontalSpacing: CGFloat = 8
    var verticalSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? subviews.reduce(CGFloat.zero) { width, subview in
            width + subview.sizeThatFits(.unspecified).width
        }
        let layout = computeLayout(in: max(maxWidth, 1), subviews: subviews)
        return CGSize(width: maxWidth, height: layout.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = computeLayout(in: max(bounds.width, 1), subviews: subviews)
        for item in layout.items {
            subviews[item.index].place(
                at: CGPoint(x: bounds.minX + item.origin.x, y: bounds.minY + item.origin.y),
                proposal: ProposedViewSize(item.size)
            )
        }
    }

    private func computeLayout(in maxWidth: CGFloat, subviews: Subviews) -> (items: [LayoutItem], height: CGFloat) {
        var items: [LayoutItem] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }

            items.append(LayoutItem(index: index, origin: CGPoint(x: x, y: y), size: size))
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }

        return (items, subviews.isEmpty ? 0 : y + rowHeight)
    }

    private struct LayoutItem {
        let index: Int
        let origin: CGPoint
        let size: CGSize
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

/// Empty `NSView` whose only purpose is to opt into AppKit's
/// "click-and-drag the background to move the window" behaviour. We
/// drop one of these behind the Cloud header so the user can grab any
/// non-interactive pixel of our SwiftUI chrome and reposition the
/// window — replacing the affordance the native title bar used to
/// provide before we hid the traffic lights.
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DraggableView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DraggableView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }
}

private struct CloudRecordingDateSection: Identifiable {
    let id: String
    let title: String
    var recordings: [CloudRecording]
}

private struct CloudRecordingDateSectionHeader: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.dtLabelTertiary)
                .tracking(0.32)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.dtLabelQuaternary)
        }
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(count) recordings")
    }
}

private struct CloudRecordingRow: View {
    let recording: CloudRecording
    let latestJobStatus: RemoteJobStatus?
    let isSelected: Bool
    let isNowPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 10) {
                // Source icon column. peng-xiao `26485a7a` asked the icon
                // to "just be bigger" rather than padded inside a smaller
                // visual box, and to vertically anchor the row (not float
                // beside the title). 24pt → 30pt + center alignment puts
                // the icon between the two metadata rows so it visually
                // covers the full row height; the previous `.top` align
                // + `.padding(.top, 1)` decorative offset is no longer
                // needed.
                CloudSourceIcon(recording: recording, size: 30)

                VStack(alignment: .leading, spacing: 4) {
                    // Row 1: title + status chip. Title is the primary
                    // affordance, chip sits trailing as the status read.
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if isNowPlaying {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(DT.waveformLit)
                                .frame(width: 12)
                                .accessibilityLabel("Now playing")
                        }

                        Text(recording.presentationTitle)
                            .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                            .foregroundStyle(Color.dtLabel)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 0)

                        CloudStatusChip(status: recording.status, latestJobStatus: latestJobStatus)
                    }

                    // Row 2: single metadata bar — `source · time · duration`.
                    // Originally rendered as three separate stacked rows
                    // (subtitle, then a clock/timer icon row), which left a
                    // large empty area below the source icon and made the
                    // bottom-left timestamp feel "空落落" — peng-xiao
                    // `41a1772f`. Mini `d3bedf7f` / `d24fadec` reviewed and
                    // proposed the consolidated bar: same reading rhythm,
                    // no left/right spacer split, no decorative SF Symbols.
                    // Cell height drops from ~3 metadata rows to 1, so the
                    // 24pt source icon now visually covers the row's full
                    // left column without the suspended-anchor problem.
                    HStack(spacing: 6) {
                        Text(recording.sourceLine)
                        Text("·")
                            .foregroundStyle(Color.dtLabelQuaternary)
                        Text(recording.listTimeText)
                        if let duration = recording.durationText {
                            Text("·")
                                .foregroundStyle(Color.dtLabelQuaternary)
                            Text(duration)
                        }
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
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

private enum CloudDetailSection: Hashable {
    case summary
    case transcript
}

private extension CloudRecordingProcessingAction {
    var title: String {
        "Transcribe + summarize…"
    }

    var busyTitle: String {
        "Processing…"
    }

    var systemImage: String {
        "sparkles.rectangle.stack"
    }

    var helpText: String {
        "Run a fresh transcription and summary pass."
    }

    var confirmationTitle: String {
        "Transcribe and summarize this recording?"
    }

    var confirmationButtonTitle: String {
        "Transcribe + Summarize"
    }

    var confirmationMessage: String {
        "This starts a fresh cloud transcription job. The backend will enqueue summary generation after the transcript succeeds."
    }

    var accessibilityIdentifier: String {
        AccessibilityIDs.Cloud.retranscribeButton
    }

    var confirmAccessibilityIdentifier: String {
        AccessibilityIDs.Cloud.confirmRetranscribeButton
    }
}

private struct CloudDetailSectionOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: [CloudDetailSection: CGFloat] { [:] }

    static func reduce(value: inout [CloudDetailSection: CGFloat], nextValue: () -> [CloudDetailSection: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
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
            // peng-xiao `04644a8a` flagged the detail pane top whitespace
            // as wasteful — title block + tab bar were leaving more
            // breathing room than the page below them justified. Pulled
            // top inset 20→14, bottom inset 13→8, and the inner VStack
            // spacing 13→9 so the title/date/banners/tabs feel like a
            // single condensed header strip, not a wide spaced collage.
            // The detailHeader's own internal title↔date spacing tightens
            // separately (5→3) inside the header body.
            VStack(alignment: .leading, spacing: 9) {
                detailHeader
                // Failed/processing transcription banner (orange) sits above the
                // newer-version banner (blue) so terminal errors stay closer to
                // the header than informational refresh prompts.
                latestJobStrip
                newerVersionStrip
                detailJumpBar
            }
            .padding(.horizontal, 22)
            .padding(.top, 14)
            .padding(.bottom, 8)

            Divider().overlay(Color.white.opacity(0.08))

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if hasSummarySection {
                            transcriptInsightStack
                                .id(CloudDetailSection.summary)
                                .background(sectionOffsetReader(.summary))
                        }

                        VStack(alignment: .leading, spacing: 12) {
                            segmentsHeader
                            transcriptCard
                        }
                        .id(CloudDetailSection.transcript)
                        .background(sectionOffsetReader(.transcript))
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 16)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .coordinateSpace(name: "cloudDetailScroll")
                .onChange(of: activeSegmentID(in: transcript?.displaySegmentRows ?? [])) { _, id in
                    // Loading or switching recordings can make the active
                    // segment move from nil to the first row before the user
                    // has interacted with playback. Do not let that derived
                    // state yank the detail scroll away from the top; only
                    // auto-follow transcript rows while playback is actually
                    // advancing.
                    guard audioPlayer.isPlaying, let id else { return }
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
                    // Hold `pendingScrollTarget` past the scroll
                    // animation duration so the offset-driven
                    // `updateActiveDetailSection` cannot retoggle the
                    // active segment while the scroll is still in
                    // flight. peng-xiao `349a3fb1`: tapping Summary /
                    // Transcript made the segmented control flicker
                    // because the previous `DispatchQueue.main.async`
                    // cleared the gate immediately, so mid-animation
                    // preference-key updates would briefly flip the
                    // segment back to whichever section was currently
                    // sliding through the 88pt threshold. The 0.25s
                    // delay (animation 0.18s + ~70ms slack) lets the
                    // intent-driven activeDetailSection settle before
                    // scroll position takes over again.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        pendingScrollTarget = nil
                    }
                }
                .onPreferenceChange(CloudDetailSectionOffsetPreferenceKey.self) { offsets in
                    updateActiveDetailSection(with: offsets)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(Color.white.opacity(0.08))

            bottomPlaybackBar
        }
    }

    private var hasSummarySection: Bool {
        structuredSummaryInsights != nil || summaryInsightText != nil || shouldShowStandaloneActionItems
    }

    private var detailJumpBar: some View {
        // Segmented-control nav. peng-xiao `430c2cf6` rejected both the
        // capsule-tag version ("looks like static metadata") and the
        // underline version ("looks like a webpage nav line, ugly").
        // Final design (Mini `32cfa104`): one rounded container holding
        // both options side-by-side, active segment filled, inactive
        // segment transparent. macOS-style segmented picker, compact
        // height, low ornament.
        HStack(spacing: 0) {
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

            Spacer(minLength: 0)
        }
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

    private func sectionOffsetReader(_ section: CloudDetailSection) -> some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: CloudDetailSectionOffsetPreferenceKey.self,
                value: [section: proxy.frame(in: .named("cloudDetailScroll")).minY]
            )
        }
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
        // Identity strip: icon + `Title · date` inline as a single
        // horizontal row. peng-xiao `825bd872` / `684bb091` flagged the
        // previous "icon left, title-stacked-over-date middle, actions
        // right" arrangement as structurally loose — title and date were
        // stacked vertically while the actions sat on a different
        // visual axis, so the header read as three separate visual
        // groups. Mini `46e7aacf` proposed collapsing identity into one
        // strip; this version puts title (19pt) and date (11.5pt) on
        // one baseline-aligned line with a `·` separator, then sends
        // status + actions to the trailing edge of the same strip.
        HStack(alignment: .center, spacing: 12) {
            CloudSourceIcon(recording: recording, size: 34)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(recording.presentationTitle)
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color.dtLabel)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("·")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.dtLabelQuaternary)

                Text(recording.createdDateText)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)
            .frame(minWidth: 0)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                CloudStatusChip(status: recording.status, latestJobStatus: latestJob?.status, prominent: true)

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

@MainActor
private final class CloudRecordingWaveformPreview: ObservableObject {
    @Published private(set) var waveformPeaks: [Float] = []
    @Published private(set) var isLoadingWaveform = false

    private var currentURL: URL?
    private var waveformTask: Task<Void, Never>?
    private var waveformCache: [URL: [Float]] = [:]

    deinit {
        waveformTask?.cancel()
    }

    func load(url: URL?) {
        guard currentURL != url else { return }
        waveformTask?.cancel()
        currentURL = url
        waveformPeaks = []
        isLoadingWaveform = false

        guard let url else { return }
        if let cached = waveformCache[url] {
            waveformPeaks = cached
            return
        }

        isLoadingWaveform = true
        waveformTask = Task { [url] in
            let peaks = await Task.detached(priority: .utility) {
                (try? PlaybackWaveformExtractor.cachedPeaks(from: url)) ?? []
            }.value
            guard !Task.isCancelled, self.currentURL == url else { return }
            self.waveformCache[url] = peaks
            self.waveformPeaks = peaks
            self.isLoadingWaveform = false
        }
    }
}

@MainActor
private final class CloudMeetingAudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var waveformPeaks: [Float] = []
    @Published private(set) var isLoadingWaveform = false
    @Published private(set) var currentRecordingID: String?
    @Published private(set) var currentURL: URL?
    @Published private(set) var currentTitle = "Meeting playback"
    /// User-selected playback rate. Applied to `AVPlayer.rate` while
    /// playing; remembered across pause/play cycles so toggling
    /// playback never silently drops back to 1×.
    @Published private(set) var playbackRate: Float = 1.0

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var waveformTask: Task<Void, Never>?
    private var waveformCache: [URL: [Float]] = [:]
    private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var currentArtwork: NSImage?
    private var isSeeking = false

    init() {
        configureRemoteCommands()
    }

    func load(recordingID: String?, url: URL?, title: String, artwork: NSImage?) {
        currentRecordingID = recordingID
        currentTitle = title
        currentArtwork = Self.normalizedArtwork(from: artwork)
        guard currentURL != url else {
            refreshDuration()
            updateNowPlayingInfo()
            return
        }

        removeObservers()
        player?.pause()
        player = nil
        currentRecordingID = recordingID
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
        // `.timeDomain` keeps pitch stable across non-1× rates so 0.5×
        // doesn't sound chipmunk-y (default `.lowQualityZeroLatency`
        // is fine for live HLS but rough on local file playback).
        item.audioTimePitchAlgorithm = .timeDomain
        let nextPlayer = AVPlayer(playerItem: item)
        player = nextPlayer
        refreshDuration()
        loadWaveform(for: url)

        timeObserver = nextPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.18, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard self?.isSeeking != true else { return }
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
        // `play()` always resumes at 1×; honour the user's saved rate
        // by stamping it after the play call. Setting `rate` while
        // paused is harmless because we only do it on a player that
        // just transitioned to playing.
        player.play()
        if playbackRate != 1.0 {
            player.rate = playbackRate
        }
        isPlaying = true
        refreshDuration()
        updateNowPlayingInfo()
    }

    /// Update the user-preferred playback rate. Applied immediately
    /// when audio is currently playing; otherwise stored so the next
    /// `play()` call picks it up.
    func setPlaybackRate(_ rate: Float) {
        let clamped = max(0.25, min(rate, 4.0))
        playbackRate = clamped
        guard isPlaying, let player else { return }
        player.rate = clamped
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
        currentRecordingID = nil
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
        guard let player else {
            updateNowPlayingInfo()
            return
        }

        isSeeking = true
        player.seek(
            to: CMTime(seconds: clamped, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.currentTime = clamped
                self.isSeeking = false
                self.refreshDuration()
                self.updateNowPlayingInfo()
            }
        }
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
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(playbackRate) : 0.0,
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        if let currentArtwork {
            info[MPMediaItemPropertyArtwork] = Self.makeNowPlayingArtwork(from: currentArtwork)
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private nonisolated static func makeNowPlayingArtwork(from image: NSImage) -> MPMediaItemArtwork {
        let artworkImage = (image.copy() as? NSImage) ?? image
        // MediaPlayer evaluates this provider on a background queue; keep it nonisolated so Swift actor checks do not trap.
        return MPMediaItemArtwork(boundsSize: artworkImage.size) { _ in
            artworkImage
        }
    }

    private static func normalizedArtwork(from image: NSImage?) -> NSImage? {
        guard let image else { return nil }

        let canvasSize = NSSize(width: 256, height: 256)
        let canvas = NSImage(size: canvasSize)
        canvas.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: canvasSize).fill()

        let inset: CGFloat = 18
        image.draw(
            in: NSRect(x: inset, y: inset, width: canvasSize.width - inset * 2, height: canvasSize.height - inset * 2),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        canvas.unlockFocus()
        return canvas
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
    let isViewingLoadedAudio: Bool
    let hasLocalSession: Bool
    let waveformPeaks: [Float]
    let isLoadingWaveform: Bool
    let playbackRate: Float
    let onPlayPause: () -> Void
    let onSeek: (Double) -> Void
    let onSelectRate: (Float) -> Void

    @State private var rateSelectionFeedbackID = 0

    /// Allowed playback rates surfaced in the menu. Order matters —
    /// the menu renders top-to-bottom in this order.
    private static let rateOptions: [Float] = [0.5, 1.0, 1.5, 2.0, 3.0]

    private var sliderUpperBound: Double {
        max(duration, currentTime, 1)
    }

    var body: some View {
        HStack(spacing: 12) {
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
                .frame(width: 28, height: 28)
            }
            .buttonStyle(PanelIconButtonStyle(size: 28))
            .disabled(isPreparingAudio)
            .help(hasAudio ? "Play meeting audio" : "Download audio preview")

            VStack(alignment: .leading, spacing: 2) {
                Text(playbackStatusTitle)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(playbackStatusColor)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(playbackStatusDetail)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: 150, alignment: .leading)

            CloudPlaybackWaveformScrubber(
                progress: sliderProgress,
                isEnabled: hasAudio && !isPreparingAudio,
                peaks: waveformPeaks,
                isLoadingPeaks: isLoadingWaveform,
                onSeekProgress: { progress in
                    onSeek(progress * sliderUpperBound)
                }
            )

            playbackRateMenu
        }
        .frame(height: 44)
        .padding(.horizontal, 12)
        .padding(.top, 5)
        .padding(.bottom, 9)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.018))
    }

    private var sliderProgress: Double {
        guard sliderUpperBound > 0 else { return 0 }
        return min(max(0, currentTime / sliderUpperBound), 1)
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
                isEnabled: hasAudio,
                feedbackID: rateSelectionFeedbackID
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!hasAudio)
        .help("Playback speed")
    }

    private static func rateLabel(_ rate: Float) -> String {
        // Clean labels: integer rates render without trailing zeros
        // ("1×" not "1.0×"); halves keep one decimal ("0.5×", "1.5×").
        if rate == rate.rounded() {
            return "\(Int(rate))×"
        }
        return String(format: "%.1f×", rate)
    }

    private var playbackStatusTitle: String {
        if let errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        if !hasAudio && !hasLocalSession {
            return "Audio not local yet"
        }
        if !hasAudio {
            return "Audio unavailable"
        }
        return sourceDescription
    }

    private var playbackStatusDetail: String {
        if !hasAudio && !hasLocalSession {
            return "Use Sync in the header"
        }
        if hasAudio && !isViewingLoadedAudio {
            return "Browsing another recording"
        }
        return "\(Self.timeText(currentTime)) / \(duration > 0 ? Self.timeText(duration) : "--:--")"
    }

    private var playbackStatusColor: Color {
        if errorMessage != nil || !hasAudio {
            return DT.systemOrange
        }
        return Color.dtLabelSecondary
    }

    static func timeText(_ seconds: Double) -> String {
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

private struct MenuIconLabel: View {
    let systemName: String
    var size: CGFloat = 28

    @State private var hovered = false
    @State private var pressed = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .frame(width: size, height: size)
            .foregroundStyle(hovered || pressed ? Color.dtLabel : Color.dtLabelSecondary)
            .background(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .fill(Color.white.opacity(pressed ? 0.13 : (hovered ? 0.085 : 0)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .strokeBorder(Color.white.opacity(hovered || pressed ? 0.075 : 0), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DT.R.control, style: .continuous))
            .onHover { hovered = $0 }
            .scaleEffect(pressed ? 0.96 : 1)
            .animation(DT.ease(0.12), value: hovered)
            .animation(DT.ease(0.08), value: pressed)
            .onLongPressGesture(
                minimumDuration: .infinity,
                maximumDistance: 18,
                pressing: { pressed = $0 },
                perform: {}
            )
    }
}

/// Pill label that backs the playback-rate `Menu`. Tracks its own
/// hover state so the control feels responsive on mouse-over (Menu's
/// default label has no built-in hover/press chrome). When the user
/// has selected a non-1× rate, the pill picks up an accent fill so
/// the active state reads at a glance.
private struct PlaybackRatePillLabel: View {
    let text: String
    let isActive: Bool
    let isEnabled: Bool
    let feedbackID: Int

    @State private var hovered = false
    @State private var pressed = false
    @State private var didChange = false

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold, design: .monospaced))
            .foregroundStyle(foregroundColor)
            .frame(width: 40, height: 25)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(strokeColor, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovered = isEnabled && $0 }
            .scaleEffect(pressed ? 0.96 : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(DT.ease(0.12), value: hovered)
            .animation(DT.ease(0.08), value: pressed)
            .animation(DT.ease(0.18), value: isActive)
            .animation(DT.ease(0.16), value: didChange)
            .onLongPressGesture(
                minimumDuration: .infinity,
                maximumDistance: 18,
                pressing: { isPressing in
                    pressed = isEnabled && isPressing
                },
                perform: {}
            )
            .onChange(of: text) { _, _ in
                guard isEnabled else { return }
                flashChange()
            }
            .onChange(of: feedbackID) { _, _ in
                guard isEnabled else { return }
                flashChange()
            }
    }

    private func flashChange() {
        didChange = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.42) {
            didChange = false
        }
    }

    private var foregroundColor: Color {
        if !isEnabled { return Color.dtLabelTertiary }
        if isActive || didChange { return DT.waveformLit }
        return hovered ? Color.dtLabel : Color.dtLabel
    }

    private var fillColor: Color {
        if pressed {
            return Color.white.opacity(0.20)
        }
        if didChange {
            return DT.waveformLit.opacity(0.24)
        }
        if isActive {
            return DT.waveformLit.opacity(hovered ? 0.20 : 0.14)
        }
        return Color.white.opacity(hovered ? 0.16 : 0.085)
    }

    private var strokeColor: Color {
        if didChange {
            return DT.waveformLit.opacity(0.70)
        }
        if isActive {
            return DT.waveformLit.opacity(hovered ? 0.55 : 0.40)
        }
        return Color.white.opacity(hovered ? 0.34 : 0.18)
    }
}

private struct CloudPlaybackWaveformScrubber: View {
    let progress: Double
    let isEnabled: Bool
    let peaks: [Float]
    let isLoadingPeaks: Bool
    var compact = false
    let onSeekProgress: (Double) -> Void

    private var trackHeight: CGFloat { compact ? 13 : 32 }
    private let horizontalInset: CGFloat = 7
    private var scrubberHeight: CGFloat { compact ? 18 : 44 }
    private var playheadHeight: CGFloat { compact ? 17 : 40 }
    private let playheadWidth: CGFloat = 7

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, scrubberHeight)
            let clampedProgress = min(max(progress, 0), 1)
            let inset = min(horizontalInset, max(width / 2 - 1, 0))
            let contentWidth = max(width - inset * 2, 1)
            let spacing: CGFloat = 2.4
            let barCount = Self.barCount(for: contentWidth)
            let barWidth = Self.barWidth(for: contentWidth, barCount: barCount, spacing: spacing)
            let timeline = WaveformTimeline(
                inset: inset,
                contentWidth: contentWidth,
                barWidth: barWidth
            )
            let playheadX = timeline.xPosition(for: clampedProgress)

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
                    .frame(width: playheadWidth, height: playheadHeight)
                    .offset(x: playheadX - playheadWidth / 2)
                .allowsHitTesting(false)
            }
            .frame(width: width, height: height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard isEnabled else { return }
                        onSeekProgress(timeline.progress(for: value.location.x))
                    }
            )
        }
        .frame(height: scrubberHeight)
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

    private struct WaveformTimeline {
        let inset: CGFloat
        let contentWidth: CGFloat
        let barWidth: CGFloat

        private var startX: CGFloat {
            inset + barWidth / 2
        }

        private var width: CGFloat {
            max(contentWidth - barWidth, 1)
        }

        func xPosition(for progress: Double) -> CGFloat {
            startX + width * CGFloat(min(max(progress, 0), 1))
        }

        func progress(for xPosition: CGFloat) -> Double {
            Double(min(max((xPosition - startX) / width, 0), 1))
        }

        static func isBarPlayed(index: Int, count: Int, progress: Double) -> Bool {
            guard count > 1 else { return progress >= 0.5 }
            let clampedProgress = min(max(progress, 0), 1)
            let barProgress = Double(index) / Double(count - 1)
            return barProgress <= clampedProgress
        }
    }

    private var playheadColor: Color {
        Color.white.opacity(0.88)
    }

    private func barColor(index: Int, count: Int) -> Color {
        if WaveformTimeline.isBarPlayed(index: index, count: count, progress: progress) {
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

private struct CloudStatusChip: View {
    /// Horizontal inset between the capsule outline and the status text
    /// glyph. Exposed as a single source of truth so any view that wants
    /// its own trailing column to *visually* line up with the status
    /// chip's TEXT (not its capsule outline) — e.g. the duration label
    /// in `CloudRecordingRow`'s metadata row — can apply the same
    /// trailing offset and avoid the 6pt visual misalignment between
    /// "Ready" and "26:01" that peng-xiao called out (`f4892708`).
    static let nonProminentHorizontalInset: CGFloat = 6
    static let prominentHorizontalInset: CGFloat = 9

    private let displayStatus: CloudRecordingDisplayStatus
    var prominent: Bool = false

    init(
        status: CloudRecordingStatus,
        latestJobStatus: RemoteJobStatus? = nil,
        prominent: Bool = false
    ) {
        self.displayStatus = CloudRecordingDisplayStatus.resolve(
            recordingStatus: status,
            latestJobStatus: latestJobStatus
        )
        self.prominent = prominent
    }

    var body: some View {
        Text(displayStatus.displayName)
            .font(.system(size: prominent ? 11 : 9, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, prominent ? Self.prominentHorizontalInset : Self.nonProminentHorizontalInset)
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
        switch displayStatus {
        case .transcription(let status):
            return status.detailColor
        case .recording(let status):
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
}

private struct CloudJobStatusChip: View {
    let status: RemoteJobStatus
    var compact = false

    var body: some View {
        Text(status.displayName)
            .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold))
            .foregroundStyle(status.detailColor)
            .padding(.horizontal, compact ? 6 : 7)
            .padding(.vertical, compact ? 2 : 3)
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

    var detailIconName: String {
        switch self {
        case .queued, .running:
            return "hourglass"
        case .succeeded:
            return "waveform.badge.checkmark"
        case .failed:
            return "exclamationmark.triangle.fill"
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
            // The tint plate stays as a faint badge under whatever icon
            // we render. It used to also act as decorative padding (the
            // app icon was inset to 72% of the box), but peng-xiao
            // `26485a7a` flagged that as making the source logo look
            // smaller than the container suggests. Real app icons now
            // fill the box edge-to-edge; the rounded corner radius mask
            // keeps them from poking past the badge outline.
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(DT.statusReady.opacity(0.10))

            if let icon = recording.sourceAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            } else {
                // Source-symbol fallback when the recording's bundle ID
                // doesn't resolve to an installed app (e.g. Discord
                // running as a PWA, recording from a CLI tool, etc.).
                // Original tint was `DT.statusReady` against the same-
                // colour 10% plate, which made the symbol nearly
                // invisible on top of the badge — that's the missing
                // Discord icon peng-xiao saw at `26485a7a`. Render with
                // primary label colour at a larger size so the fallback
                // is unambiguously a recognisable shape.
                Image(systemName: recording.sourceIconName)
                    .font(.system(size: size * 0.58, weight: .medium))
                    .foregroundStyle(Color.dtLabel)
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

    var nowPlayingArtwork: NSImage? {
        if let sourceAppIcon {
            sourceAppIcon.size = NSSize(width: 256, height: 256)
            return sourceAppIcon
        }

        if let logo = NSImage(named: "Logo") ?? NSImage(named: "LogoTemplate") {
            logo.size = NSSize(width: 256, height: 256)
            return logo
        }

        return NSImage(systemSymbolName: sourceIconName, accessibilityDescription: nil)
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

    var durationSeconds: Double? {
        guard let durationMs, durationMs > 0 else { return nil }
        return Double(durationMs) / 1000.0
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

    var listTimeText: String {
        guard let date = createdAt else { return "Unknown time" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
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
