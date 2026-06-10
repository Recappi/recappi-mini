import AppKit
import SwiftUI

private enum CloudTypography {
    static let captionTiny: Font = .system(size: 10.5, weight: .regular)
    static let captionTinyMono: Font = .system(size: 10.5, weight: .regular, design: .monospaced)
    static let caption: Font = .system(size: 11, weight: .regular)
    static let captionMono: Font = .system(size: 11, weight: .regular, design: .monospaced)
    static let body: Font = .system(size: 14, weight: .regular)
    static let label: Font = .system(size: 13, weight: .medium)
    static let section: Font = .system(size: 16, weight: .semibold)
    static let title: Font = .system(size: 22, weight: .semibold)
}

struct CloudRecordingDetail: View {
    @StateObject private var detailWaveform = CloudRecordingWaveformPreview()
    @ObservedObject private var config = AppConfig.shared
    @State private var pendingAutoplayAfterPrepare = false
    @State private var pendingSeekAfterPrepare: Double?
    @State private var pinnedSegmentID: String?
    @State private var pendingPinnedSegmentIDAfterPrepare: String?
    @State private var isShowingRecordingInfo = false
    @State private var isShowingProcessingStatusDetail = false
    @State private var pendingScrollTarget: CloudDetailSection?
    @State private var activeDetailSection: CloudDetailSection = .summary
    @State private var suppressOffsetDrivenSectionUpdates = false
    @State private var isShowingRetranscribeContext = false
    @State private var isShowingTranscriptVersions = false
    @State private var selectedTranscriptVersionJobID: String?
    @State private var transcriptVersionCache: [String: TranscriptResponse] = [:]
    @State private var transcriptVersionLoadingJobID: String?
    @State private var transcriptVersionErrorMessage: String?
    @State private var retranscribeSceneDraft = RecordingSceneTemplate.meeting.rawValue
    @State private var retranscribePromptDraft = ""
    @State private var renamingSpeakerRawName: String?
    @State private var renamingSpeakerAnchorID: String?
    @State private var speakerRenameDraft = ""
    @State private var speakerNoteDraft = ""
    @State private var speakerEmojiDraft = ""
    @State private var summarySourcePopoverKey: String?
    @Namespace private var chapterRowHighlightNamespace
    @Namespace private var transcriptRowHighlightNamespace

    let recording: CloudRecording
    let recordingWebURL: URL?
    let latestJob: TranscriptionJob?
    let transcriptionJobs: [TranscriptionJob]
    let transcript: TranscriptResponse?
    let liveCaptionTranscriptState: LiveCaptionTranscriptLoadState
    let transcriptErrorMessage: String?
    let retranscriptionLimitMessage: String?
    let localSessionURL: URL?
    let playbackAudioURL: URL?
    let playbackSourceDescription: String
    let playbackErrorMessage: String?
    @Binding var cloudSearchQuery: String
    @Binding var selectedSearchSpeakerRawName: String?
    @Binding var speakerOverrides: [String: CloudSpeakerDisplayOverride]
    let indexedSearchResults: [CloudIndexedSearchResult]
    let isCloudSearchLoading: Bool
    @ObservedObject var audioPlayer: CloudMeetingAudioPlayer
    let isTranscriptLoading: Bool
    let isJobHistoryLoading: Bool
    let isPreparingPlaybackAudio: Bool
    let isDownloading: Bool
    let isDeleting: Bool
    let isSyncingToLocal: Bool
    let processingAction: CloudRecordingProcessingAction?
    let processingPhase: ProcessingPhase?
    let hasDownloadedAudio: Bool
    let hasNewerVersion: Bool
    let onLoadTranscript: () -> Void
    let onRefreshDetail: () -> Void
    let onCopyTranscript: () -> Void
    let onProcessRecording: (CloudRecordingProcessingAction) -> Void
    let onPreparePlaybackAudio: () -> Void
    let onRevealLocalSession: () -> Void
    let onSyncToLocal: () -> Void
    let onDownloadAudio: () -> Void
    let onRevealAudio: () -> Void
    let onDelete: () -> Void
    let onAcknowledgeNewerVersion: () -> Void
    let onLoadTranscriptVersion: @MainActor (String) async throws -> TranscriptResponse

    var body: some View {
        readerPane
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { detailToolbarContent }
        .sheet(isPresented: $isShowingTranscriptVersions) {
            transcriptVersionsSheet
        }
        .onAppear {
            detailWaveform.load(url: playbackAudioURL)
            refreshPlayerMetadataIfNeeded()
            refreshDetailWhenActivating(activeDetailSection)
        }
        .onChange(of: playbackAudioURL) { _, url in
            detailWaveform.load(url: url)
            if let pendingSeekAfterPrepare, url != nil {
                self.pendingSeekAfterPrepare = nil
                loadPlaybackAudio(url: url)
                audioPlayer.seek(to: pendingSeekAfterPrepare)
            }
            if let pendingPinnedSegmentIDAfterPrepare, url != nil {
                pinnedSegmentID = pendingPinnedSegmentIDAfterPrepare
                self.pendingPinnedSegmentIDAfterPrepare = nil
            }
            if pendingAutoplayAfterPrepare, url != nil {
                pendingAutoplayAfterPrepare = false
                loadPlaybackAudio(url: url)
                audioPlayer.play()
            }
            refreshPlayerMetadataIfNeeded()
        }
        .onChange(of: recording.id) { _, _ in
            pendingAutoplayAfterPrepare = false
            pendingSeekAfterPrepare = nil
            pendingPinnedSegmentIDAfterPrepare = nil
            pinnedSegmentID = nil
            selectedTranscriptVersionJobID = nil
            transcriptVersionCache.removeAll()
            transcriptVersionLoadingJobID = nil
            transcriptVersionErrorMessage = nil
            isShowingRecordingInfo = false
            isShowingProcessingStatusDetail = false
            isShowingRetranscribeContext = false
            isShowingTranscriptVersions = false
            activeDetailSection = .summary
            pendingScrollTarget = nil
            refreshPlayerMetadataIfNeeded()
            cloudSearchQuery = ""
            selectedSearchSpeakerRawName = nil
            renamingSpeakerRawName = nil
            renamingSpeakerAnchorID = nil
            speakerRenameDraft = ""
            speakerNoteDraft = ""
            speakerEmojiDraft = ""
            summarySourcePopoverKey = nil
        }
        .onChange(of: hasActualDetailContent) { _, hasContent in
            guard !hasContent else { return }
            activeDetailSection = .summary
            pendingScrollTarget = nil
        }
        .onChange(of: activeDetailSection) { _, section in
            refreshDetailWhenActivating(section)
        }
    }

