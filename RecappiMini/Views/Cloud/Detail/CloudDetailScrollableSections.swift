import SwiftUI

struct CloudDetailScrollableSections<Summary: View, Timeline: View, TranscriptHeader: View, TranscriptCard: View>: View {
    let hasSummarySection: Bool
    let activeSegmentID: String?
    let isPlaybackActive: Bool
    @Binding var pendingScrollTarget: CloudDetailSection?
    @Binding var activeDetailSection: CloudDetailSection
    let onUpdateOffsets: ([CloudDetailSection: CGFloat]) -> Void

    private let summary: Summary
    private let timeline: Timeline
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
        @ViewBuilder timeline: () -> Timeline,
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
        self.timeline = timeline()
        self.transcriptHeader = transcriptHeader()
        self.transcriptCard = transcriptCard()
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CloudDetailSectionScrollPane(
                section: .summary,
                isActive: activeDetailSection == .summary,
                activeSegmentID: activeSegmentID,
                isPlaybackActive: isPlaybackActive,
                pendingScrollTarget: $pendingScrollTarget,
                activeDetailSection: $activeDetailSection
            ) {
                CloudDetailSummarySection(
                    isVisible: hasSummarySection,
                    offsetReader: { EmptyView() }
                ) {
                    summary
                }
            }

            CloudDetailSectionScrollPane(
                section: .timeline,
                isActive: activeDetailSection == .timeline,
                activeSegmentID: activeSegmentID,
                isPlaybackActive: isPlaybackActive,
                pendingScrollTarget: $pendingScrollTarget,
                activeDetailSection: $activeDetailSection
            ) {
                timeline
                    .id(CloudDetailSection.timeline)
            }

            CloudDetailSectionScrollPane(
                section: .transcript,
                isActive: activeDetailSection == .transcript,
                activeSegmentID: activeSegmentID,
                isPlaybackActive: isPlaybackActive,
                pendingScrollTarget: $pendingScrollTarget,
                activeDetailSection: $activeDetailSection
            ) {
                CloudDetailTranscriptSection(
                    offsetReader: { EmptyView() },
                    header: { transcriptHeader },
                    card: { transcriptCard }
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(DT.motionAware(DT.easeSpring(DT.Motion.cloudSectionSwap)), value: activeDetailSection)
        .onChange(of: activeDetailSection) { _, section in
            DiagnosticsLog.event("cloud", "detail.section.changed section=\(section)")
        }
    }
}

private struct CloudDetailSectionScrollPane<Content: View>: View {
    let section: CloudDetailSection
    let isActive: Bool
    let activeSegmentID: String?
    let isPlaybackActive: Bool
    @Binding var pendingScrollTarget: CloudDetailSection?
    @Binding var activeDetailSection: CloudDetailSection

    private let content: Content

    init(
        section: CloudDetailSection,
        isActive: Bool,
        activeSegmentID: String?,
        isPlaybackActive: Bool,
        pendingScrollTarget: Binding<CloudDetailSection?>,
        activeDetailSection: Binding<CloudDetailSection>,
        @ViewBuilder content: () -> Content
    ) {
        self.section = section
        self.isActive = isActive
        self.activeSegmentID = activeSegmentID
        self.isPlaybackActive = isPlaybackActive
        self._pendingScrollTarget = pendingScrollTarget
        self._activeDetailSection = activeDetailSection
        self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    content
                }
                .id(section)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .zIndex(isActive ? 1 : 0)
            .onChange(of: activeSegmentID) { _, id in
                // Loading or switching recordings can make the active
                // segment move from nil to the first row before the user
                // has interacted with playback. Do not let that derived
                // state yank the detail scroll away from the top; only
                // auto-follow transcript rows while playback is advancing.
                guard section == .transcript,
                      isActive,
                      isPlaybackActive,
                      let id else { return }
                scrollToSegment(id, proxy: proxy)
            }
            .onChange(of: activeDetailSection) { _, activeSection in
                guard section == .transcript,
                      activeSection == .transcript,
                      isPlaybackActive,
                      let activeSegmentID else { return }
                DispatchQueue.main.async {
                    scrollToSegment(activeSegmentID, proxy: proxy)
                }
            }
            .onChange(of: pendingScrollTarget) { _, target in
                guard target == section else { return }
                withAnimation(DT.motionAware(DT.easeSpring(DT.Motion.cloudSectionSwap))) {
                    activeDetailSection = section
                }
                if section == .transcript,
                   isPlaybackActive,
                   let activeSegmentID {
                    DispatchQueue.main.async {
                        scrollToSegment(activeSegmentID, proxy: proxy)
                    }
                }
                // Hold `pendingScrollTarget` past the section fade so old
                // offset-driven callers cannot retoggle the segmented control
                // mid-flight. Each tab keeps its own ScrollView alive, so
                // switching tabs no longer shares or resets scroll offsets.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    guard pendingScrollTarget == section else { return }
                    pendingScrollTarget = nil
                }
            }
        }
    }

    private func scrollToSegment(_ id: String, proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.18)) {
            proxy.scrollTo(id, anchor: .center)
        }
    }
}
