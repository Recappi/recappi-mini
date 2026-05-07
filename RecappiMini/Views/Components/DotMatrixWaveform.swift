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
    let levels: [Float]

    private let rows: Int = 5

    var body: some View {
        Canvas { ctx, size in
            let cols = levels.count
            guard cols > 0 else { return }

            let colStep = size.width / CGFloat(cols)
            let rowStep = size.height / CGFloat(rows)
            let dotSize = min(colStep, rowStep) * 0.6
            let litRows = DotMatrixWaveformModel.litRowCounts(for: levels, rows: rows)

            for column in 0..<cols {
                let lit = litRows[column]
                let firstLit = rows - lit

                for row in 0..<rows {
                    let x = CGFloat(column) * colStep + (colStep - dotSize) / 2
                    let y = CGFloat(row) * rowStep + (rowStep - dotSize) / 2
                    let rect = CGRect(x: x, y: y, width: dotSize, height: dotSize)
                    let color: Color = row >= firstLit
                        ? DT.waveformLit
                        : DT.waveformUnlit
                    ctx.fill(Path(ellipseIn: rect), with: .color(color))
                }
            }
        }
        .animation(.easeOut(duration: 0.08), value: levels)
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
