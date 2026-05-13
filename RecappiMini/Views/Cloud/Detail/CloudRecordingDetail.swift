import AppKit
import SwiftUI

struct CloudRecordingDetail: View {
    @StateObject private var detailWaveform = CloudRecordingWaveformPreview()
    @ObservedObject private var config = AppConfig.shared
    @State private var pendingAutoplayAfterPrepare = false
    @State private var pendingSeekAfterPrepare: Double?
    @State private var pinnedSegmentID: String?
    @State private var pendingPinnedSegmentIDAfterPrepare: String?
    @State private var isShowingRecordingInfo = false
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

    let recording: CloudRecording
    let recordingWebURL: URL?
    let latestJob: TranscriptionJob?
    let transcriptionJobs: [TranscriptionJob]
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
    let onLoadTranscriptVersion: @MainActor (String) async throws -> TranscriptResponse

    var body: some View {
        readerPane
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { detailToolbarContent }
        .sheet(isPresented: $isShowingTranscriptVersions) {
            transcriptVersionsSheet
        }
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
            selectedTranscriptVersionJobID = nil
            transcriptVersionCache.removeAll()
            transcriptVersionLoadingJobID = nil
            transcriptVersionErrorMessage = nil
            activeDetailSection = .summary
            refreshPlayerMetadataIfNeeded()
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
                detailHeader
            } latestJob: {
                latestJobStrip
            } newerVersion: {
                newerVersionStrip
            } navigation: {
                detailNavigationRow
            }
            .animation(DT.motionAware(DT.ease(0.20)), value: latestJob?.status)
            .animation(DT.motionAware(DT.ease(0.20)), value: hasNewerVersion)

