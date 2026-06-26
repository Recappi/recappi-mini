import Foundation
@preconcurrency import ScreenCaptureKit

public struct CaptureSourceApplication: Sendable, Equatable {
    public var bundleID: String
    public var name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }
}

public enum CaptureSourceCatalog {
    public static let systemSource = CaptureSource(
        id: "system",
        kind: .system,
        label: "System audio · all apps"
    )

    public static func availableSources(
        selfBundleID: String = Bundle.main.bundleIdentifier ?? "com.recappi.mini",
        includeSystemSource: Bool = true
    ) async throws -> [CaptureSource] {
        let content = try await SCShareableContent.current
        let applications = content.applications.map {
            CaptureSourceApplication(bundleID: $0.bundleIdentifier, name: $0.applicationName)
        }
        return sources(
            from: applications,
            selfBundleID: selfBundleID,
            includeSystemSource: includeSystemSource
        )
    }

    public static func sources(
        from applications: [CaptureSourceApplication],
        selfBundleID: String,
        includeSystemSource: Bool = true
    ) -> [CaptureSource] {
        var byParent: [String: CaptureSourceApplication] = [:]
        for app in applications {
            let bundleID = app.bundleID
            guard !bundleID.isEmpty else { continue }
            let parent = CaptureBundleCollapser.parent(of: bundleID)
            guard shouldInclude(bundleID: parent, selfBundleID: selfBundleID) else { continue }
            if byParent[parent] == nil || bundleID == parent {
                byParent[parent] = app
            }
        }

        let appSources = byParent
            .compactMap { parentBundleID, app -> CaptureSource? in
                let label = CaptureBundleCollapser.browserDisplayName(
                    for: parentBundleID,
                    fallback: app.name
                )
                guard !label.isEmpty else { return nil }
                return CaptureSource(
                    id: "app:\(parentBundleID)",
                    kind: .app,
                    label: label,
                    appName: label,
                    bundleID: parentBundleID
                )
            }
            .sorted { lhs, rhs in
                lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
            }

        guard includeSystemSource else { return appSources }
        return [systemSource] + appSources
    }

    public static func shouldInclude(bundleID: String, selfBundleID: String) -> Bool {
        guard bundleID != selfBundleID else { return false }
        guard !bundleID.hasPrefix("com.apple.") || notableAppleBundleIDs.contains(bundleID) else {
            return false
        }
        return true
    }

    private static let notableAppleBundleIDs: Set<String> = [
        "com.apple.Safari",
        "com.apple.FaceTime",
        "com.apple.Music",
        "com.apple.QuickTimePlayerX",
        "com.apple.VoiceMemos",
    ]
}