    private var readerPane: some View {
        // Apple Music-style stacking: the transcript pane fills the
        // entire reader area and the Liquid Glass playback capsule
        // floats on top of it at the bottom (overlay, not VStack).
        // `safeAreaInset` reserves room at the bottom of the scrollable
        // content so the last transcript row never gets hidden behind
        // the capsule.
        VStack(alignment: .leading, spacing: 0) {
            CloudDetailHeaderSection {
                if isCloudSearchActive {
                    searchDetailHeader
                } else {
                    detailHeader
                }
            } latestJob: {
                terminalJobStrip
            } newerVersion: {
                newerVersionStrip
            } navigation: {
                if isCloudSearchActive {
                    searchNavigationRow
                } else {
                    detailNavigationRow
                }
            }

            if isViewingHistoricalVersion {
                historicalVersionBanner
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
            }

            if shouldShowProcessingContextStrip {
                processingContextStrip
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
                    .transaction { transaction in
                        transaction.animation = nil
                    }
            }

            Divider().overlay(Palette.borderHairline)

            if isCloudSearchActive {
                cloudSearchResultsPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                CloudDetailScrollableSections(
                    hasSummarySection: isSummaryNavigationAvailable,
                    activeSegmentID: activeSegmentID(in: visibleTranscript?.displaySegmentRows ?? []),
                    isPlaybackActive: audioPlayer.isPlaying,
                    pendingScrollTarget: $pendingScrollTarget,
                    activeDetailSection: $activeDetailSection,
                    onUpdateOffsets: updateActiveDetailSection(with:)
                ) {
                    transcriptInsightStack
                } timeline: {
                    timelineSectionView
                } transcriptHeader: {
                    EmptyView()
                } transcriptCard: {
                    transcriptCard
                }
                // Reset the scrollable reader when switching recordings, while
                // keeping the window toolbar hosted by the stable detail view.
                .id(recording.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    // Empty inset just reserves layout space equal to the
                    // capsule's footprint so the scrollable area can scroll
                    // past the floating player.
                    Color.clear.frame(height: floatingPlayerInset)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if !isCloudSearchActive {
                CloudDetailPlaybackSection {
                    bottomPlaybackBar
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(DT.motionAware(.spring(response: 0.26, dampingFraction: 0.88)), value: isCloudSearchActive)
    }

    /// Approximate height of the Liquid Glass playback capsule
    /// (44pt content + 6/10 vertical breathing room). Used as the
    /// bottom safe-area inset for the scrollable content.
    private var floatingPlayerInset: CGFloat { 60 }

    private var selectedTranscriptVersionJob: TranscriptionJob? {
        guard let selectedTranscriptVersionJobID else { return nil }
        return transcriptVersionJobs.first(where: { $0.id == selectedTranscriptVersionJobID })
    }

    private var visibleTranscript: TranscriptResponse? {
        guard let selectedTranscriptVersionJobID else { return transcript }
        return transcriptVersionCache[selectedTranscriptVersionJobID]
    }

    private var visibleTranscriptErrorMessage: String? {
        selectedTranscriptVersionJobID == nil ? transcriptErrorMessage : transcriptVersionErrorMessage
    }

    private var isVisibleTranscriptLoading: Bool {
        if let selectedTranscriptVersionJobID {
            return transcriptVersionLoadingJobID == selectedTranscriptVersionJobID
        }
        return isTranscriptLoading
    }

    private var isViewingHistoricalVersion: Bool {
        selectedTranscriptVersionJobID != nil
    }

    private var transcriptVersionJobs: [TranscriptionJob] {
        let jobs = transcriptionJobs
            .filter { $0.status == .succeeded && $0.transcriptId?.isEmpty == false }
        var seen = Set<String>()
        return jobs.filter { job in
            guard let transcriptId = job.transcriptId, !seen.contains(transcriptId) else {
                return false
            }
            seen.insert(transcriptId)
            return true
        }
    }

    private var hasPreviousTranscriptVersions: Bool {
        transcriptVersionJobs.contains { job in
            guard let activeTranscriptId = recording.activeTranscriptId else { return true }
            return job.transcriptId != activeTranscriptId
        }
    }

    private var hasSummarySection: Bool {
        structuredSummaryInsights != nil
            || summaryInsightText != nil
            || summaryStatusMessage != nil
            || shouldShowStandaloneActionItems
    }

    private var hasActualSummaryContent: Bool {
        structuredSummaryInsights != nil
            || summaryInsightText != nil
            || shouldShowStandaloneActionItems
    }

    private var hasActualTimelineContent: Bool {
        !timelineEntries.isEmpty
    }

    private var hasActualTranscriptContent: Bool {
        visibleTranscript?.displaySegmentRows.isEmpty == false
    }

    private var hasActualDetailContent: Bool {
        hasActualSummaryContent || hasActualTimelineContent || hasActualTranscriptContent
    }

    private var isSummaryNavigationAvailable: Bool {
        hasSummarySection
            || visibleTranscript == nil
            || isVisibleTranscriptLoading
            || shouldShowTranscriptGenerationEmptyState
    }

    private var isTranscriptUnavailableMessage: Bool {
        visibleTranscriptErrorMessage == "Transcript is not available for this recording yet."
    }

    private var isTranscriptGenerationProcessing: Bool {
        processingAction == .transcriptAndSummary || processingPhase != nil || latestJob?.status.isActive == true
    }

    private var shouldShowTranscriptGenerationEmptyState: Bool {
        guard !isViewingHistoricalVersion else { return false }
        guard !isVisibleTranscriptLoading || processingAction == .transcriptAndSummary else { return false }
        guard visibleTranscript == nil || !hasActualDetailContent else { return false }
        return isTranscriptGenerationProcessing
            || recording.activeTranscriptId == nil
            || isTranscriptUnavailableMessage
            || !hasActualDetailContent
    }

    private var shouldShowProcessingContextStrip: Bool {
        guard !isViewingHistoricalVersion else { return false }
        guard latestJob?.status.isActive != true else { return false }
        guard !shouldShowTranscriptGenerationEmptyState else { return false }
        // First-run cloud recordings need an obvious Transcribe entry.
        // Existing transcripts use the Re-Transcribe popover from the
        // actions menu, so the detail surface does not permanently grow.
        return recording.activeTranscriptId == nil
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
            if hasActualDetailContent {
                detailJumpBar
            }

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                Text(recording.createdDateText)
                    .font(CloudTypography.caption)
                    .foregroundStyle(Color.dtLabelTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                headerStatusLabel
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var headerStatusLabel: some View {
        if shouldShowProcessingStatusDetailLabel {
            Button {
                isShowingProcessingStatusDetail.toggle()
            } label: {
                HStack(spacing: 5) {
                    Text(processingStatusLabelTitle)
                        .font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(processingStatusColor.opacity(0.82))
                }
                .foregroundStyle(processingStatusColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, CloudStatusChip.prominentHorizontalInset)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(processingStatusColor.opacity(0.13))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(processingStatusColor.opacity(0.22), lineWidth: 0.5)
                )
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isShowingProcessingStatusDetail, arrowEdge: .bottom) {
                processingStatusDetailPopover
            }
            .recappiTooltip("Show processing details")
        } else {
            CloudStatusChip(status: recording.status, latestJobStatus: latestJob?.status, prominent: true)
        }
    }

    private var shouldShowProcessingStatusDetailLabel: Bool {
        processingPhase != nil
            || processingAction == .transcriptAndSummary
            || latestJob?.status.isActive == true
    }

    private var processingStatusLabelTitle: String {
        if let processingPhase {
            return processingPhase.title.replacingOccurrences(of: "…", with: "")
        }
        if let status = latestJob?.status, status.isActive {
            return status.displayName
        }
        return "Processing"
    }

    private var processingStatusColor: Color {
        if let status = latestJob?.status, status.isActive {
            return status.detailColor
        }
        return DT.statusUploading
    }

    private var processingStatusDetailTitle: String {
        if let processingPhase {
            return processingPhase.title
        }
        if let status = latestJob?.status, status.isActive {
            return "Transcription \(status.displayName.lowercased())"
        }
        return "Processing…"
    }

    private var processingStatusDetailText: String {
        if let processingPhase {
            return processingPhase.detail
        }
        if processingAction == .transcriptAndSummary {
            return "Recappi is uploading or starting cloud processing. Transcript and summary will appear here when it finishes."
        }
        if let latestJob, latestJob.status.isActive {
            return latestJob.providerModelText
        }
        return "Transcript and summary will appear here when processing finishes."
    }

    private var processingStatusDetailPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: latestJob?.status.detailIconName ?? "hourglass")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(processingStatusColor)
                    .frame(width: 18, height: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(processingStatusDetailTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.dtLabel)
                    Text(processingStatusDetailText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.dtLabelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if shouldShowProcessingRail {
                processingProgressRail
                    .padding(.top, 2)
            }

            if let latestJob {
                VStack(alignment: .leading, spacing: 6) {
                    recordingInfoRow("Status", latestJob.status.displayName, systemImage: "clock")
                    recordingInfoRow("Model", latestJob.providerModelText, systemImage: "cpu")
                }
                .padding(.top, 2)
            }
        }
        .padding(14)
        .frame(width: 310, alignment: .leading)
    }

    private var searchNavigationRow: some View {
        HStack(alignment: .center, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(CloudTypography.caption)
                Text("Search results")
                    .font(CloudTypography.label)
                Text("All recordings")
                    .font(CloudTypography.caption)
                    .foregroundStyle(Color.dtLabelTertiary)
            }
            .foregroundStyle(Color.dtLabel)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.controlFillHover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Palette.borderHairline, lineWidth: 0.5)
            )

            Spacer(minLength: 0)

            Button {
                cloudSearchQuery = ""
                selectedSearchSpeakerRawName = nil
            } label: {
                Text("Clear")
                    .font(CloudTypography.caption)
                    .foregroundStyle(Color.dtLabelSecondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule(style: .continuous).fill(Palette.controlFillHover))
            }
            .buttonStyle(.plain)
        }
    }

    private var detailJumpBar: some View {
        HStack(spacing: 6) {
            detailJumpSegment(
                title: "Summary",
                systemImage: "text.alignleft",
                section: .summary,
                accessibilityID: AccessibilityIDs.Cloud.jumpToSummaryButton,
                isDisabled: !isSummaryNavigationAvailable
            )

            detailJumpSegment(
                title: "Chapters",
                systemImage: "play.rectangle",
                section: .timeline,
                accessibilityID: AccessibilityIDs.Cloud.jumpToTimelineButton,
                isDisabled: false
            )

            detailJumpSegment(
                title: "Transcription",
                systemImage: "text.alignleft",
                section: .transcript,
                accessibilityID: AccessibilityIDs.Cloud.jumpToTranscriptButton,
                isDisabled: false
            )
        }
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
            refreshDetailWhenActivating(section)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .regular))
                Text(title)
                    .font(CloudTypography.caption)
            }
            .foregroundStyle(Color.dtLabelSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isActive ? Palette.controlFillPress : Palette.controlFillHover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Palette.borderHairline, lineWidth: 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .accessibilityIdentifier(accessibilityID)
    }

    private func refreshDetailWhenActivating(_ section: CloudDetailSection) {
        guard Self.shouldRefreshDetailWhenActivating(
            section: section,
            recordingStatus: recording.status,
            activeTranscriptId: recording.activeTranscriptId,
            transcript: visibleTranscript,
            isViewingHistoricalVersion: isViewingHistoricalVersion,
            isTranscriptLoading: isVisibleTranscriptLoading
        ) else {
            return
        }
        onRefreshDetail()
    }