            if isViewingHistoricalVersion {
                historicalVersionBanner
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if shouldShowProcessingContextStrip {
                processingContextStrip
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }

            Divider().overlay(Palette.borderHairline)

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
                segmentsHeader
            } transcriptCard: {
                transcriptCard
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // Empty inset just reserves layout space equal to the
                // capsule's footprint so the scrollable area can scroll
                // past the floating player.
                Color.clear.frame(height: floatingPlayerInset)
            }
        }
        .overlay(alignment: .bottom) {
            CloudDetailPlaybackSection {
                bottomPlaybackBar
            }
        }
        .animation(DT.motionAware(DT.ease(DT.Motion.elementPresence)), value: shouldShowProcessingContextStrip)
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

    private var isSummaryNavigationAvailable: Bool {
        hasSummarySection || visibleTranscript == nil || isVisibleTranscriptLoading
    }

    private var shouldShowProcessingContextStrip: Bool {
        guard !isViewingHistoricalVersion else { return false }
        guard latestJob?.status.isActive != true else { return false }
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
                isDisabled: !isSummaryNavigationAvailable
            )

            detailJumpSegment(
                title: "Timeline",
                systemImage: "clock",
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
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.controlFillHover)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Palette.borderHairline, lineWidth: 0.5)
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
                    .fill(isActive ? Palette.controlFillPress : Color.clear)
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
                        total: entries.count,
                        activeIndex: activeIndex
                    )
                }
            }
        }
    }

    /// Timeline tab content rendered between Summary and Transcript in the
    /// scroll view. Wraps the rail-style chapter list with a section header
    /// matching the visual rhythm of the transcript section so it reads as a
    /// distinct top-level destination, not an embedded Summary block.
    private var timelineSectionView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.dtLabelSecondary)
                Text("Timeline")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.dtLabel)
                Spacer(minLength: 0)
                Text("Chapters")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.dtLabelTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Palette.controlFillHover)
                    )
            }

            timelineChaptersBody()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.surfaceCardSubtle.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.borderHairline.opacity(0.5), lineWidth: 0.5)
        )
    }


    @ViewBuilder
    private func timelineChapterRow(
        _ entry: TimelineChapterDisplayEntry,
        index: Int,
        total: Int,
        activeIndex: Int?
    ) -> some View {
        let isActive = activeIndex == index
        let isPlayed = (activeIndex ?? -1) > index
        let isPast = isPlayed
        let isFuture = currentTimelinePlaybackMs != nil && (activeIndex ?? Int.max) < index && !isActive
        let isLast = index == total - 1

        let markerSize: CGFloat = isActive ? 14 : 10
        let railWidth: CGFloat = 2
        let activeAccent = DT.statusReady
        let pastAccent = DT.statusReady.opacity(0.6)
        let futureAccent = Palette.labelTertiary.opacity(0.35)

        Button {
            handlePlaybackSeek(Double(entry.startMs) / 1000.0)
        } label: {
            HStack(alignment: .top, spacing: 12) {
            // Rail column: marker + connector
                VStack(spacing: 0) {
                    ZStack {
                        Circle()
                            .fill(
                                isActive
                                    ? activeAccent
                                    : (isPast ? pastAccent : futureAccent)
                            )
                            .frame(width: markerSize, height: markerSize)

                        if isActive {
                            Circle()
                                .strokeBorder(activeAccent.opacity(0.35), lineWidth: 3)
                                .frame(width: markerSize + 8, height: markerSize + 8)
                        }
                    }
                    .frame(width: 22, height: 22)

                    if !isLast {
                        Rectangle()
                            .fill(
                                isPlayed || isActive
                                    ? pastAccent
                                    : futureAccent
                            )
                            .frame(width: railWidth)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(width: 22)

            // Content column
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.timeRange)
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(isActive ? activeAccent : (isFuture ? Color.dtLabelTertiary : activeAccent.opacity(0.85)))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(activeAccent.opacity(isActive ? 0.18 : (isFuture ? 0.05 : 0.10)))
                            )
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(activeAccent.opacity(isActive ? 0.30 : (isFuture ? 0.10 : 0.18)), lineWidth: 0.5)
                            )

                        Text(entry.title)
                            .font(.system(size: 13, weight: isActive ? .bold : .semibold))
                            .foregroundStyle(isFuture ? Color.dtLabelSecondary : Color.dtLabel)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)

                        Spacer(minLength: 0)
                    }
                    .padding(.top, isActive ? 3 : 4)

                    Text(entry.summary)
                        .font(.system(size: 12))
                        .foregroundStyle(isFuture ? Color.dtLabelTertiary : Color.dtLabelSecondary)
                        .lineSpacing(2.5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, isLast ? 0 : 14)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isActive ? activeAccent.opacity(0.045) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(isActive ? activeAccent.opacity(0.13) : Color.clear, lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
    }

    private var timelineEmptyState: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.dtLabelTertiary)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text("No timeline available")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.dtLabel)
                Text("Generate a new summary for this recording to create chapter markers.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.surfaceCardSubtle.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Palette.borderHairline.opacity(0.5), lineWidth: 0.5)
        )
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
            summarySectionBlock(title: "Notable quotes", systemImage: "quote.bubble", accent: Palette.labelTertiary) {
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
                .fill(Palette.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.borderHairline, lineWidth: 1)
        )
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
            || !recording.status.allowsTranscriptionRequest
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
        return action.helpText
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

            headerPlayButton
        }
    }

    /// Apple Music-style track-row play affordance. The bottom strip is
    /// now the steady-state now-playing surface; this button is the
    /// primary "start playing this recording" entry. Shows a prepare
    /// spinner while the audio is downloading.
    private var headerPlayButton: some View {
        let isViewingLoadedAudio = audioPlayer.currentRecordingID == recording.id
        let isPlaying = isViewingLoadedAudio && audioPlayer.isPlaying

        return Button(action: handlePlayPause) {
            ZStack {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 38, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .opacity(isPreparingPlaybackAudio ? 0 : 1)
                ProgressView()
                    .controlSize(.small)
                    .opacity(isPreparingPlaybackAudio ? 1 : 0)
            }
            .frame(width: 38, height: 38)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isPreparingPlaybackAudio)
        .help(isPlaying ? "Pause" : "Play recording")
        .accessibilityIdentifier(AccessibilityIDs.Cloud.headerPlayButton)
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
                .help("Choose processing scene")

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
                .help(processingHelpText(for: .transcriptAndSummary))
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
        ToolbarItemGroup(placement: .primaryAction) {
            toolbarLocalActionButton

            if let recordingWebURL {
                Button {
                    NSWorkspace.shared.open(recordingWebURL)
                } label: {
                    Label("Open in browser", systemImage: "arrow.up.right.square")
                }
                .help("Open in browser")
                .accessibilityIdentifier(AccessibilityIDs.Cloud.openRecordingInBrowserButton)
            }

            Button {
                isShowingRecordingInfo.toggle()
            } label: {
                Label("Recording details", systemImage: "info.circle")
            }
            .help(recordingInfoHelpText)
            .popover(isPresented: $isShowingRecordingInfo, arrowEdge: .top) {
                recordingInfoPopover
            }
            .accessibilityIdentifier(AccessibilityIDs.Cloud.recordingInfoButton)

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
        .help(localSessionURL == nil ? "Sync to local" : "Open local session")
        .accessibilityIdentifier(localSessionURL == nil ? AccessibilityIDs.Cloud.syncToLocalButton : AccessibilityIDs.Cloud.revealLocalSessionButton)
    }

    private var recordingActionsMenu: some View {
        Menu {
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
                .help(processingHelpText(for: action))
                .accessibilityIdentifier(action.accessibilityIdentifier)
            }

            Button("Previous versions…", systemImage: "clock.arrow.circlepath") {
                isShowingTranscriptVersions = true
            }
            .disabled(!hasPreviousTranscriptVersions)
            .help(hasPreviousTranscriptVersions ? "View earlier transcript versions" : "No previous transcript versions")
            .accessibilityIdentifier(AccessibilityIDs.Cloud.previousVersionsButton)

            Divider()

            Button("Delete recording", systemImage: "trash", role: .destructive, action: onDelete)
                .disabled(isDeleting)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.deleteButton)
        } label: {
            Label("More actions", systemImage: "ellipsis")
        }
        .menuIndicator(.hidden)
        .help("More actions")
        .popover(isPresented: $isShowingRetranscribeContext, arrowEdge: .top) {
            retranscribeContextPopover
        }
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
            .transition(.opacity.combined(with: .move(edge: .top)))
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
                .transition(.opacity.combined(with: .move(edge: .top)))
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
        audioPlayer.load(
            recordingID: recording.id,
            url: resolvedURL,
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

    @ViewBuilder
    private var transcriptCard: some View {
        let segmentRows = computeSegmentRowsWithPerfLogging()
        let activeSegmentID = activeSegmentID(in: segmentRows)
        Group {
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
                .textSelection(.enabled)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.transcriptText)
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
        .transaction { transaction in
            transaction.animation = nil
        }
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

private struct CloudTranscriptSegmentRow: View {
    let row: CloudTranscriptSegmentDisplayRow
    let isActive: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: 12) {
                Capsule(style: .continuous)
                    .fill(isActive ? DT.waveformLit.opacity(0.9) : Palette.controlFillHover)
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
                    .fill(isActive ? Palette.surfaceCardSubtleActive : Palette.surfaceCardSubtle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Palette.borderHairline, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(row.startMs == nil && row.endMs == nil ? "No timing for this segment" : "Jump audio to this segment")
        .disabled(row.startMs == nil && row.endMs == nil)
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
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(Color.black.opacity(0.82))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule(style: .continuous).fill(DT.waveformLit.opacity(0.92)))
                    }

                    Text(job.versionTimestampText)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.dtLabel)
                        .lineLimit(1)
                }

                Text(job.versionDetailText)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let promptPreview = job.promptPreviewText {
                    Text("Prompt: \(promptPreview)")
                        .font(.system(size: 10, weight: .medium))
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
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(isSelected ? DT.systemBlue : Color.dtLabelTertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? DT.systemBlue.opacity(0.10) : Palette.surfaceCardSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? DT.systemBlue.opacity(0.22) : Palette.borderHairline, lineWidth: 0.7)
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
