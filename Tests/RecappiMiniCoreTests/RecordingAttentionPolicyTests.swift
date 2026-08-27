import XCTest
@testable import RecappiMini

final class RecordingAttentionPolicyTests: XCTestCase {
    private let settings = RecordingAttentionSettings(
        longReminderIntervalSeconds: 60,
        suspectedInactivityEnabled: true,
        maxDurationSeconds: 300
    )

    func testLongRecordingReminderOnlyFiresWhilePanelIsHiddenAndRepeatsByInterval() {
        var policy = RecordingAttentionPolicy()

        XCTAssertEqual(
            policy.actions(
                for: snapshot(elapsedSeconds: 59, isPanelVisible: false),
                settings: settings
            ),
            []
        )
        XCTAssertEqual(
            policy.actions(
                for: snapshot(elapsedSeconds: 60, isPanelVisible: true),
                settings: settings
            ),
            []
        )
        XCTAssertEqual(
            policy.actions(
                for: snapshot(elapsedSeconds: 61, isPanelVisible: false),
                settings: settings
            ),
            [.longHiddenRecording]
        )
        XCTAssertEqual(
            policy.actions(
                for: snapshot(elapsedSeconds: 100, isPanelVisible: false),
                settings: settings
            ),
            []
        )
        XCTAssertEqual(
            policy.actions(
                for: snapshot(elapsedSeconds: 121, isPanelVisible: false),
                settings: settings
            ),
            [.longHiddenRecording]
        )
    }

    func testMaxDurationFiresOnce() {
        var policy = RecordingAttentionPolicy()
        let maxSettings = RecordingAttentionSettings(
            longReminderIntervalSeconds: 0,
            suspectedInactivityEnabled: true,
            maxDurationSeconds: 300
        )

        XCTAssertEqual(
            policy.actions(for: snapshot(elapsedSeconds: 299), settings: maxSettings),
            []
        )
        XCTAssertEqual(
            policy.actions(for: snapshot(elapsedSeconds: 300), settings: maxSettings),
            [.maxDurationReached]
        )
        XCTAssertEqual(
            policy.actions(for: snapshot(elapsedSeconds: 360), settings: maxSettings),
            []
        )
    }

    func testFocusedSourceInactivityRequiresGraceAndResetsWhenSourceReturns() {
        var policy = RecordingAttentionPolicy()
        let inactivitySettings = RecordingAttentionSettings(
            longReminderIntervalSeconds: 0,
            suspectedInactivityEnabled: true,
            maxDurationSeconds: 0
        )

        XCTAssertEqual(
            policy.actions(
                for: snapshot(
                    elapsedSeconds: 180,
                    activeBundleIDs: [],
                    focusedSourceBundleID: "com.example.Meet"
                ),
                settings: inactivitySettings
            ),
            []
        )
        XCTAssertEqual(
            policy.actions(
                for: snapshot(
                    elapsedSeconds: 240,
                    activeBundleIDs: ["com.example.Meet"],
                    focusedSourceBundleID: "com.example.Meet"
                ),
                settings: inactivitySettings
            ),
            []
        )
        XCTAssertEqual(
            policy.actions(
                for: snapshot(
                    elapsedSeconds: 260,
                    activeBundleIDs: [],
                    focusedSourceBundleID: "com.example.Meet"
                ),
                settings: inactivitySettings
            ),
            []
        )
        XCTAssertEqual(
            policy.actions(
                for: snapshot(
                    elapsedSeconds: 380,
                    activeBundleIDs: [],
                    focusedSourceBundleID: "com.example.Meet"
                ),
                settings: inactivitySettings
            ),
            [.suspectedInactiveSource]
        )
    }

    func testAllSystemQuietInactivityUsesLongerGrace() {
        var policy = RecordingAttentionPolicy()
        let quietSettings = RecordingAttentionSettings(
            longReminderIntervalSeconds: 0,
            suspectedInactivityEnabled: true,
            maxDurationSeconds: 0
        )

        XCTAssertEqual(
            policy.actions(
                for: snapshot(elapsedSeconds: 180, activeBundleIDs: [], audioLevel: 0.0),
                settings: quietSettings
            ),
            []
        )
        XCTAssertEqual(
            policy.actions(
                for: snapshot(elapsedSeconds: 300, activeBundleIDs: ["com.example.Player"], audioLevel: 0.0),
                settings: quietSettings
            ),
            []
        )
        XCTAssertEqual(
            policy.actions(
                for: snapshot(elapsedSeconds: 320, activeBundleIDs: [], audioLevel: 0.0),
                settings: quietSettings
            ),
            []
        )
        XCTAssertEqual(
            policy.actions(
                for: snapshot(elapsedSeconds: 500, activeBundleIDs: [], audioLevel: 0.0),
                settings: quietSettings
            ),
            [.suspectedInactiveSource]
        )
    }

    private func snapshot(
        elapsedSeconds: Int,
        isPanelVisible: Bool = false,
        activeBundleIDs: Set<String> = ["com.example.Meet"],
        focusedSourceBundleID: String? = nil,
        audioLevel: Float = 0.2
    ) -> RecordingAttentionSnapshot {
        RecordingAttentionSnapshot(
            elapsedSeconds: elapsedSeconds,
            isPanelVisible: isPanelVisible,
            activeBundleIDs: activeBundleIDs,
            focusedSourceBundleID: focusedSourceBundleID,
            audioLevel: audioLevel
        )
    }
}
