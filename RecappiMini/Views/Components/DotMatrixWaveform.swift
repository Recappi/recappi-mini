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

    static func litRowOpacities(for levels: [Float], rows: Int = 5) -> [[Float]] {
        guard rows > 0 else { return Array(repeating: [], count: levels.count) }
        return levels.map { rawLevel in
            let amplitude = max(0, min(1, rawLevel))
            guard amplitude > 0.028 else { return Array(repeating: 0, count: rows) }
            let perceptualHeight = max(1, pow(amplitude, 0.58) * Float(rows))
            return (0..<rows).map { row in
                let rowFromBottom = Float(rows - row - 1)
                let fill = perceptualHeight - rowFromBottom
                guard fill > 0 else { return 0 }
                guard fill < 1 else { return 1 }
                return smoothstep(fill)
            }
        }
    }

    private static func smoothstep(_ value: Float) -> Float {
        let t = max(0, min(1, value))
        return t * t * (3 - 2 * t)
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
            let litOpacities = DotMatrixWaveformModel.litRowOpacities(for: renderLevels, rows: rows)

            for column in 0..<cols {
                for row in 0..<rows {
                    let x = CGFloat(column) * colStep + (colStep - dotSize) / 2
                    let y = CGFloat(row) * rowStep + (rowStep - dotSize) / 2
                    let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
                    let path = Path(ellipseIn: rect)
                    ctx.fill(path, with: .color(resolvedUnlitColor))

                    let opacity = litOpacities[column][row]
                    if opacity > 0 {
                        // Overlay the lit color with fractional coverage at
                        // the waveform's top edge. Fully covered lower dots
                        // stay crisp; only the boundary row fades into the
                        // unlit matrix so the shape stops reading as binary.
                        ctx.fill(path, with: .color(resolvedLitColor.opacity(Double(opacity))))
                    }
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
