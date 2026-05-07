import AppKit
import SwiftUI

struct CloudSourceIcon: View {
    let recording: CloudRecording
    let size: CGFloat

    var body: some View {
        ZStack {
            // The tint plate stays as a faint badge under whatever icon
            // we render. It used to also act as decorative padding (the
            // app icon was inset to 72% of the box), but peng-xiao
            // `26485a7a` flagged that as making the source logo look
            // smaller than the container suggests. Real app icons now
            // fill the box edge-to-edge; the rounded corner radius mask
            // keeps them from poking past the badge outline.
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(DT.statusReady.opacity(0.10))

            if let icon = recording.sourceAppIcon {
                Image(nsImage: icon)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
            } else {
                // Source-symbol fallback when the recording's bundle ID
                // doesn't resolve to an installed app (e.g. Discord
                // running as a PWA, recording from a CLI tool, etc.).
                // Original tint was `DT.statusReady` against the same-
                // colour 10% plate, which made the symbol nearly
                // invisible on top of the badge — that's the missing
                // Discord icon peng-xiao saw at `26485a7a`. Render with
                // primary label colour at a larger size so the fallback
                // is unambiguously a recognisable shape.
                Image(systemName: recording.sourceIconName)
                    .font(.system(size: size * 0.58, weight: .medium))
                    .foregroundStyle(Color.dtLabel)
            }
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
        )
    }
}
