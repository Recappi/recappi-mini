import SwiftUI

struct CloudStatusChip: View {
    /// Horizontal inset between the capsule outline and the status text
    /// glyph. Exposed as a single source of truth so any view that wants
    /// its own trailing column to *visually* line up with the status
    /// chip's TEXT (not its capsule outline) — e.g. the duration label
    /// in `CloudRecordingRow`'s metadata row — can apply the same
    /// trailing offset and avoid the 6pt visual misalignment between
    /// "Ready" and "26:01" that peng-xiao called out (`f4892708`).
    static let nonProminentHorizontalInset: CGFloat = 6
    static let prominentHorizontalInset: CGFloat = 9

    private let displayStatus: CloudRecordingDisplayStatus
    var prominent: Bool = false

    init(
        status: CloudRecordingStatus,
        latestJobStatus: RemoteJobStatus? = nil,
        prominent: Bool = false
    ) {
        self.displayStatus = CloudRecordingDisplayStatus.resolve(
            recordingStatus: status,
            latestJobStatus: latestJobStatus
        )
        self.prominent = prominent
    }

    var body: some View {
        Text(displayStatus.displayName)
            .font(.system(size: prominent ? 11 : 9, weight: .medium))
            .foregroundStyle(color)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, prominent ? Self.prominentHorizontalInset : Self.nonProminentHorizontalInset)
            .padding(.vertical, prominent ? 5 : 3)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(0.13))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(color.opacity(0.22), lineWidth: 0.5)
            )
    }

    private var color: Color {
        switch displayStatus {
        case .transcription(let status):
            return status.detailColor
        case .recording(let status):
            switch status {
            case .ready:
                return DT.statusReady
            case .uploading:
                return DT.statusUploading
            case .failed, .aborted:
                return DT.statusWarning
            case .unknown:
                return Color.dtLabelTertiary
            }
        }
    }
}

struct CloudJobStatusChip: View {
    let status: RemoteJobStatus
    var compact = false

    var body: some View {
        Text(status.displayName)
            .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold))
            .foregroundStyle(status.detailColor)
            .padding(.horizontal, compact ? 6 : 7)
            .padding(.vertical, compact ? 2 : 3)
            .background(
                Capsule(style: .continuous)
                    .fill(status.detailColor.opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(status.detailColor.opacity(0.22), lineWidth: 0.5)
            )
    }
}

extension RemoteJobStatus {
    var detailColor: Color {
        switch self {
        case .queued:
            return DT.waveformLit
        case .running:
            return DT.statusUploading
        case .succeeded:
            return DT.statusReady
        case .failed:
            return DT.systemOrange
        }
    }

    var detailIconName: String {
        switch self {
        case .queued, .running:
            return "hourglass"
        case .succeeded:
            return "waveform.badge.checkmark"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }
}
