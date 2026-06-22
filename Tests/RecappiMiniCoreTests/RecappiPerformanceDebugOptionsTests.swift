import XCTest
@testable import RecappiMini

final class RecappiPerformanceDebugOptionsTests: XCTestCase {
    func testDisableBackendLiveCaptionsPrefersTruthyEnvironment() {
        let defaults = UserDefaults(suiteName: "RecappiPerformanceDebugOptionsTests-\(UUID().uuidString)")!
        defaults.set(false, forKey: RecappiPerformanceDebugOptions.disableBackendLiveCaptionsDefaultsKey)

        XCTAssertTrue(RecappiPerformanceDebugOptions.disableBackendLiveCaptions(
            environment: [RecappiPerformanceDebugOptions.disableBackendLiveCaptionsEnvKey: "yes"],
            userDefaults: defaults
        ))
    }

    func testMinimalRecordingUIFallsBackToUserDefaults() {
        let defaults = UserDefaults(suiteName: "RecappiPerformanceDebugOptionsTests-\(UUID().uuidString)")!
        defaults.set(true, forKey: RecappiPerformanceDebugOptions.minimalRecordingUIDefaultsKey)

        XCTAssertTrue(RecappiPerformanceDebugOptions.minimalRecordingUI(
            environment: [:],
            userDefaults: defaults
        ))
    }

    func testFalseyEnvironmentOverridesTruthyDefaults() {
        let defaults = UserDefaults(suiteName: "RecappiPerformanceDebugOptionsTests-\(UUID().uuidString)")!
        defaults.set(true, forKey: RecappiPerformanceDebugOptions.disableBackendLiveCaptionsDefaultsKey)

        XCTAssertFalse(RecappiPerformanceDebugOptions.disableBackendLiveCaptions(
            environment: [RecappiPerformanceDebugOptions.disableBackendLiveCaptionsEnvKey: "0"],
            userDefaults: defaults
        ))
    }
}
