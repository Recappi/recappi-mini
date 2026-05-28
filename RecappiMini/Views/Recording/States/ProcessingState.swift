import SwiftUI

struct ProcessingState: View {
    let phase: ProcessingPhase
    var onClose: () -> Void
    @State private var spin = false
    @State private var shimmerPhase = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(DT.recordingLiveBlue, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.dtLabel)
                        .accessibilityIdentifier(AccessibilityIDs.Panel.processingTitle)
                    Text(step)
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(Color.dtLabelSecondary)
                        .accessibilityIdentifier(AccessibilityIDs.Panel.processingDetail)
                }

                Spacer(minLength: 0)

                Button(action: onClose) {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(PanelIconButtonStyle(size: 16, backdropAdaptiveForeground: true))
                .recappiTooltip("Hide panel and continue processing")
                .accessibilityIdentifier(AccessibilityIDs.Panel.closeButton)
            }

            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Palette.controlFillPress)
                        .frame(height: 3)

                    switch phase.progressStyle {
                    case .determinate(let progress):
                        Capsule()
                            .fill(DT.recordingLiveBlue)
                            .frame(width: width * max(0, min(1, progress)), height: 3)
                            .animation(.easeOut(duration: 0.25), value: progress)

                    case .indeterminate(let base):
                        let clampedBase = max(0, min(1, base))
                        let baseWidth = width * clampedBase
                        let remainingWidth = max(width - baseWidth, 0)
                        let segmentWidth = min(max(remainingWidth * 0.45, 26), max(remainingWidth, 26))

                        Capsule()
                            .fill(DT.recordingLiveBlue.opacity(0.85))
                            .frame(width: baseWidth, height: 3)
                            .animation(.easeOut(duration: 0.25), value: base)

                        if remainingWidth > 0 {
                            Capsule()
                                .fill(DT.recordingLiveBlue)
                                .frame(width: min(segmentWidth, remainingWidth), height: 3)
                                .offset(x: baseWidth + ((remainingWidth - min(segmentWidth, remainingWidth)) * (shimmerPhase ? 1 : 0)))
                                .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 1.1).repeatForever(autoreverses: true), value: shimmerPhase)
                        }
                    }
                }
            }
            .frame(height: 3)
            .onAppear { shimmerPhase = true }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    private var title: String {
        phase.title
    }

    private var step: String {
        phase.detail
    }
}
