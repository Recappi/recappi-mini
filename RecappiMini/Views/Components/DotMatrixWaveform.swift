import SwiftUI

/// Same dot-matrix shell as the original recording UI, but the columns now
/// represent fixed frequency buckets instead of a rolling timeline.
enum DotMatrixWaveformModel {
    struct ReleaseFrame: Equatable {
        var attack: [Float]
        var target: [Float]

        var needsRelease: Bool {
            zip(attack, target).contains { attackValue, targetValue in
                attackValue > targetValue + 0.0001
            }
        }
    }

    static func litRowCounts(for levels: [Float], rows: Int = 5) -> [Int] {
        guard rows > 0 else { return Array(repeating: 0, count: levels.count) }
        return levels.map { rawLevel in
            let amplitude = max(0, min(1, rawLevel))
            guard amplitude > 0.028 else { return 0 }
            // Traditional player visualizers exaggerate low-amplitude activity
            // so the whole spectrum feels alive instead of collapsing into the
            // bass bins. Keep that visual behavior while preserving stronger
            // peaks for the louder columns.
            let perceptual = pow(amplitude, 0.58)
            return max(1, min(rows, Int(ceil(perceptual * Float(rows)))))
        }
    }

    static func releaseFrame(displayed: [Float], incoming: [Float]) -> ReleaseFrame {
        let current = align(displayed, toCount: incoming.count)
        let target = align(incoming, toCount: incoming.count)
        let attack = zip(current, target).map { max($0, $1) }
        return ReleaseFrame(attack: attack, target: target)
    }

    private static func align(_ levels: [Float], toCount count: Int) -> [Float] {
        if levels.count == count { return levels }
        if levels.count > count { return Array(levels.suffix(count)) }
        return Array(repeating: 0, count: count - levels.count) + levels
    }
}

struct DotMatrixWaveform: View {
    @Environment(\.colorScheme) private var colorScheme

    let levels: [Float]
    var litColor: Color?
    var unlitColor: Color?

    @State private var displayedLevels: [Float] = []
    @State private var targetLevels: [Float] = []
    @State private var releaseOpacity = 0.0
    @State private var releaseAnimationID = 0

    private let rows: Int = 5

    var body: some View {
        Canvas { ctx, size in
            let renderLevels = displayedLevels.isEmpty ? levels : displayedLevels
            let cols = renderLevels.count
            guard cols > 0 else { return }

            let colStep = size.width / CGFloat(cols)
            let rowStep = size.height / CGFloat(rows)
            let dotSize = min(colStep, rowStep) * 0.6
            let litRows = DotMatrixWaveformModel.litRowCounts(for: renderLevels, rows: rows)
            let targetRows = DotMatrixWaveformModel.litRowCounts(
                for: targetLevels.isEmpty ? renderLevels : targetLevels,
                rows: rows
            )

            for column in 0..<cols {
                let lit = litRows[column]
                let targetLit = column < targetRows.count ? targetRows[column] : lit
                let firstLit = rows - lit
                let firstTargetLit = rows - targetLit

                for row in 0..<rows {
                    let x = CGFloat(column) * colStep + (colStep - dotSize) / 2
                    let y = CGFloat(row) * rowStep + (rowStep - dotSize) / 2
                    let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
                    let isLit = row >= firstLit
                    let isReleasing = isLit && row < firstTargetLit
                    let color: Color
                    if isReleasing {
                        let rowFade = Double(row + 1) / Double(rows)
                        color = resolvedLitColor.opacity(max(0.16, releaseOpacity * (0.52 + rowFade * 0.28)))
                    } else {
                        color = isLit ? resolvedLitColor : resolvedUnlitColor
                    }
                    ctx.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .onAppear {
            displayedLevels = levels
            targetLevels = levels
        }
        .onChange(of: levels) { _, newLevels in
            updateDisplayedLevels(to: newLevels)
        }
    }

    private var resolvedLitColor: Color {
        if let litColor {
            return litColor
        }

        return DT.waveformLit
    }

    private var resolvedUnlitColor: Color {
        if let unlitColor {
            return unlitColor
        }

        return colorScheme == .dark ? Color.white.opacity(0.20) : DT.waveformUnlit
    }

    private func updateDisplayedLevels(to newLevels: [Float]) {
        let frame = DotMatrixWaveformModel.releaseFrame(
            displayed: displayedLevels.isEmpty ? levels : displayedLevels,
            incoming: newLevels
        )

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            releaseAnimationID += 1
            displayedLevels = frame.attack
            targetLevels = frame.target
            releaseOpacity = frame.needsRelease ? 0.95 : 0
        }

        guard frame.needsRelease else { return }
        let animationID = releaseAnimationID
        DispatchQueue.main.async {
            Task { @MainActor in
                let frameCount = 18
                for step in 1...frameCount {
                    guard releaseAnimationID == animationID else { return }
                    try? await Task.sleep(nanoseconds: 22_000_000)

                    let t = Double(step) / Double(frameCount)
                    let eased = 1 - pow(1 - t, 2.8)
                    displayedLevels = zip(frame.attack, frame.target).map { attack, target in
                        attack + Float((Double(target - attack)) * eased)
                    }
                    releaseOpacity = 0.95 * (1 - eased)
                }

                guard releaseAnimationID == animationID else { return }
                displayedLevels = frame.target
                releaseOpacity = 0
            }
        }
    }
}

struct PulsingModifier: ViewModifier {
    @State private var pulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(pulsing ? 0.35 : 1)
            .animation(.easeInOut(duration: 1.4).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
