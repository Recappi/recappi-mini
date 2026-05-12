import SwiftUI

/// Sidebar list row content. List drives selection via `.tag()` — this
/// view stays purely visual so the system selection capsule provides the
/// dominant highlight. Reduced to icon + title; metadata (source, time,
/// status) is reachable from the detail pane and the row context menu.
struct CloudRecordingRow: View {
    let recording: CloudRecording
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 4) {
            CloudSourceIcon(recording: recording, size: 26)

            Text(recording.presentationTitle)
                .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                // Leave foregroundStyle unspecified so macOS's sidebar
                // List inverts the label to white over the selection
                // capsule automatically. Setting an explicit colour here
                // (even `Color.dtLabel`) would suppress that system flip.
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .animation(DT.motionAware(DT.ease(0.15)), value: isSelected)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.recordingRowPrefix + recording.id)
    }
}

#if DEBUG
#Preview("Cloud Sidebar Rows") {
    List {
        CloudRecordingRow(
            recording: .previewSample(id: "1", title: "Weekly engineering sync"),
            isSelected: true
        )
        CloudRecordingRow(
            recording: .previewSample(id: "2", title: "Design review with platform team"),
            isSelected: false
        )
        CloudRecordingRow(
            recording: .previewSample(
                id: "3",
                title: "Quarterly planning conversation with stakeholders across teams"
            ),
            isSelected: false
        )
    }
    .listStyle(.sidebar)
    .frame(width: 280, height: 220)
}
#endif
