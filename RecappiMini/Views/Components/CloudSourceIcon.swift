import AppKit
import SwiftUI

struct CloudSourceIcon: View {
    let recording: CloudRecording
    let size: CGFloat

    @State private var loadedBundleID: String?
    @State private var loadedIcon: NSImage?
    @State private var requestedBundleID: String?

    var body: some View {
        Group {
            if let icon = displayIcon {
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
        .onAppear(perform: loadIconIfNeeded)
        .onChange(of: recording.sourceAppIconBundleID) { _, _ in
            loadIconIfNeeded()
        }
    }

    private var displayIcon: NSImage? {
        if loadedBundleID == recording.sourceAppIconBundleID, let loadedIcon {
            return loadedIcon
        }
        return recording.sourceAppIcon
    }

    private func loadIconIfNeeded() {
        guard let bundleID = recording.sourceAppIconBundleID else {
            loadedBundleID = nil
            loadedIcon = nil
            requestedBundleID = nil
            return
        }

        let iconSize = NSSize(width: size, height: size)
        if let cached = CloudRecordingAppIconProvider.cachedIcon(for: bundleID, size: iconSize) {
            loadedBundleID = bundleID
            loadedIcon = cached
            requestedBundleID = nil
            return
        }

        guard requestedBundleID != bundleID else { return }
        requestedBundleID = bundleID

        DispatchQueue.global(qos: .utility).async {
            let icon = CloudRecordingAppIconProvider.loadIcon(for: bundleID, size: iconSize)
            DispatchQueue.main.async {
                guard recording.sourceAppIconBundleID == bundleID else { return }
                loadedBundleID = bundleID
                loadedIcon = icon
                requestedBundleID = nil
            }
        }
    }
}
