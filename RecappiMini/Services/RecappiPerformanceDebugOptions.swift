import Foundation

enum RecappiPerformanceDebugOptions {
    static let disableBackendLiveCaptionsEnvKey = "RECAPPI_DEBUG_DISABLE_BACKEND_LIVE_CAPTIONS"
    static let disableBackendLiveCaptionsDefaultsKey = "recappi.debug.disableBackendLiveCaptions"

    static let minimalRecordingUIEnvKey = "RECAPPI_DEBUG_MINIMAL_RECORDING_UI"
    static let minimalRecordingUIDefaultsKey = "recappi.debug.minimalRecordingUI"

    static func disableBackendLiveCaptions(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        boolFlag(
            environmentKey: disableBackendLiveCaptionsEnvKey,
            defaultsKey: disableBackendLiveCaptionsDefaultsKey,
            environment: environment,
            userDefaults: userDefaults
        )
    }

    static func minimalRecordingUI(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        boolFlag(
            environmentKey: minimalRecordingUIEnvKey,
            defaultsKey: minimalRecordingUIDefaultsKey,
            environment: environment,
            userDefaults: userDefaults
        )
    }

    private static func boolFlag(
        environmentKey: String,
        defaultsKey: String,
        environment: [String: String],
        userDefaults: UserDefaults
    ) -> Bool {
        if let raw = environment[environmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !raw.isEmpty
        {
            return ["1", "true", "yes", "on"].contains(raw)
        }
        return userDefaults.bool(forKey: defaultsKey)
    }
}