    nonisolated static func shouldRefreshDetailWhenActivating(
        section: CloudDetailSection,
        recordingStatus: CloudRecordingStatus,
        activeTranscriptId: String?,
        transcript: TranscriptResponse?,
        isViewingHistoricalVersion: Bool,
        isTranscriptLoading: Bool
    ) -> Bool {
        guard section == .summary || section == .timeline else { return false }
        guard !isViewingHistoricalVersion, !isTranscriptLoading else { return false }
        guard recordingStatus == .ready else { return false }
        guard activeTranscriptId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return false
        }
        guard let transcript else { return true }
        return !CloudLibraryStore.hasSummaryContent(transcript)
    }

    private var isCloudSearchActive: Bool {
        !cloudSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedSearchSpeakerRawName != nil
    }

    private var visibleSpeakerIdentities: [CloudSpeakerIdentity] {
        speakerIdentities(for: visibleTranscript?.displaySegmentRows ?? [])
    }

    private func speakerIdentities(for rows: [CloudTranscriptSegmentDisplayRow]) -> [CloudSpeakerIdentity] {
        var seen: Set<String> = []
        var identities: [CloudSpeakerIdentity] = []
        for speaker in rows.compactMap(\.speaker).map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !speaker.isEmpty {
            guard !seen.contains(speaker) else { continue }
            seen.insert(speaker)
            if let identity = speakerIdentity(for: speaker, index: identities.count) {
                identities.append(identity)
            }
        }
        return identities
    }

    private func speakerIdentity(for rawName: String?, index: Int? = nil) -> CloudSpeakerIdentity? {
        guard let raw = rawName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let allNames = (visibleTranscript?.displaySegmentRows ?? [])
            .compactMap(\.speaker)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let offset: Int
        if let index {
            offset = index
        } else {
            let unique = allNames.reduce(into: [String]()) { result, name in
                if !result.contains(name) {
                    result.append(name)
                }
            }
            offset = unique.firstIndex(of: raw) ?? 0
        }
        let speakerID = CloudSpeakerModel.speakerID(forRawName: raw)
        let override = speakerOverrides[speakerID]
        return CloudSpeakerIdentity(
            speakerID: speakerID,
            rawName: raw,
            displayName: override?.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? override!.displayName
                : raw,
            emoji: override?.emoji.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                ? override!.emoji
                : CloudSpeakerIdentity.defaultEmoji(at: offset),
            color: CloudSpeakerIdentity.defaultColor(at: offset),
            note: override?.note
        )
    }

    private var cloudSearchResults: [CloudSearchResult] {
        let query = cloudSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let indexedResults = indexedSearchResults.map(cloudSearchResult(from:))
        let results = indexedResults.isEmpty && UITestModeConfiguration.shared.stateBoardVisualFixtureEnabled
            ? currentRecordingSearchResults + stateBoardGlobalSearchFixtureResults
            : indexedResults
        return results.filter { result in
            let speakerMatches = selectedSearchSpeakerRawName == nil || result.speaker?.rawName == selectedSearchSpeakerRawName
            let queryMatches = query.isEmpty || result.searchableText.lowercased().contains(query)
            return speakerMatches && queryMatches
        }
    }

    private var allCloudSearchResults: [CloudSearchResult] {
        let indexedResults = indexedSearchResults.map(cloudSearchResult(from:))
        return indexedResults.isEmpty && UITestModeConfiguration.shared.stateBoardVisualFixtureEnabled
            ? currentRecordingSearchResults + stateBoardGlobalSearchFixtureResults
            : indexedResults
    }

    private func cloudSearchResult(from indexed: CloudIndexedSearchResult) -> CloudSearchResult {
        CloudSearchResult(
            id: indexed.id,
            recordingID: indexed.recordingID,
            recordingTitle: indexed.recordingTitle,
            source: CloudSearchResultSource(indexed.source),
            sectionBreadcrumb: indexed.sectionBreadcrumb,
            marker: indexed.marker,
            text: indexed.text,
            speaker: speakerIdentity(for: indexed.speakerRawName),
            targetSegmentID: indexed.targetSegmentID,
            isCurrentRecording: indexed.recordingID == recording.id
        )
    }

    private var currentRecordingSearchResults: [CloudSearchResult] {
        var results: [CloudSearchResult] = []

        for row in visibleTranscript?.displaySegmentRows ?? [] {
            results.append(
                CloudSearchResult(
                    id: "\(recording.id)-transcript-\(row.id)",
                    recordingID: recording.id,
                    recordingTitle: recording.presentationTitle,
                    source: .transcript,
                    sectionBreadcrumb: "Transcript",
                    marker: row.marker,
                    text: row.text,
                    speaker: speakerIdentity(for: row.speaker),
                    targetSegmentID: row.id,
                    isCurrentRecording: true
                )
            )
        }

        let summaryEntries = currentSummarySearchEntries()
        for entry in summaryEntries {
            results.append(
                CloudSearchResult(
                    id: "\(recording.id)-summary-\(entry.section)-\(abs(entry.text.hashValue))",
                    recordingID: recording.id,
                    recordingTitle: recording.presentationTitle,
                    source: .summary,
                    sectionBreadcrumb: "Notes · \(entry.section)",
                    marker: nil,
                    text: entry.text,
                    speaker: nil,
                    targetSegmentID: nil,
                    isCurrentRecording: true
                )
            )
        }

        return results
    }

    private func currentSummarySearchEntries() -> [(section: String, text: String)] {
        guard let insights = structuredSummaryInsights else {
            if let summaryInsightText {
                return [("Overview", summaryInsightText)]
            }
            return []
        }

        var entries: [(String, String)] = []
        if let summaryText = insights.summaryText {
            entries.append(("TL;DR", summaryText))
        }
        entries.append(contentsOf: insights.keyPoints.map { ("Key points", $0) })
        entries.append(contentsOf: insights.decisions.map { ("Decisions", $0) })
        entries.append(contentsOf: insights.actionItemTexts.map { ("Action items", $0) })
        entries.append(contentsOf: insights.quoteTexts.map { ("Quotes", $0) })
        return entries
    }

    private var stateBoardGlobalSearchFixtureResults: [CloudSearchResult] {
        guard UITestModeConfiguration.shared.stateBoardVisualFixtureEnabled else { return [] }
        return [
            CloudSearchResult(
                id: "fixture-design-summary",
                recordingID: "fixture-design",
                recordingTitle: "Design review with platform team",
                source: .summary,
                sectionBreadcrumb: "Notes · Key points",
                marker: nil,
                text: "The team compared caption panel affordances, search placement, and speaker labeling before moving into production SwiftUI mocks.",
                speaker: nil,
                targetSegmentID: nil,
                isCurrentRecording: false
            ),
            CloudSearchResult(
                id: "fixture-design-transcript",
                recordingID: "fixture-design",
                recordingTitle: "Design review with platform team",
                source: .transcript,
                sectionBreadcrumb: "Transcript",
                marker: "12:04",
                text: "The caption panel should stay quiet until hover, but search needs to work across every recording, not only this transcript.",
                speaker: CloudSpeakerIdentity(
                    speakerID: CloudSpeakerModel.speakerID(forRawName: "Maya"),
                    rawName: "Maya",
                    displayName: "Maya",
                    emoji: "💬",
                    color: CloudSpeakerIdentity.defaultColor(at: 3),
                    note: nil
                ),
                targetSegmentID: nil,
                isCurrentRecording: false
            ),
            CloudSearchResult(
                id: "fixture-sales-summary",
                recordingID: "fixture-sales",
                recordingTitle: "Customer support sync",
                source: .summary,
                sectionBreadcrumb: "Notes · Decisions",
                marker: nil,
                text: "Support agreed to use transcript search for exact quotes and note search for recurring customer themes.",
                speaker: nil,
                targetSegmentID: nil,
                isCurrentRecording: false
            ),
            CloudSearchResult(
                id: "fixture-sales-transcript",
                recordingID: "fixture-sales",
                recordingTitle: "Customer support sync",
                source: .transcript,
                sectionBreadcrumb: "Transcript",
                marker: "08:41",
                text: "Search should find the exact transcript sentence and also surface the related summary section when the wording differs.",
                speaker: CloudSpeakerIdentity(
                    speakerID: CloudSpeakerModel.speakerID(forRawName: "Noah"),
                    rawName: "Noah",
                    displayName: "Noah",
                    emoji: "🎧",
                    color: CloudSpeakerIdentity.defaultColor(at: 1),
                    note: nil
                ),
                targetSegmentID: nil,
                isCurrentRecording: false
            ),
        ]
    }

    private var cloudSearchResultsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                searchHeader

                if cloudSearchResults.isEmpty {
                    searchEmptyState
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(cloudSearchResults) { result in
                            CloudSearchResultRow(result: result) {
                                activateSearchResult(result)
                            }
                            .accessibilityIdentifier(AccessibilityIDs.Cloud.searchResultRowPrefix + result.id)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Palette.surfaceCard)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Palette.borderHairline, lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .accessibilityIdentifier(AccessibilityIDs.Cloud.searchResults)
    }

    private var searchHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(cloudSearchResults.count) results")
                    .font(CloudTypography.label)
                    .foregroundStyle(Color.dtLabel)
                Text("across all recordings")
                    .font(CloudTypography.caption)
                    .foregroundStyle(Color.dtLabelTertiary)
                    .lineLimit(1)
                Spacer(minLength: 0)

                if isCloudSearchLoading {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.65)
                        .frame(width: 16, height: 16)
                }

                HStack(spacing: 5) {
                    sourceCountChip(
                        "Verbatim",
                        systemImage: "text.quote",
                        count: cloudSearchResults.filter { $0.source == .transcript }.count
                    )
                    sourceCountChip(
                        "Notes",
                        systemImage: "note.text",
                        count: cloudSearchResults.filter { $0.source == .summary }.count
                    )
                }
            }

            if !visibleSpeakerIdentities.isEmpty {
                FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    searchFilterChip(title: "All speakers", rawName: nil)
                    ForEach(visibleSpeakerIdentities) { speaker in
                        searchFilterChip(
                            title: "\(speaker.emoji) \(speaker.displayName)",
                            rawName: speaker.rawName
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.surfaceCardSubtle)
        )
    }

    private func sourceCountChip(_ title: String, systemImage: String, count: Int) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 8.5, weight: .medium))
            Text("\(count)")
                .font(CloudTypography.captionMono)
            Text(title)
                .font(CloudTypography.caption)
        }
        .foregroundStyle(Color.dtLabelSecondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
    }

    private func searchFilterChip(title: String, rawName: String?) -> some View {
        let isSelected = selectedSearchSpeakerRawName == rawName
        return Button {
            selectedSearchSpeakerRawName = rawName
        } label: {
            Text(title)
                .font(CloudTypography.caption)
                .foregroundStyle(Color.dtLabelSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? Palette.controlFillPress : Color.clear)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(Palette.borderHairline, lineWidth: 0.6)
                )
        }
        .buttonStyle(.plain)
    }

    private var searchEmptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.dtLabelTertiary)
            Text("No transcript or note results yet.")
                .font(CloudTypography.label)
                .foregroundStyle(Color.dtLabelSecondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.surfaceCard)
        )
    }

    private func activateSearchResult(_ result: CloudSearchResult) {
        cloudSearchQuery = ""
        selectedSearchSpeakerRawName = nil
        switch result.source {
        case .summary:
            activeDetailSection = .summary
            pendingScrollTarget = .summary
            pinnedSegmentID = nil
        case .transcript:
            activeDetailSection = .transcript
            pendingScrollTarget = .transcript
            pinnedSegmentID = result.isCurrentRecording ? result.targetSegmentID : nil
        }
    }

    private func updateActiveDetailSection(with offsets: [CloudDetailSection: CGFloat]) {
        guard pendingScrollTarget == nil else { return }
        guard !suppressOffsetDrivenSectionUpdates else { return }
        activeDetailSection = CloudDetailSection.resolveVisibleSection(
            current: activeDetailSection,
            hasSummarySection: hasSummarySection,
            transcriptOffset: offsets[.transcript],
            timelineOffset: offsets[.timeline]
        )
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

    private func selectTranscriptVersion(_ job: TranscriptionJob) {
        if job.transcriptId == recording.activeTranscriptId {
            clearHistoricalVersionSelection()
            isShowingTranscriptVersions = false
            return
        }

        selectedTranscriptVersionJobID = job.id
        transcriptVersionErrorMessage = nil
        pinnedSegmentID = nil
        activeDetailSection = .summary
        pendingScrollTarget = nil
        isShowingTranscriptVersions = false

        guard transcriptVersionCache[job.id] == nil else { return }
        transcriptVersionLoadingJobID = job.id

        Task {
            do {
                let transcript = try await onLoadTranscriptVersion(job.id)
                guard !Task.isCancelled else { return }
                transcriptVersionCache[job.id] = transcript
                if selectedTranscriptVersionJobID == job.id {
                    transcriptVersionErrorMessage = nil
                }
            } catch is CancellationError {
                // Selection changes cancel silently.
            } catch {
                DiagnosticsLog.error(
                    "cloud",
                    "transcript_version.load.failed recordingID=\(recording.id) jobID=\(job.id) \(DiagnosticsLog.errorSummary(error))"
                )
                if selectedTranscriptVersionJobID == job.id {
                    transcriptVersionErrorMessage = NetworkErrorPresenter.userFacingMessage(for: error)
                }
            }

            if transcriptVersionLoadingJobID == job.id {
                transcriptVersionLoadingJobID = nil
            }
        }
    }

    private func clearHistoricalVersionSelection() {
        selectedTranscriptVersionJobID = nil
        transcriptVersionLoadingJobID = nil
        transcriptVersionErrorMessage = nil
        pinnedSegmentID = nil
        activeDetailSection = .summary
        pendingScrollTarget = nil
    }

    @ViewBuilder
    private var transcriptInsightStack: some View {
        if let structuredSummaryInsights {
            structuredSummaryContent(structuredSummaryInsights)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.summaryText)
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
            summaryStatusEmptyState(message: summaryStatusMessage)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.summaryText)
        } else if shouldShowTranscriptGenerationEmptyState {
            transcriptGenerationEmptyState(showsAction: true, minHeight: 430)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.summaryText)
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
                                .strokeBorder(DT.appAccent.opacity(0.42), lineWidth: 1)
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
                summaryHeroCard(text: tldr, topics: insights.topics)
            }

            summaryGroupedListCard(insights: insights)
        }
        .frame(maxWidth: 760, alignment: .leading)
    }

    @ViewBuilder
    private func summaryHeroCard(text: String, topics: [String]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Summary")
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(Color.dtLabelTertiary)
                .textCase(.uppercase)
                .tracking(0.6)

            markdownText(text)
                .font(.body)
                .foregroundStyle(Color.dtLabel)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !topics.isEmpty {
                FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    ForEach(Array(topics.enumerated()), id: \.offset) { entry in
                        summaryTopicChip(entry.element, accent: summaryNeutralAccent)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(summaryCardBackground)
    }

    @ViewBuilder
    private func summaryGroupedListCard(insights: TranscriptSummaryInsights) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            let hasKey = !insights.keyPoints.isEmpty
            let hasDecisions = !insights.decisions.isEmpty
            let hasSteps = !insights.actionItemTexts.isEmpty
            let hasQuotes = !insights.quoteTexts.isEmpty

            if hasKey {
                summaryGroupedSubsection(label: "Key insights", items: insights.keyPoints, bullet: nil)
            }

            if hasDecisions {
                if hasKey { Divider() }
                summaryGroupedSubsection(label: "Decisions", items: insights.decisions, bullet: nil)
            }

            if hasSteps {
                if hasKey || hasDecisions { Divider() }
                summaryGroupedSubsection(label: "Next steps", items: insights.actionItemTexts, bullet: .nextStep)
            }

            if hasQuotes {
                if hasKey || hasDecisions || hasSteps { Divider() }
                summaryGroupedQuotes(items: insights.quoteTexts)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(summaryCardBackground)
    }

    @ViewBuilder
    private func summaryGroupedQuotes(items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notable quotes")
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(Color.dtLabelTertiary)
                .textCase(.uppercase)
                .tracking(0.6)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, quote in
                    markdownText(quote)
                        .font(.body)
                        .italic()
                        .foregroundStyle(Color.dtLabel)
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 10)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(Palette.borderSubtle)
                                .frame(width: 2)
                        }
                }
            }
        }
    }

    enum SummaryBullet { case nextStep }

    @ViewBuilder
    private func summaryGroupedSubsection(label: String, items: [String], bullet: SummaryBullet?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(label)
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(Color.dtLabelTertiary)
                .textCase(.uppercase)
                .tracking(0.6)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(items.prefix(6).enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 10) {
                        if bullet == .nextStep {
                            Image(systemName: "circle")
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(DT.appAccent)
                                .padding(.top, 4)
                        }
                        markdownText(item)
                            .font(.body)
                            .foregroundStyle(Color.dtLabel)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var summaryCardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.dtLabel.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.dtLabel.opacity(0.06), lineWidth: 0.5)
            )
    }

    private var summaryNeutralAccent: Color {
        Color.dtLabelTertiary
    }

    private struct TimelineChapterDisplayEntry: Identifiable {
        let id: String
        let startMs: Int
        let endMs: Int
        let title: String
        let summary: String

        var timeRange: String {
            "\(Self.formatTime(startMs)) – \(Self.formatTime(endMs))"
        }

        static func formatTime(_ milliseconds: Int) -> String {
            let total = max(0, milliseconds / 1000)
            let hours = total / 3600
            let mins = (total % 3600) / 60
            let secs = total % 60
            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, mins, secs)
            }
            return String(format: "%02d:%02d", mins, secs)
        }
    }

    private var timelineEntries: [TimelineChapterDisplayEntry] {
        (structuredSummaryInsights?.timeline ?? [])
            .enumerated()
            .map { offset, chapter in
                TimelineChapterDisplayEntry(
                    id: "\(chapter.startMs)-\(chapter.endMs)-\(offset)",
                    startMs: chapter.startMs,
                    endMs: chapter.endMs,
                    title: chapter.title,
                    summary: chapter.summary
                )
            }
    }

    private var currentTimelinePlaybackMs: Int? {
        guard audioPlayer.currentRecordingID == recording.id else { return nil }
        return Int((audioPlayer.currentTime * 1000).rounded())
    }

    private func activeTimelineIndex(_ entries: [TimelineChapterDisplayEntry]) -> Int? {
        guard let currentTimelinePlaybackMs else { return nil }
        if let active = entries.firstIndex(where: {
            currentTimelinePlaybackMs >= $0.startMs && currentTimelinePlaybackMs < $0.endMs
        }) {
            return active
        }
        return entries.lastIndex(where: { currentTimelinePlaybackMs >= $0.startMs })
    }

    @ViewBuilder
    private func timelineChaptersBody() -> some View {
        let entries = timelineEntries
        let activeIndex = activeTimelineIndex(entries)

        if entries.isEmpty {
            timelineEmptyState
        } else {
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { (offset, entry) in
                    timelineChapterRow(
                        entry,
                        index: offset,
                        activeIndex: activeIndex
                    )
                }
            }
            .animation(DT.motionAware(DT.easeSpring(0.20)), value: activeIndex)
        }
    }

    /// Chapter navigation rendered in the same row language as transcript
    /// segments: the row itself is the jump target, without a separate
    /// timeline rail or right-side action chip.
    @ViewBuilder
    private var timelineSectionView: some View {
        if timelineEntries.isEmpty {
            timelineEmptyState
        } else {
            timelineChaptersBody()
        }
    }


    @ViewBuilder
    private func timelineChapterRow(
        _ entry: TimelineChapterDisplayEntry,
        index: Int,
        activeIndex: Int?
    ) -> some View {
        let isActive = activeIndex == index

        Button {
            handlePlaybackSeek(Double(entry.startMs) / 1000.0)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(entry.timeRange)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.dtLabelTertiary)
                        .lineLimit(1)

                    Text(entry.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.dtLabelSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(entry.summary)
                    .font(.body)
                    .foregroundStyle(Color.dtLabel)
                    .lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                CloudActivePlaybackRowHighlight(
                    isActive: isActive,
                    namespace: chapterRowHighlightNamespace,
                    id: "chapter-active-row"
                )
            )
        }
        .buttonStyle(.plain)
    }

    private var timelineEmptyState: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Palette.surfaceCardSubtle)
                    .frame(width: 44, height: 44)

                Image(systemName: "clock.badge.questionmark")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .frame(width: 22, height: 22)
            }
            .overlay(
                Circle()
                    .strokeBorder(Palette.borderHairline, lineWidth: 0.6)
            )

            VStack(spacing: 5) {
                Text("No chapters available")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.dtLabel)
                Text("Generate a new summary for this recording to create audio chapter markers.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, minHeight: 430, alignment: .center)
    }

    @ViewBuilder
    private func summaryCalloutBlock(title: String, text: String) -> some View {
        summarySectionBlock(title: title, systemImage: "quote.opening", accent: summaryNeutralAccent) {
            markdownText(text)
                .font(CloudTypography.body)
                .foregroundStyle(Color.dtLabel)
                .lineSpacing(2.5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func summaryBulletSection(
        title: String,
        systemImage: String,
        items: [String],
        accent: Color,
        sectionKey: String
    ) -> some View {
        if !items.isEmpty {
            summarySectionBlock(
                title: title,
                systemImage: systemImage,
                accent: accent
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.offset) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Circle()
                                .fill(accent.opacity(0.72))
                                .frame(width: 4, height: 4)
                                .padding(.top, 9)
                            markdownText(entry.element)
                                .font(CloudTypography.body)
                                .foregroundStyle(Color.dtLabel)
                                .lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func summarySourceBadge(_ identity: CloudSpeakerIdentity, key: String) -> some View {
        Button {
            summarySourcePopoverKey = key
        } label: {
            HStack(spacing: 4) {
                Text(identity.emoji)
                    .font(.system(size: 9.5))
                Text(identity.displayName)
                    .font(CloudTypography.caption)
                    .lineLimit(1)
            }
            .foregroundStyle(Color.dtLabelSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(Capsule(style: .continuous).fill(Palette.controlFillHover))
            .overlay(Capsule(style: .continuous).strokeBorder(Palette.borderHairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(identity.displayName) source")
        .accessibilityIdentifier(AccessibilityIDs.Cloud.summarySourceBadgePrefix + key)
        .popover(
            isPresented: Binding(
                get: { summarySourcePopoverKey == key },
                set: { isPresented in if !isPresented { summarySourcePopoverKey = nil } }
            ),
            arrowEdge: .top
        ) {
            summarySourcePopover(for: identity)
        }
    }

    private func summaryAttributionIdentity(for offset: Int) -> CloudSpeakerIdentity? {
        let identities = visibleSpeakerIdentities
        guard !identities.isEmpty else { return nil }
        return identities[offset % identities.count]
    }

    private func summarySourcePopover(for identity: CloudSpeakerIdentity) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                speakerAvatar(identity, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(identity.displayName)
                        .font(CloudTypography.caption)
                        .foregroundStyle(Color.dtLabel)
                    Text("Source transcript segments")
                        .font(CloudTypography.caption)
                        .foregroundStyle(Color.dtLabelTertiary)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                ForEach(summarySourceRows(for: identity).prefix(3)) { row in
                    HStack(alignment: .top, spacing: 8) {
                        Text(row.marker)
                            .font(CloudTypography.captionMono)
                            .foregroundStyle(Color.dtLabelSecondary)
                            .frame(width: 44, alignment: .leading)
                        Text(row.text)
                            .font(CloudTypography.caption)
                            .foregroundStyle(Color.dtLabelSecondary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(13)
        .frame(width: 320, alignment: .leading)
        .background(DT.recordingShell)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.summarySourcePopover)
    }

    private func summarySourceRows(for identity: CloudSpeakerIdentity) -> [CloudTranscriptSegmentDisplayRow] {
        let rows = visibleTranscript?.displaySegmentRows ?? []
        let matches = rows.filter { $0.speaker == identity.rawName }
        return matches.isEmpty ? Array(rows.prefix(3)) : matches
    }

    @ViewBuilder
    private func summaryTopicSection(items: [String]) -> some View {
        if !items.isEmpty {
            let topicAccent = summaryNeutralAccent
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
            .font(CloudTypography.caption)
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
            summarySectionBlock(title: "Notable quotes", systemImage: "quote.bubble", accent: Palette.labelTertiary) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(items.enumerated()), id: \.offset) { entry in
                        markdownText(entry.element)
                            .font(CloudTypography.body)
                            .italic()
                            .foregroundStyle(Color.dtLabel)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 12)
                            .overlay(alignment: .leading) {
                                Rectangle()
                                    .fill(Palette.borderSubtle)
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
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.dtLabelTertiary)
                .textCase(.uppercase)
                .tracking(0.6)

            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(summaryCardBackground)
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(CloudTypography.section)
                    .foregroundStyle(Color.dtLabel)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Spacer(minLength: 0)

                if let trailingText {
                    Text(trailingText)
                        .font(CloudTypography.captionTiny)
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityIdentifier(accessibilityID)
    }

    private var summaryInsightText: String? {
        guard let summary = visibleTranscript?.summary else { return nil }
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var summaryStatusMessage: String? {
        guard structuredSummaryInsights == nil, summaryInsightText == nil else {
            return nil
        }
        switch visibleTranscript?.summaryStatus {
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
        switch visibleTranscript?.summaryStatus {
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

    private var summaryStatusTitle: String {
        switch visibleTranscript?.summaryStatus {
        case .pending:
            return "Summary pending"
        case .queued:
            return "Summary queued"
        case .running:
            return "Generating summary"
        case .failed:
            return "Summary failed"
        case .skipped:
            return "Summary skipped"
        case .succeeded, .none:
            return "Summary"
        }
    }

    private func summaryStatusEmptyState(message: String) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Palette.surfaceCardSubtle)
                    .frame(width: 44, height: 44)

                Image(systemName: summaryStatusIconName)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .frame(width: 22, height: 22)
            }
            .overlay(
                Circle()
                    .strokeBorder(Palette.borderHairline, lineWidth: 0.6)
            )

            VStack(spacing: 5) {
                Text(summaryStatusTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.dtLabel)

                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, minHeight: 430, alignment: .center)
    }

    private var structuredSummaryInsights: TranscriptSummaryInsights? {
        guard let insights = visibleTranscript?.summaryInsights, !insights.isEmpty else {
            return nil
        }
        return insights
    }

    private var visibleActionItems: [String] {
        visibleTranscript?.actionItems?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        ?? []
    }

    private var shouldShowStandaloneActionItems: Bool {
        guard !visibleActionItems.isEmpty else { return false }
        guard let structuredSummaryInsights else { return true }
        return structuredSummaryInsights.actionItemTexts.isEmpty
    }

    private func isProcessingActionDisabled(_ action: CloudRecordingProcessingAction) -> Bool {
        if isViewingHistoricalVersion {
            return true
        }
        if processingAction != nil || isTranscriptLoading {
            return true
        }
        return latestJob?.status.isActive == true
            || retranscriptionLimitMessage != nil
            || !recording.allowsProcessingRequest(hasLocalSession: localSessionURL != nil)
    }

    private func processingHelpText(for action: CloudRecordingProcessingAction) -> String {
        if isViewingHistoricalVersion {
            return "Cannot re-transcribe historical versions. Switch back to current first."
        }
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
        if recording.isLocalOnlyRecording {
            if localSessionURL != nil {
                return "Upload the local audio to Recappi Cloud and start transcription."
            }
            return "This recording is saved locally, but its local audio folder is unavailable."
        }
        return action.helpText
    }

    private var detailHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            CloudSourceIcon(recording: recording, size: 34)

            Text(recording.presentationTitle)
                .font(CloudTypography.title)
                .foregroundStyle(Color.dtLabel)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)
                .frame(minWidth: 0)
        }
    }

    private var searchDetailHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(DT.appAccent.opacity(0.14))
                Image(systemName: "magnifyingglass")
                    .font(CloudTypography.section)
                    .foregroundStyle(DT.appAccentSoft)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text("Search all recordings")
                    .font(CloudTypography.title)
                    .foregroundStyle(Color.dtLabel)
                    .lineLimit(1)

                Text(searchModeSubtitle)
                    .font(CloudTypography.caption)
                    .foregroundStyle(Color.dtLabelTertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                cloudSearchQuery = ""
                selectedSearchSpeakerRawName = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(PanelIconButtonStyle(size: 28))
            .recappiTooltip("Close search")
        }
    }

    private var searchModeSubtitle: String {
        let query = cloudSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "Verbatim hits and notes across every recording"
        }
        return "Results for “\(query)”"
    }

    private var processingScene: RecordingSceneTemplate {
        RecordingSceneTemplate.option(for: config.recordingSceneTemplate)
    }

    private var retranscribeScene: RecordingSceneTemplate {
        RecordingSceneTemplate.option(for: retranscribeSceneDraft)
    }

    private var processingContextStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(RecordingSceneTemplate.allCases) { option in
                        Button {
                            config.recordingSceneTemplate = option.rawValue
                        } label: {
                            Label(option.title, systemImage: option == processingScene ? "checkmark" : "")
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text("Scene")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.dtLabelTertiary)
                        Text(processingScene.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.dtLabel)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(Color.dtLabelTertiary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                            .fill(Palette.surfaceCardSubtle)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                            .strokeBorder(Palette.borderHairline, lineWidth: 0.6)
                    )
                }
                .buttonStyle(.plain)
                .recappiTooltip("Choose processing scene")

                Button {
                    config.recordingTemplatePromptExpanded.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: config.recordingTemplatePromptExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(Color.dtLabelTertiary)
                        Text("Prompt")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.dtLabel)
                            .lineLimit(1)
                        Text("transcription")
                            .font(.system(size: 9.5, weight: .regular))
                            .foregroundStyle(Color.dtLabelTertiary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                            .fill(Palette.surfaceCardSubtle)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                            .strokeBorder(Palette.borderHairline, lineWidth: 0.6)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityIDs.Panel.promptDisclosureButton)

                Spacer(minLength: 8)

                Button(processingAction == .transcriptAndSummary ? "Processing…" : CloudRecordingProcessingAction.transcriptAndSummary.title(hasExistingTranscript: recording.activeTranscriptId != nil)) {
                    onProcessRecording(.transcriptAndSummary)
                }
                .buttonStyle(PanelPushButtonStyle())
                .frame(minWidth: 98)
                .disabled(isProcessingActionDisabled(.transcriptAndSummary))
                .recappiTooltip(processingHelpText(for: .transcriptAndSummary))
                .accessibilityIdentifier(AccessibilityIDs.Cloud.retranscribeButton)
            }
            .transaction { transaction in
                transaction.animation = nil
            }

            if config.recordingTemplatePromptExpanded {
                promptTextEditor(
                    text: $config.recordingExtraPrompt,
                    height: 72
                )
                .transition(.opacity)
            }
        }
        .padding(.vertical, 7)
        .animation(DT.motionAware(DT.ease(DT.Motion.elementPresence)), value: processingScene)
        .animation(DT.motionAware(DT.ease(DT.Motion.elementPresence)), value: config.recordingTemplatePromptExpanded)
    }

    @ToolbarContentBuilder
    private var detailToolbarContent: some ToolbarContent {
        ToolbarItem(id: "cloud-recording-info", placement: .primaryAction) {
            Button {
                isShowingRecordingInfo.toggle()
            } label: {
                Label("Recording details", systemImage: "info.circle")
            }
            .recappiTooltip("Show recording details")
            .popover(isPresented: $isShowingRecordingInfo, arrowEdge: .top) {
                recordingInfoPopover
            }
            .accessibilityIdentifier(AccessibilityIDs.Cloud.recordingInfoButton)
        }

        ToolbarItem(id: "cloud-recording-actions", placement: .primaryAction) {
            recordingActionsMenu
        }
    }

    private var toolbarLocalActionButton: some View {
        Button {
            if localSessionURL == nil {
                onSyncToLocal()
            } else {
                onRevealLocalSession()
            }
        } label: {
            if isSyncingToLocal {
                ProgressView()
                    .controlSize(.small)
            } else {
                Label(
                    localSessionURL == nil ? "Sync to local" : "Open local session",
                    systemImage: localSessionURL == nil ? "arrow.down.doc" : "folder"
                )
            }
        }
        .disabled(isSyncingToLocal)
        .recappiTooltip(localSessionURL == nil ? "Sync to local" : "Open local session")
        .accessibilityIdentifier(localSessionURL == nil ? AccessibilityIDs.Cloud.syncToLocalButton : AccessibilityIDs.Cloud.revealLocalSessionButton)
    }

    private var recordingActionsMenu: some View {
        Menu {
            if localSessionURL == nil {
                Button(isSyncingToLocal ? "Syncing audio…" : "Sync audio to this Mac", systemImage: "arrow.down.doc") {
                    onSyncToLocal()
                }
                .disabled(isSyncingToLocal)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.syncToLocalButton)
            } else {
                Button("Open local session", systemImage: "folder") {
                    onRevealLocalSession()
                }
                .accessibilityIdentifier(AccessibilityIDs.Cloud.revealLocalSessionButton)
            }

            if let recordingWebURL {
                Button("Open in browser", systemImage: "arrow.up.right.square") {
                    NSWorkspace.shared.open(recordingWebURL)
                }
                .accessibilityIdentifier(AccessibilityIDs.Cloud.openRecordingInBrowserButton)
            }

            Divider()

            Button("Copy transcript", systemImage: "doc.on.doc", action: copyVisibleTranscript)
                .disabled(visibleTranscript?.text.isEmpty != false)
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
                Button(processingAction == action ? action.busyTitle : action.title(hasExistingTranscript: recording.activeTranscriptId != nil), systemImage: action.systemImage) {
                    if recording.activeTranscriptId != nil {
                        presentRetranscribeContextPopover()
                    } else {
                        onProcessRecording(action)
                    }
                }
                .disabled(isProcessingActionDisabled(action))
                .recappiTooltip(processingHelpText(for: action))
                .accessibilityIdentifier(action.accessibilityIdentifier)
            }

            Button("Previous versions…", systemImage: "clock.arrow.circlepath") {
                isShowingTranscriptVersions = true
            }
            .disabled(!hasPreviousTranscriptVersions)
            .recappiTooltip(hasPreviousTranscriptVersions ? "View earlier transcript versions" : "No previous transcript versions")
            .accessibilityIdentifier(AccessibilityIDs.Cloud.previousVersionsButton)

            Divider()

            Button("Delete recording", systemImage: "trash", role: .destructive, action: onDelete)
                .disabled(isDeleting)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.deleteButton)
        } label: {
            Label("More actions", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .recappiTooltip("More actions")
        .popover(isPresented: $isShowingRetranscribeContext, arrowEdge: .top) {
            retranscribeContextPopover
        }
        .accessibilityIdentifier(AccessibilityIDs.Cloud.moreActionsButton)
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
                Divider().overlay(Palette.borderHairline)

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

    private var retranscribeContextPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Re-Transcribe")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dtLabel)
                Text("Choose the scene and optional prompt before starting a fresh cloud pass.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Menu {
                    ForEach(RecordingSceneTemplate.allCases) { option in
                        Button {
                            retranscribeSceneDraft = option.rawValue
                        } label: {
                            Label(option.title, systemImage: option == retranscribeScene ? "checkmark" : "")
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Scene")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.dtLabelTertiary)
                        Text(retranscribeScene.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.dtLabel)
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundStyle(Color.dtLabelTertiary)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                            .fill(Palette.surfaceCardSubtle)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                            .strokeBorder(Palette.borderHairline, lineWidth: 0.6)
                    )
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text("Prompt")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(Color.dtLabel)
                        Text("Optional")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.dtLabelTertiary)
                    }

                    promptTextEditor(
                        text: $retranscribePromptDraft,
                        height: 80
                    )
                }
                .frame(height: 104, alignment: .topLeading)
            }

            HStack(spacing: 8) {
                Button("Cancel") {
                    isShowingRetranscribeContext = false
                }
                .buttonStyle(PanelPushButtonStyle())

                Button(processingAction == .transcriptAndSummary ? "Processing…" : "Re-Transcribe") {
                    confirmRetranscribeContext()
                }
                .buttonStyle(PanelPushButtonStyle(primary: true))
                .disabled(isProcessingActionDisabled(.transcriptAndSummary))
                .accessibilityIdentifier(AccessibilityIDs.Cloud.confirmRetranscribeButton)
            }
        }
        .padding(14)
        .frame(width: 300, height: 252, alignment: .topLeading)
        .background(DT.recordingShell)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.retranscribeContextPopover)
    }

    private func promptTextEditor(text: Binding<String>, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: text)
                .font(.system(size: 11.5))
                .foregroundStyle(Color.dtLabel)
                .scrollContentBackground(.hidden)
                .padding(7)

            if text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Add names, terms, or goals to improve summary")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .background(
            RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                .fill(Palette.surfaceCardSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                .strokeBorder(Palette.borderHairline, lineWidth: 0.6)
        )
        .accessibilityIdentifier(AccessibilityIDs.Panel.promptField)
    }

    private func presentRetranscribeContextPopover() {
        retranscribeSceneDraft = config.recordingSceneTemplate
        retranscribePromptDraft = config.recordingExtraPrompt
        isShowingRetranscribeContext = true
    }

    private func confirmRetranscribeContext() {
        config.recordingSceneTemplate = retranscribeSceneDraft
        config.recordingExtraPrompt = retranscribePromptDraft
        isShowingRetranscribeContext = false
        onProcessRecording(.transcriptAndSummary)
    }

    private func copyVisibleTranscript() {
        guard let text = visibleTranscript?.text, !text.isEmpty else { return }
        if isViewingHistoricalVersion {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } else {
            onCopyTranscript()
        }
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
        if hasNewerVersion && !isViewingHistoricalVersion {
            HStack(alignment: .center, spacing: 9) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(DT.systemBlue)
                    .frame(width: 2, height: 22)

                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DT.systemBlue)
                    .frame(width: 13)

                Text("✨ New transcript version is ready")
                    .font(.system(size: 10.8, weight: .semibold))
                    .foregroundStyle(Color.dtLabel)
                    .lineLimit(1)

                Spacer(minLength: 0)

                Button(action: acknowledgeNewerVersionWithoutSectionFlicker) {
                    Text("View")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(DT.systemBlue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("View newer cloud transcript version")
                .accessibilityIdentifier(AccessibilityIDs.Cloud.newerVersionRefreshButton)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 36, idealHeight: 36, maxHeight: 40, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .fill(DT.systemBlue.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                    .strokeBorder(DT.systemBlue.opacity(0.22), lineWidth: 0.6)
            )
            .accessibilityIdentifier(AccessibilityIDs.Cloud.newerVersionBanner)
        }
    }

    @ViewBuilder
    private var historicalVersionBanner: some View {
        if let selectedTranscriptVersionJob {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(DT.systemBlue.opacity(0.92))
                    .frame(width: 2, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Viewing previous version · \(selectedTranscriptVersionJob.versionTimestampText) · read-only")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dtLabel)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(selectedTranscriptVersionJob.versionDetailText)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.dtLabelSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button("Back to current") {
                    clearHistoricalVersionSelection()
                }
                .buttonStyle(.plain)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(DT.systemBlue)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.backToCurrentVersionButton)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityIdentifier(AccessibilityIDs.Cloud.historicalVersionBanner)
        }
    }

    private var transcriptVersionsSheet: some View {
        CloudTranscriptVersionsSheet(
            jobs: transcriptVersionJobs,
            activeTranscriptID: recording.activeTranscriptId,
            selectedJobID: selectedTranscriptVersionJobID,
            loadingJobID: transcriptVersionLoadingJobID,
            errorMessage: transcriptVersionErrorMessage,
            onSelect: selectTranscriptVersion(_:),
            onClose: { isShowingTranscriptVersions = false }
        )
    }

    private func processingProgressValue(for phase: ProcessingPhase) -> Double {
        switch phase.progressStyle {
        case .determinate(let progress):
            return max(0, min(1, progress))
        case .indeterminate(let base):
            return max(0, min(1, base))
        }
    }

    @ViewBuilder
    private var terminalJobStrip: some View {
        if let latestJob {
            switch latestJob.status {
            case .succeeded, .queued, .running:
                EmptyView()
            case .failed:
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
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transcript")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .tracking(0.45)
                if let visibleTranscript {
                    Text("\(visibleTranscript.displaySegmentRows.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.dtLabelTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(Palette.controlFillHover))
                }
                Spacer(minLength: 0)
                ZStack {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.72)
                        .opacity(isVisibleTranscriptLoading ? 1 : 0)
                }
                .frame(width: 16, height: 16)
            }

        }
    }

    private var speakerBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(visibleSpeakerIdentities) { speaker in
                    speakerChip(speaker)
                }
            }
            .padding(.horizontal, 1)
        }
        .accessibilityIdentifier(AccessibilityIDs.Cloud.speakerBar)
    }

    private func speakerChip(_ identity: CloudSpeakerIdentity) -> some View {
        Button {
            presentSpeakerRenamePopover(for: identity)
        } label: {
            HStack(spacing: 5) {
                speakerAvatar(identity, size: 17)
                Text(identity.displayName)
                    .font(CloudTypography.caption)
                    .foregroundStyle(Color.dtLabel)
                    .lineLimit(1)
            }
            .padding(.leading, 5)
            .padding(.trailing, 7)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Palette.controlFillHover)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Palette.borderHairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .popover(
            isPresented: Binding(
                get: { renamingSpeakerRawName == identity.rawName && renamingSpeakerAnchorID == nil },
                set: { isPresented in if !isPresented { dismissSpeakerRenamePopover() } }
            ),
            arrowEdge: .top
        ) {
            speakerRenamePopover
        }
        .recappiTooltip("Rename \(identity.displayName)")
        .accessibilityIdentifier(AccessibilityIDs.Cloud.speakerChipPrefix + identity.rawName)
    }

    private func speakerAvatar(_ identity: CloudSpeakerIdentity, size: CGFloat) -> some View {
        ZStack {
            Circle()
                .fill(Palette.controlFillPress)
            Text(identity.emoji)
                .font(.system(size: size * 0.52))
        }
        .frame(width: size, height: size)
        .overlay(
            Circle()
                .strokeBorder(Palette.borderHairline, lineWidth: 0.7)
        )
    }

    private func presentSpeakerRenamePopover(for identity: CloudSpeakerIdentity, anchorID: String? = nil) {
        speakerRenameDraft = identity.displayName
        speakerNoteDraft = identity.note ?? ""
        speakerEmojiDraft = identity.emoji
        renamingSpeakerAnchorID = anchorID
        renamingSpeakerRawName = identity.rawName
    }

    private var speakerRenamePopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let rawName = renamingSpeakerRawName,
                   let identity = speakerIdentity(for: rawName) {
                    speakerAvatar(identity, size: 28)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Rename speaker")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.dtLabel)
                    Text("Applies to every matching segment in this meeting.")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(Color.dtLabelTertiary)
                }
            }

            HStack(spacing: 6) {
                ForEach(CloudSpeakerIdentity.emojiChoices, id: \.self) { emoji in
                    Button {
                        speakerEmojiDraft = emoji
                    } label: {
                        Text(emoji)
                            .font(.system(size: 14))
                            .frame(width: 24, height: 24)
                            .background(
                                Circle()
                                    .fill(speakerEmojiDraft == emoji ? DT.appAccent.opacity(0.16) : Palette.controlFillHover)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Speaker name", text: $speakerRenameDraft)
                    .accessibilityIdentifier(AccessibilityIDs.Cloud.speakerRenameNameField)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .frame(height: 30)
                    .background(
                        RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                            .fill(Palette.surfaceCardSubtle)
                    )

                TextField("Add note (optional)", text: $speakerNoteDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: DT.R.control, style: .continuous)
                            .fill(Palette.surfaceCardSubtle)
                    )
            }

            HStack(spacing: 8) {
                Label("Apply to all \(renamingSpeakerRawName ?? "speaker") segments", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(DT.appAccent)
                Spacer(minLength: 0)
                Button("Cancel") {
                    dismissSpeakerRenamePopover()
                }
                .buttonStyle(PanelPushButtonStyle())
                Button("Save") {
                    saveSpeakerRename()
                }
                .buttonStyle(PanelPushButtonStyle(primary: true))
                .accessibilityIdentifier(AccessibilityIDs.Cloud.speakerRenameSaveButton)
            }
        }
        .padding(14)
        .frame(width: 348, alignment: .leading)
        .background(DT.recordingShell)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.speakerRenamePopover)
    }

    private func dismissSpeakerRenamePopover() {
        renamingSpeakerRawName = nil
        renamingSpeakerAnchorID = nil
    }

    private func saveSpeakerRename() {
        guard let rawName = renamingSpeakerRawName else { return }
        let normalizedName = speakerRenameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedEmoji = speakerEmojiDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedNote = speakerNoteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let speakerID = CloudSpeakerModel.speakerID(forRawName: rawName)
        speakerOverrides[speakerID] = CloudSpeakerDisplayOverride(
            displayName: normalizedName.isEmpty ? rawName : normalizedName,
            emoji: normalizedEmoji.isEmpty ? CloudSpeakerIdentity.defaultEmoji(at: 0) : normalizedEmoji,
            note: normalizedNote.isEmpty ? nil : normalizedNote
        )
        dismissSpeakerRenamePopover()
    }

    private var transcriptDurationSeconds: Double? {
        let maxEndMs = visibleTranscript?.segments.compactMap(\.endMs).max()
        guard let maxEndMs, maxEndMs > 0 else { return nil }
        return Double(maxEndMs) / 1000.0
    }

    private var bottomPlaybackBar: some View {
        let isViewingLoadedAudio = audioPlayer.currentRecordingID == recording.id
        let fallbackDuration = max(recording.durationSeconds ?? 0, transcriptDurationSeconds ?? 0)
        let displayDuration = isViewingLoadedAudio ? max(audioPlayer.duration, fallbackDuration) : fallbackDuration
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
            onSyncToLocal: onSyncToLocal,
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
        let seconds = max(0, Double(milliseconds) / 1000.0)
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
        loadPlaybackAudio(url: resolvedURL)
    }

    private func loadPlaybackAudio(url: URL?) {
        audioPlayer.load(
            recordingID: recording.id,
            url: url,
            title: recording.presentationTitle,
            artwork: recording.nowPlayingArtwork
        )
    }

    private func computeSegmentRowsWithPerfLogging() -> [CloudTranscriptSegmentDisplayRow] {
        let segmentCount = visibleTranscript?.segments.count ?? 0
        let rows = PerfLog.measure("displaySegmentRows", extra: "segments=\(segmentCount)") {
            visibleTranscript?.displaySegmentRows ?? []
        }
        PerfLog.event("transcriptCard.render", extra: "rows=\(rows.count)")
        PerfLog.end("select.until.firstRender", extra: "rows=\(rows.count)")
        return rows
    }

    /// Live captions to show in place of a not-yet-ready transcript. `nil`
    /// when the reader found nothing readable for this recording's linked
    /// session, so the existing empty/placeholder states still apply.
    private var liveCaptionPreviewTranscript: LiveCaptionTranscript? {
        guard let transcript = liveCaptionTranscriptState.transcript,
              !transcript.lines.isEmpty else { return nil }
        return transcript
    }

    @ViewBuilder
    private var transcriptCard: some View {
        let segmentRows = computeSegmentRowsWithPerfLogging()
        let activeSegmentID = activeSegmentID(in: segmentRows)
        Group {
            if !segmentRows.isEmpty {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(segmentRows) { row in
                        CloudTranscriptSegmentRow(
                            row: row,
                            isActive: row.id == activeSegmentID,
                            speaker: speakerIdentity(for: row.speaker),
                            activeHighlightNamespace: transcriptRowHighlightNamespace,
                            onSpeakerSelect: {
                                if let identity = speakerIdentity(for: row.speaker) {
                                    presentSpeakerRenamePopover(for: identity, anchorID: row.id)
                                }
                            },
                            onSelect: { jumpToSegment(row) },
                            renamingSpeakerRawName: $renamingSpeakerRawName,
                            renamingSpeakerAnchorID: $renamingSpeakerAnchorID,
                            renamePopover: { speakerRenamePopover }
                        )
                        .id(row.id)
                    }
                }
                .animation(DT.motionAware(DT.easeSpring(0.20)), value: activeSegmentID)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.transcriptText)
            } else if !isViewingHistoricalVersion, let liveTranscript = liveCaptionPreviewTranscript {
                // No official transcript yet — bridge the transcribing wait
                // (and local-only recordings) with the captions captured live
                // during recording. Replaced by the real transcript above once
                // its segment rows arrive.
                CloudDetailLiveCaptionsPreview(
                    transcript: liveTranscript,
                    isProcessing: isTranscriptGenerationProcessing
                )
            } else if shouldShowTranscriptGenerationEmptyState {
                transcriptGenerationEmptyState(showsAction: false, minHeight: 280)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Palette.surfaceCardSubtle)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Palette.borderHairline, lineWidth: 1)
                    )
            } else {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.dtLabelTertiary)
                        .frame(width: 18, height: 18)

                    Text(transcriptPlaceholderText)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.dtLabelSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    if recording.activeTranscriptId != nil {
                        Button("Load transcript") {
                            onLoadTranscript()
                        }
                        .buttonStyle(PanelPushButtonStyle())
                        .frame(width: 126)
                        .disabled(isVisibleTranscriptLoading)
                        .accessibilityIdentifier(AccessibilityIDs.Cloud.loadTranscriptButton)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.surfaceCardSubtle)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Palette.borderHairline, lineWidth: 1)
                )
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: segmentRows.isEmpty ? nil : 200, alignment: .topLeading)
    }

    private func activeSegmentID(in rows: [CloudTranscriptSegmentDisplayRow]) -> String? {
        guard audioPlayer.currentRecordingID == recording.id else { return pinnedSegmentID }
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

    private var transcriptGenerationIconName: String {
        if isTranscriptGenerationProcessing {
            return "clock"
        }
        if recording.activeTranscriptId == nil {
            return "text.badge.plus"
        }
        return "arrow.triangle.2.circlepath"
    }

    private var transcriptGenerationTitle: String {
        if isTranscriptGenerationProcessing {
            return "Transcription is in progress"
        }
        if recording.activeTranscriptId == nil {
            return "No transcript yet"
        }
        return "Transcript needs to be regenerated"
    }

    private var transcriptGenerationDescription: String {
        if let processingPhase {
            return "\(processingPhase.detail). Transcript and summary will appear here when processing finishes."
        }
        if processingAction == .transcriptAndSummary {
            return "Recappi is uploading or starting cloud processing. Transcript and summary will appear here when it finishes."
        }
        if latestJob?.status.isActive == true {
            return "Transcript and summary will appear here when processing finishes."
        }
        if let visibleTranscriptErrorMessage, !isTranscriptUnavailableMessage {
            return visibleTranscriptErrorMessage
        }
        if recording.activeTranscriptId == nil {
            return "Start transcription to generate transcript, summary, and speaker labels."
        }
        return "The saved transcript is unavailable. Re-run transcription to rebuild it."
    }

    private var transcriptGenerationActionTitle: String {
        recording.activeTranscriptId == nil
            ? CloudRecordingProcessingAction.transcriptAndSummary.title(hasExistingTranscript: false)
            : "Re-Transcribe"
    }

    @ViewBuilder
    private func transcriptGenerationEmptyState(showsAction: Bool, minHeight: CGFloat) -> some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Palette.surfaceCardSubtle)
                    .frame(width: 44, height: 44)

                Image(systemName: transcriptGenerationIconName)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .frame(width: 22, height: 22)
            }
            .overlay(
                Circle()
                    .strokeBorder(Palette.borderHairline, lineWidth: 0.6)
            )

            VStack(spacing: 5) {
                Text(transcriptGenerationTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.dtLabel)

                Text(transcriptGenerationDescription)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 440)
            }

            if shouldShowProcessingRail {
                processingProgressRail
                    .padding(.top, 2)
            }

            if !isTranscriptGenerationProcessing, showsAction {
                Button(transcriptGenerationActionTitle) {
                    if recording.activeTranscriptId == nil {
                        onProcessRecording(.transcriptAndSummary)
                    } else {
                        presentRetranscribeContextPopover()
                    }
                }
                .buttonStyle(PanelPushButtonStyle(primary: recording.activeTranscriptId == nil))
                .frame(width: recording.activeTranscriptId == nil ? 156 : 126)
                .disabled(isProcessingActionDisabled(.transcriptAndSummary))
                .accessibilityIdentifier(AccessibilityIDs.Cloud.retranscribeButton)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 32)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .center)
    }

    private var shouldShowProcessingRail: Bool {
        processingPhase != nil || processingAction == .transcriptAndSummary
    }

    private var processingProgressRail: some View {
        GeometryReader { geometry in
            let progress = max(0, min(1, inlineProcessingProgressValue))
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Palette.controlFillHover)

                Capsule(style: .continuous)
                    .fill(DT.statusUploading.opacity(0.78))
                    .frame(width: geometry.size.width * progress)
            }
        }
        .frame(width: 190, height: 2.5)
        .transaction { transaction in
            transaction.animation = nil
        }
        .accessibilityIdentifier(AccessibilityIDs.Cloud.processingStatus)
    }

    private var inlineProcessingProgressValue: Double {
        if let processingPhase {
            return processingProgressValue(for: processingPhase)
        }
        if latestJob?.status.isActive == true {
            return 0.84
        }
        return 0.12
    }

    private var transcriptPlaceholderText: String {
        if isVisibleTranscriptLoading {
            return "Loading transcript…"
        }
        return visibleTranscriptErrorMessage ?? "Segments are not available for this recording yet."
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

private struct CloudSpeakerIdentity: Identifiable {
    let speakerID: String
    let rawName: String
    let displayName: String
    let emoji: String
    let color: Color
    let note: String?

    var id: String { speakerID }

    static let emojiChoices = ["🎤", "🎧", "📻", "👤", "💬", "✨"]

    static func defaultEmoji(at index: Int) -> String {
        emojiChoices[index % emojiChoices.count]
    }

    static func defaultColor(at index: Int) -> Color {
        let colors: [Color] = [
            Color(red: 0.64, green: 0.52, blue: 0.96),
            Color(red: 0.38, green: 0.57, blue: 0.92),
            Color(red: 0.36, green: 0.72, blue: 0.56),
            Color(red: 0.84, green: 0.58, blue: 0.82),
            Color(red: 0.82, green: 0.67, blue: 0.39),
            Color(red: 0.62, green: 0.65, blue: 0.72),
        ]
        return colors[index % colors.count]
    }
}

private enum CloudSearchResultSource: Equatable {
    case transcript
    case summary

    init(_ indexedSource: CloudIndexedSearchSource) {
        switch indexedSource {
        case .transcript:
            self = .transcript
        case .summary:
            self = .summary
        }
    }

    var title: String {
        switch self {
        case .transcript:
            "Verbatim"
        case .summary:
            "Notes"
        }
    }

    var systemImage: String {
        switch self {
        case .transcript:
            "text.quote"
        case .summary:
            "note.text"
        }
    }

    var accent: Color {
        switch self {
        case .transcript:
            DT.appAccent
        case .summary:
            DT.appAccentSoft
        }
    }
}

private struct CloudSearchResult: Identifiable {
    let id: String
    let recordingID: String
    let recordingTitle: String
    let source: CloudSearchResultSource
    let sectionBreadcrumb: String
    let marker: String?
    let text: String
    let speaker: CloudSpeakerIdentity?
    let targetSegmentID: String?
    let isCurrentRecording: Bool

    var searchableText: String {
        [
            recordingTitle,
            source.title,
            sectionBreadcrumb,
            marker,
            text,
            speaker?.rawName,
            speaker?.displayName,
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }
}

private struct CloudSearchResultRow: View {
    let result: CloudSearchResult
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 11) {
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(stripeColor.opacity(result.source == .summary ? 0.55 : 0.88))
                    .frame(width: 4)
                    .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        sourceBadge

                        Text(result.recordingTitle)
                            .font(CloudTypography.label)
                            .foregroundStyle(Color.dtLabel)
                            .lineLimit(1)

                        Text(result.sectionBreadcrumb)
                            .font(CloudTypography.caption)
                            .foregroundStyle(Color.dtLabelSecondary)
                            .lineLimit(1)

                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 7) {
                        if let speaker = result.speaker {
                            HStack(spacing: 4) {
                                Text(speaker.emoji)
                                    .font(.system(size: 10))
                                Text(speaker.displayName)
                                    .font(CloudTypography.caption)
                            }
                            .foregroundStyle(Color.dtLabelSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule(style: .continuous).fill(Palette.controlFillHover))
                        }

                        if let marker = result.marker {
                            Text(marker)
                                .font(CloudTypography.captionMono)
                                .foregroundStyle(Color.dtLabelSecondary)
                        }

                        if !result.isCurrentRecording {
                            Text("Different recording")
                                .font(CloudTypography.caption)
                                .foregroundStyle(Color.dtLabelSecondary)
                        }

                        Spacer(minLength: 0)
                    }

                    Text(result.text)
                        .font(CloudTypography.body)
                        .foregroundStyle(Color.dtLabel)
                        .lineSpacing(2)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Palette.surfaceCardSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Palette.borderHairline, lineWidth: 0.7)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var stripeColor: Color {
        switch result.source {
        case .transcript:
            result.speaker?.color ?? result.source.accent
        case .summary:
            Color.dtLabelTertiary
        }
    }

    private var sourceBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: result.source.systemImage)
                .font(.system(size: 9, weight: .medium))
            Text(result.source.title)
                .font(CloudTypography.caption)
        }
        .foregroundStyle(Color.dtLabelTertiary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2.5)
    }
}

