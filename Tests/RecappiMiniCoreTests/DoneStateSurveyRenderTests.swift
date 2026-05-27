import AppKit
import SwiftUI
import XCTest
@testable import RecappiMini

/// One-off render utility (not a real assertion). Produces a PNG that
/// stacks all nine `DoneCloudStatus` icons + labels using the real
/// `DoneState` row, mirrored across light and dark NSAppearance so a
/// reviewer can confirm both palettes read legibly. Mirrors the
/// production wiring (NSHostingView with overridden `appearance`) so the
/// dark column reflects what task #185's adaptive chrome will actually
/// render — not a SwiftUI-only colorScheme override that the underlying
/// `Palette.label*` tokens ignore.
///
/// Skipped by default. Run with `--filter DoneStateSurveyRenderTests`
/// after exporting `DONE_STATE_SURVEY_OUTPUT=/tmp/path.png`.
final class DoneStateSurveyRenderTests: XCTestCase {
    @MainActor
    func test_renderDoneStateSurvey() throws {
        guard let outputPath = ProcessInfo.processInfo.environment["DONE_STATE_SURVEY_OUTPUT"] else {
            throw XCTSkip("Set DONE_STATE_SURVEY_OUTPUT=/path/to.png to render survey")
        }

        let statuses: [DoneCloudStatus] = [
            .savedLocally,
            .uploading,
            .synced,
            .pending,
            .queued,
            .transcribing,
            .ready,
            .syncFailed,
            .transcriptionFailed,
        ]

        let result = RecordingResult(
            folderURL: FileManager.default.temporaryDirectory,
            transcript: nil,
            duration: 193
        )

        let columnWidth: CGFloat = 380
        let columnHeight: CGFloat = 28 + CGFloat(statuses.count) * 36
        let columnSize = NSSize(width: columnWidth, height: columnHeight)

        let lightImage = try Self.render(
            view: DoneStateSurveyColumn(
                title: "Light NSAppearance (system light + light backdrop)",
                titleColor: .black,
                backdrop: Color(white: 0.96),
                statuses: statuses,
                result: result
            ),
            appearance: NSAppearance(named: .aqua)!,
            size: columnSize
        )
        let darkImage = try Self.render(
            view: DoneStateSurveyColumn(
                title: "Dark NSAppearance (#185 adaptive: light system, dark backdrop)",
                titleColor: .white,
                backdrop: Color(white: 0.12),
                statuses: statuses,
                result: result
            ),
            appearance: NSAppearance(named: .darkAqua)!,
            size: columnSize
        )

        let gap: CGFloat = 24
        let composite = NSImage(size: NSSize(
            width: columnWidth * 2 + gap * 3,
            height: columnHeight + gap * 2
        ))
        composite.lockFocus()
        NSColor(white: 0.42, alpha: 1).setFill()
        NSRect(origin: .zero, size: composite.size).fill()
        lightImage.draw(at: NSPoint(x: gap, y: gap), from: .zero, operation: .copy, fraction: 1)
        darkImage.draw(at: NSPoint(x: gap * 2 + columnWidth, y: gap), from: .zero, operation: .copy, fraction: 1)
        composite.unlockFocus()

        guard
            let tiff = composite.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let png = bitmap.representation(using: .png, properties: [:])
        else {
            XCTFail("Failed to encode PNG")
            return
        }
        try png.write(to: URL(fileURLWithPath: outputPath))
        print("DoneStateSurvey written to: \(outputPath)")
    }

    @MainActor
    private static func render<V: View>(view: V, appearance: NSAppearance, size: NSSize) throws -> NSImage {
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()

        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw NSError(domain: "DoneStateSurvey", code: 1)
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = NSImage(size: size)
        image.addRepresentation(bitmap)
        return image
    }
}

private struct DoneStateSurveyColumn: View {
    let title: String
    let titleColor: Color
    let backdrop: Color
    let statuses: [DoneCloudStatus]
    let result: RecordingResult

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(titleColor)
            VStack(spacing: 6) {
                ForEach(Array(statuses.enumerated()), id: \.offset) { _, status in
                    DoneState(
                        result: result,
                        canTranscribe: status == .pending,
                        cloudStatus: status,
                        onTranscribe: {},
                        onShow: {},
                        onNew: {}
                    )
                    .frame(width: 340)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(backdrop)
                    )
                }
            }
        }
        .padding(12)
    }
}
