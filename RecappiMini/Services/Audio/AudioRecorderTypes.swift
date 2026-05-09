import AppKit
@preconcurrency import ScreenCaptureKit

struct AudioApp: Identifiable, Hashable {
    enum Bucket: Int, Sendable, Comparable {
        case meeting = 0
        case browser = 1
        case other = 2
        static func < (lhs: Bucket, rhs: Bucket) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String  // bundle ID
    let name: String
    let icon: NSImage?
    let scApp: SCRunningApplication?
    let bucket: Bucket
    /// True when AudioActivityMonitor sees this bundle currently producing
    /// output audio. Active apps float to the top of the picker.
    var isActive: Bool

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id
    }
}

struct RecordingSuggestion: Equatable, Sendable {
    let appID: String
    let appName: String
    let promptTitle: String
}

struct MeetingPrompt: Equatable, Sendable {
    let appID: String
    let appName: String
    let promptTitle: String
}

struct DetectedMeetingRecordingContext: Equatable, Sendable {
    let appID: String
    let appName: String
    let promptTitle: String
}

struct AutoStopRecordingRequest: Equatable, Identifiable, Sendable {
    let id = UUID()
    let context: DetectedMeetingRecordingContext
}

struct LiveCaptionRecordingConfiguration: Equatable, Sendable {
    let showsTranslation: Bool
    let targetLanguage: String
}

enum LiveCaptionPaneVisibility: String, CaseIterable, Identifiable, Sendable {
    case both
    case captionOnly
    case translationOnly

    var id: String { rawValue }

    var showsCaption: Bool {
        self != .translationOnly
    }

    var showsTranslation: Bool {
        self != .captionOnly
    }
}

/// Bundle-ID whitelists for smart sorting. Helpers / renderers are filtered
/// out at the refresh step, so we classify by the user-visible parent bundle.
enum AudioAppCategories {
    static let meetingBundles: Set<String> = [
        "us.zoom.xos",
        "us.zoom.Zoom",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap",         // Slack (huddles)
        "com.hnc.Discord",
        "com.cisco.webexmeetingsapp",
        "com.cisco.webexmeetingsapp.WebexApp",
        "com.apple.FaceTime",
        "com.loom.desktop",
    ]

    static let browserBundles: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "company.thebrowser.Browser",        // Arc
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    static func bucket(for bundleID: String) -> AudioApp.Bucket {
        let canonical = BundleCollapser.parent(of: bundleID)
        if meetingBundles.contains(canonical) { return .meeting }
        if browserBundles.contains(canonical) { return .browser }
        return .other
    }
}