private struct CloudTranscriptSegmentRow<PopoverContent: View>: View {
    let row: CloudTranscriptSegmentDisplayRow
    let isActive: Bool
    let speaker: CloudSpeakerIdentity?
    let activeHighlightNamespace: Namespace.ID
    let onSpeakerSelect: () -> Void
    let onSelect: () -> Void
    @Binding var renamingSpeakerRawName: String?
    @Binding var renamingSpeakerAnchorID: String?
    let renamePopover: () -> PopoverContent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let speaker {
                    Button(action: onSpeakerSelect) {
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(speaker.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.dtLabelSecondary)
                                .lineLimit(1)

                            Image(systemName: "chevron.down")
                                .font(.system(size: 7, weight: .semibold))
                                .foregroundStyle(Color.dtLabelTertiary)
                                .baselineOffset(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .recappiTooltip("Rename \(speaker.displayName)")
                    .accessibilityIdentifier(AccessibilityIDs.Cloud.speakerNameButtonPrefix + speaker.rawName)
                    .accessibilityLabel("Speaker \(speaker.displayName)")
                    .accessibilityHint("Rename speaker")
                    .popover(
                        isPresented: Binding(
                            get: {
                                renamingSpeakerRawName == speaker.rawName
                                    && renamingSpeakerAnchorID == row.id
                            },
                            set: { isPresented in
                                guard !isPresented else { return }
                                if renamingSpeakerRawName == speaker.rawName,
                                   renamingSpeakerAnchorID == row.id {
                                    renamingSpeakerRawName = nil
                                    renamingSpeakerAnchorID = nil
                                }
                            }
                        ),
                        arrowEdge: .top
                    ) {
                        renamePopover()
                    }
                }

                Text(row.marker)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .lineLimit(1)
            }

            Text(row.text)
                .font(.body)
                .foregroundStyle(Color.dtLabel)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.transcriptSegmentTextPrefix + row.id)
                .accessibilityValue(isActive ? "selected" : "not selected")
                .accessibilityAddTraits(isActive ? .isSelected : [])
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            CloudActivePlaybackRowHighlight(
                isActive: isActive,
                namespace: activeHighlightNamespace,
                id: "transcript-active-row"
            )
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

private struct CloudActivePlaybackRowHighlight: View {
    let isActive: Bool
    let namespace: Namespace.ID
    let id: String

