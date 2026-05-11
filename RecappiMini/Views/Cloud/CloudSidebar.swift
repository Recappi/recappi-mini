import SwiftUI

/// Sidebar list row content. List drives selection via `.tag()` — this
/// view stays purely visual so the system selection capsule provides the
/// dominant highlight. Reduced to icon + title; metadata (source, time,
/// status) is reachable from the detail pane and the row context menu.
struct CloudRecordingRow: View {
    let recording: CloudRecording
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            CloudSourceIcon(recording: recording, size: 26)

            Text(recording.presentationTitle)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(Color.dtLabel)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(DT.ease(0.15), value: isSelected)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.recordingRowPrefix + recording.id)
    }
}
