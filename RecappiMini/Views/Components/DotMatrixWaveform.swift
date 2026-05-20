import SwiftUI

/// Same dot-matrix shell as the original recording UI, but the columns now
/// represent fixed frequency buckets instead of a rolling timeline.
enum DotMatrixWaveformModel {
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
}

struct DotMatrixWaveform: View {
    @Environment(\.colorScheme) private var colorScheme

    let levels: [Float]
    var litColor: Color?
    var unlitColor: Color?

    @State private var displayedLevels: [Float] = []

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

            for column in 0..<cols {
                let lit = litRows[column]
                let firstLit = rows - lit

                for row in 0..<rows {
                    let x = CGFloat(column) * colStep + (colStep - dotSize) / 2
                    let y = CGFloat(row) * rowStep + (rowStep - dotSize) / 2
                    let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
                    let isLit = row >= firstLit
                    let color = isLit ? resolvedLitColor : resolvedUnlitColor
                    ctx.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .onAppear {
            displayedLevels = levels
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
        RecordingPerformanceProbe.shared.noteWaveformUpdate(releasing: false)
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            displayedLevels = newLevels
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
