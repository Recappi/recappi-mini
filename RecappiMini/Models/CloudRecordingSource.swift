import AppKit
import Foundation

extension CloudRecording {
    var presentationTitle: String {
        if let summaryTitle = clean(summaryTitle) {
            return summaryTitle
        }

        if let title = clean(title), !Self.isTimestampTitle(title) {
            return title
        }

        if let sourceTitle = clean(sourceTitle), sourceTitle != "All system audio" {
            return sourceTitle
        }

        if let appName = clean(sourceAppName) {
            return "\(appName) recording"
        }

        if let createdAt {
            let formatter = DateFormatter()
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            return "Meeting at \(formatter.string(from: createdAt))"
        }

        return "Untitled recording"
    }

    var sourceLine: String {
        if let appName = clean(sourceAppName) {
            return appName
        }

        if let inferred = inferredSource {
            return inferred.displayName
        }

        if let sourceTitle = clean(sourceTitle), sourceTitle != presentationTitle {
            return sourceTitle
        }

        if let title = clean(title), title == "Audio recording" {
            return "All system audio"
        }

        return "Source unknown"
    }

    var sourceIconName: String {
        if sourceLine == "All system audio" {
            return "doc.text.below.ecg.fill"
        }
        if inferredSource != nil || clean(sourceAppName) != nil || clean(sourceAppBundleID) != nil {
            return "app.fill"
        }
        return "waveform"
    }

    var sourceAppIcon: NSImage? {
        guard let bundleID = clean(sourceAppBundleID) ?? inferredSource?.bundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }

    var nowPlayingArtwork: NSImage? {
        if let sourceAppIcon {
            sourceAppIcon.size = NSSize(width: 256, height: 256)
            return sourceAppIcon
        }

        if let logo = NSImage(named: "Logo") ?? NSImage(named: "LogoTemplate") {
            logo.size = NSSize(width: 256, height: 256)
            return logo
        }

        return NSImage(systemSymbolName: sourceIconName, accessibilityDescription: nil)
    }

    private var inferredSource: CloudRecordingSource? {
        let candidates = [
            sourceTitle,
            title,
        ].compactMap(clean)

        for candidate in candidates {
            if let source = Self.knownSources.first(where: { $0.matches(candidate) }) {
                return source
            }
        }

        return nil
    }

    var durationText: String? {
        guard let durationMs, durationMs > 0 else { return nil }
        let totalSeconds = Int((Double(durationMs) / 1000.0).rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    var durationSeconds: Double? {
        guard let durationMs, durationMs > 0 else { return nil }
        return Double(durationMs) / 1000.0
    }

    var sizeText: String? {
        guard let sizeBytes, sizeBytes > 0 else { return nil }
        return ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var audioShapeText: String {
        let rate = sampleRate.map { "\($0) Hz" } ?? "unknown rate"
        let channelText: String
        switch channels {
        case 1:
            channelText = "mono"
        case 2:
            channelText = "stereo"
        case let channels?:
            channelText = "\(channels) ch"
        case nil:
            channelText = "unknown channels"
        }
        return "\(rate), \(channelText)"
    }

    var audioShapeCompactText: String {
        let rate = sampleRate.map(Self.compactSampleRate) ?? "unknown rate"
        return "\(rate) · \(channelCompactText)"
    }

    var formatText: String {
        guard let contentType = clean(contentType) else { return "Unknown" }
        switch contentType.lowercased() {
        case "audio/wav", "audio/x-wav":
            return "WAV"
        case "audio/mpeg", "audio/mp3":
            return "MP3"
        case "audio/mp4", "audio/m4a", "video/mp4":
            return "M4A"
        case "audio/aiff", "audio/x-aiff":
            return "AIFF"
        case "audio/aac":
            return "AAC"
        case "audio/ogg":
            return "OGG"
        case "audio/flac", "audio/x-flac":
            return "FLAC"
        default:
            return contentType
                .replacingOccurrences(of: "audio/", with: "")
                .uppercased()
        }
    }

    private var channelCompactText: String {
        switch channels {
        case 1:
            return "mono"
        case 2:
            return "stereo"
        case let channels?:
            return "\(channels) ch"
        case nil:
            return "unknown"
        }
    }

    private static func compactSampleRate(_ sampleRate: Int) -> String {
        guard sampleRate >= 1000 else { return "\(sampleRate) Hz" }
        if sampleRate % 1000 == 0 {
            return "\(sampleRate / 1000) kHz"
        }
        return String(format: "%.1f kHz", Double(sampleRate) / 1000.0)
    }

    var shortDateText: String {
        guard let date = createdAt else { return "Unknown date" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var listTimeText: String {
        guard let date = createdAt else { return "Unknown time" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    var createdDateText: String {
        guard let date = createdAt else { return "Created date unknown" }
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func clean(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return nil
        }
        return text
    }

    private static func isTimestampTitle(_ title: String) -> Bool {
        title.range(
            of: #"^\d{4}-\d{2}-\d{2}_\d{6}$"#,
            options: .regularExpression
        ) != nil
    }

    private static let knownSources: [CloudRecordingSource] = [
        CloudRecordingSource(displayName: "Google Chrome", bundleID: "com.google.Chrome", aliases: ["chrome", "google chrome"]),
        CloudRecordingSource(displayName: "Safari", bundleID: "com.apple.Safari", aliases: ["safari"]),
        CloudRecordingSource(displayName: "Zoom", bundleID: "us.zoom.xos", aliases: ["zoom"]),
        CloudRecordingSource(displayName: "Microsoft Teams", bundleID: "com.microsoft.teams2", aliases: ["teams", "microsoft teams"]),
        CloudRecordingSource(displayName: "Slack", bundleID: "com.tinyspeck.slackmacgap", aliases: ["slack", "huddle"]),
        CloudRecordingSource(displayName: "Discord", bundleID: "com.hnc.Discord", aliases: ["discord"]),
        CloudRecordingSource(displayName: "FaceTime", bundleID: "com.apple.FaceTime", aliases: ["facetime", "face time"]),
        CloudRecordingSource(displayName: "Arc", bundleID: "company.thebrowser.Browser", aliases: ["arc"]),
        CloudRecordingSource(displayName: "Microsoft Edge", bundleID: "com.microsoft.edgemac", aliases: ["edge", "microsoft edge"]),
        CloudRecordingSource(displayName: "Firefox", bundleID: "org.mozilla.firefox", aliases: ["firefox"]),
    ]
}

struct CloudRecordingSource {
    let displayName: String
    let bundleID: String
    let aliases: [String]

    func matches(_ text: String) -> Bool {
        let normalized = text.lowercased()
        return aliases.contains { alias in
            normalized.contains(alias)
        }
    }
}