    var body: some View {
        ZStack {
            if isActive {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.dtLabel.opacity(0.045))
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(Palette.borderHairline.opacity(0.55), lineWidth: 0.5)
                    }
                    .matchedGeometryEffect(id: id, in: namespace, properties: .frame)
                    .transition(.opacity)
            }
        }
    }
}

private struct CloudTranscriptVersionsSheet: View {
    let jobs: [TranscriptionJob]
    let activeTranscriptID: String?
    let selectedJobID: String?
    let loadingJobID: String?
    let errorMessage: String?
    let onSelect: (TranscriptionJob) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Transcript versions")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.dtLabel)
                    Text("Open an earlier transcript in read-only mode.")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.dtLabelSecondary)
                }

                Spacer(minLength: 0)

                Button("Close", action: onClose)
                    .buttonStyle(PanelPushButtonStyle())
            }

            if let errorMessage {
                HStack(spacing: 7) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(DT.systemOrange)
                    Text(errorMessage)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.dtLabelSecondary)
                        .lineLimit(2)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DT.systemOrange.opacity(0.08))
                )
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 7) {
                    ForEach(jobs, id: \.id) { job in
                        Button {
                            onSelect(job)
                        } label: {
                            CloudTranscriptVersionRow(
                                job: job,
                                isCurrent: job.transcriptId == activeTranscriptID,
                                isSelected: job.id == selectedJobID,
                                isLoading: job.id == loadingJobID
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(AccessibilityIDs.Cloud.transcriptVersionRowPrefix + job.id)
                    }
                }
                .padding(.trailing, 2)
            }
            .frame(maxHeight: 248)
        }
        .padding(16)
        .frame(width: 410, height: 340, alignment: .topLeading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityIdentifier(AccessibilityIDs.Cloud.transcriptVersionsSheet)
    }
}

