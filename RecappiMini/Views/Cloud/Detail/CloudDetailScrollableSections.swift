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
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    switch activeDetailSection {
                    case .summary:
                        CloudDetailSummarySection(
                            isVisible: hasSummarySection,
                            offsetReader: { EmptyView() }
                        ) {
                            summary
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    case .timeline:
                        timeline
                            .id(CloudDetailSection.timeline)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    case .transcript:
                        CloudDetailTranscriptSection(
                            offsetReader: { EmptyView() },
                            header: { transcriptHeader },
                            card: { transcriptCard }
                        )
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .id(activeDetailSection)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .animation(DT.motionAware(DT.easeSpring(DT.Motion.cloudSectionSwap)), value: activeDetailSection)
            .coordinateSpace(name: "cloudDetailScroll")
            .onChange(of: activeSegmentID) { _, id in
                // Loading or switching recordings can make the active
                // segment move from nil to the first row before the user
                // has interacted with playback. Do not let that derived
                // state yank the detail scroll away from the top; only
                // auto-follow transcript rows while playback is advancing.
                guard activeDetailSection == .transcript,
                      isPlaybackActive,
                      let id else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
            .onChange(of: activeDetailSection) { _, section in
                guard section == .transcript,
                      isPlaybackActive,
                      let activeSegmentID else { return }
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(activeSegmentID, anchor: .center)
                    }
                }
            }
            .onChange(of: pendingScrollTarget) { _, target in
                guard let target else { return }
                withAnimation(DT.motionAware(DT.easeSpring(DT.Motion.cloudSectionSwap))) {
                    activeDetailSection = target
                }
                if target == .transcript,
                   isPlaybackActive,
                   let activeSegmentID {
                    DispatchQueue.main.async {
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(activeSegmentID, anchor: .center)
                        }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
                // Hold `pendingScrollTarget` past the scroll animation
                // duration so offset-driven updates cannot retoggle the
                // segmented control mid-flight.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    pendingScrollTarget = nil
                }
            }
            .onPreferenceChange(CloudDetailSectionOffsetPreferenceKey.self) { offsets in
                guard !offsets.isEmpty else { return }
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
