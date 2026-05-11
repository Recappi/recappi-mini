import AppKit
import SwiftUI

struct CloudSourceIcon: View {
    let recording: CloudRecording
    let size: CGFloat

    var body: some View {
        Group {
            if let icon = recording.sourceAppIcon {
                // Real app icons (Chrome, Zoom, …) carry their own shape
                // and shadow — render them edge-to-edge without any
                // surrounding plate.
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
            } else {
                // Bare SF Symbol fallback. Use SwiftUI's semantic
                // `.secondary` ShapeStyle so the system handles the
                // selected-row colour flip the same way it does for
                // Text — no manual isSelected plumbing required.
                Image(systemName: recording.sourceIconName)
                    .font(.system(size: size * 0.7, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}