private struct CloudTranscriptVersionRow: View {
    let job: TranscriptionJob
    let isCurrent: Bool
    let isSelected: Bool
    let isLoading: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isCurrent {
                        Text("Current")
                            .font(CloudTypography.caption)
                            .foregroundStyle(Color.black.opacity(0.82))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule(style: .continuous).fill(DT.waveformLit.opacity(0.92)))
                    }

                    Text(job.versionTimestampText)
                        .font(CloudTypography.caption)
                        .foregroundStyle(Color.dtLabel)
                        .lineLimit(1)
                }

                Text(job.versionDetailText)
                    .font(CloudTypography.caption)
                    .foregroundStyle(Color.dtLabelSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let promptPreview = job.promptPreviewText {
                    Text("Prompt: \(promptPreview)")
                        .font(CloudTypography.caption)
                        .foregroundStyle(Color.dtLabelTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.68)
            } else {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "chevron.right")
                    .font(CloudTypography.caption)
                    .foregroundStyle(Color.dtLabelTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Palette.controlFillPress : Palette.surfaceCardSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.borderHairline, lineWidth: 0.7)
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private extension TranscriptionJob {
    var versionTimestampText: String {
        guard let timestamp = finishedAt ?? startedAt ?? enqueuedAt else {
            return "Unknown date"
        }
        let seconds = timestamp > 10_000_000_000 ? Double(timestamp) / 1000.0 : Double(timestamp)
        return Self.versionDateFormatter.string(from: Date(timeIntervalSince1970: seconds))
    }

    var versionDetailText: String {
        let trimmedModel = providerModelText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedModel.isEmpty ? "Cloud transcription" : trimmedModel
    }

    var promptPreviewText: String? {
        guard let prompt else { return nil }
        let compact = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !compact.isEmpty else { return nil }
        if compact.count <= 74 {
            return compact
        }
        return String(compact.prefix(71)) + "…"
    }

    private static let versionDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
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
