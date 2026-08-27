import Foundation

struct RecordingAttentionSettings: Equatable, Sendable {
    var longReminderIntervalSeconds: Int
    var suspectedInactivityEnabled: Bool
    var maxDurationSeconds: Int

    static let defaults = RecordingAttentionSettings(
        longReminderIntervalSeconds: 45 * 60,
        suspectedInactivityEnabled: true,
        maxDurationSeconds: 0
    )
}

struct RecordingAttentionSnapshot: Equatable, Sendable {
    var elapsedSeconds: Int
    var isPanelVisible: Bool
    var activeBundleIDs: Set<String>
    var focusedSourceBundleID: String?
    var audioLevel: Float
}

enum RecordingAttentionAction: Equatable, Sendable {
    case longHiddenRecording
    case suspectedInactiveSource
    case maxDurationReached
}

struct RecordingAttentionPolicy: Sendable {
    private struct InactivityCandidate: Equatable, Sendable {
        let key: String
        let startedAtSeconds: Int
        let graceSeconds: Int
    }

    private var lastLongReminderAtSeconds: Int?
    private var inactivityCandidate: InactivityCandidate?
    private var didRaiseInactivity = false
    private var didRaiseMaxDuration = false

    private static let minimumElapsedBeforeInactivitySeconds = 3 * 60
    private static let focusedSourceInactiveGraceSeconds = 2 * 60
    private static let allSystemQuietGraceSeconds = 3 * 60
    private static let quietAudioLevelThreshold: Float = 0.015

    mutating func reset() {
        lastLongReminderAtSeconds = nil
        inactivityCandidate = nil
        didRaiseInactivity = false
        didRaiseMaxDuration = false
    }

    mutating func actions(
        for snapshot: RecordingAttentionSnapshot,
        settings: RecordingAttentionSettings
    ) -> [RecordingAttentionAction] {
        guard snapshot.elapsedSeconds > 0 else { return [] }

        var actions: [RecordingAttentionAction] = []

        if settings.longReminderIntervalSeconds > 0,
           !snapshot.isPanelVisible,
           snapshot.elapsedSeconds >= settings.longReminderIntervalSeconds,
           lastLongReminderAtSeconds.map({ snapshot.elapsedSeconds - $0 >= settings.longReminderIntervalSeconds }) ?? true {
            lastLongReminderAtSeconds = snapshot.elapsedSeconds
            actions.append(.longHiddenRecording)
        }

        if settings.maxDurationSeconds > 0,
           !didRaiseMaxDuration,
           snapshot.elapsedSeconds >= settings.maxDurationSeconds {
            didRaiseMaxDuration = true
            actions.append(.maxDurationReached)
        }

        if settings.suspectedInactivityEnabled,
           !didRaiseInactivity,
           snapshot.elapsedSeconds >= Self.minimumElapsedBeforeInactivitySeconds {
            if let candidate = inactivityCandidate(for: snapshot) {
                if let current = inactivityCandidate, current.key == candidate.key {
                    if snapshot.elapsedSeconds - current.startedAtSeconds >= current.graceSeconds {
                        didRaiseInactivity = true
                        inactivityCandidate = nil
                        actions.append(.suspectedInactiveSource)
                    }
                } else {
                    inactivityCandidate = candidate
                }
            } else {
                inactivityCandidate = nil
            }
        } else if !settings.suspectedInactivityEnabled {
            inactivityCandidate = nil
        }

        return actions
    }

    private func inactivityCandidate(for snapshot: RecordingAttentionSnapshot) -> InactivityCandidate? {
        let activeBundleIDs = Set(snapshot.activeBundleIDs.map(Self.normalizedBundleID(_:)))

        if let sourceBundleID = snapshot.focusedSourceBundleID.map(Self.normalizedBundleID(_:)),
           !sourceBundleID.isEmpty {
            guard !activeBundleIDs.contains(sourceBundleID) else { return nil }
            return InactivityCandidate(
                key: "source:\(sourceBundleID)",
                startedAtSeconds: snapshot.elapsedSeconds,
                graceSeconds: Self.focusedSourceInactiveGraceSeconds
            )
        }

        guard activeBundleIDs.isEmpty,
              snapshot.audioLevel <= Self.quietAudioLevelThreshold else {
            return nil
        }

        return InactivityCandidate(
            key: "all-system-quiet",
            startedAtSeconds: snapshot.elapsedSeconds,
            graceSeconds: Self.allSystemQuietGraceSeconds
        )
    }

    private static func normalizedBundleID(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
