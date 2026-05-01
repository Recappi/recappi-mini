import Foundation

struct UITestModeConfiguration {
    struct SimulatedAutoPromptApp: Sendable {
        let bundleID: String
        let name: String
    }

    static let shared = UITestModeConfiguration()

    let isEnabled: Bool
    let authToken: String?
    let backendURL: String?
    let audioFixturePath: String?
    let commandFilePath: String?
    let manualAuthEnabled: Bool
    let simulatedAutoPromptApp: SimulatedAutoPromptApp?
    let simulatedAutoPromptMeetingLabel: String?
    let hiddenAutoPromptSnoozeSeconds: TimeInterval?
    let detectedMeetingAutoStopGraceSeconds: TimeInterval?
    let openCloudWindowOnLaunch: Bool
    /// Test-only override: pretend the selected recording has a newer cloud
    /// version after each detail refresh, so reviewers can see the
    /// `newerVersionStrip` banner without orchestrating a real concurrent
    /// retranscribe.
    ///
    /// **NOT A FEATURE FLAG.** This is strictly a UI regression / screenshot
    /// fixture. It bypasses the real freshness comparison and forces the
    /// banner on after every detail refresh. Do not call it from product
    /// code paths and do not expose it to users. Gated by the
    /// `RECAPPI_TEST_FORCE_NEWER_VERSION_BANNER=1` env var, which must be
    /// set explicitly in a test launch.
    let forceNewerVersionBannerForTesting: Bool

    private init(processInfo: ProcessInfo = .processInfo) {
        let env = processInfo.environment
        let args = Set(processInfo.arguments)

        isEnabled = env["RECAPPI_UI_TEST"] == "1" || args.contains("RECAPPI_UI_TEST")
        authToken = env["RECAPPI_TEST_AUTH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        backendURL = env["RECAPPI_TEST_BACKEND_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        audioFixturePath = env["RECAPPI_TEST_AUDIO_FIXTURE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        commandFilePath = env["RECAPPI_UI_TEST_COMMAND_FILE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        manualAuthEnabled = env["RECAPPI_ENABLE_MANUAL_AUTH"] == "1"
        openCloudWindowOnLaunch = env["RECAPPI_TEST_OPEN_CLOUD_WINDOW"] == "1"
        forceNewerVersionBannerForTesting = env["RECAPPI_TEST_FORCE_NEWER_VERSION_BANNER"] == "1"
        if let rawSnooze = env["RECAPPI_TEST_HIDDEN_AUTOPROMPT_SNOOZE_SECONDS"],
           let parsedSnooze = TimeInterval(rawSnooze) {
            hiddenAutoPromptSnoozeSeconds = max(parsedSnooze, 0)
        } else {
            hiddenAutoPromptSnoozeSeconds = nil
        }
        if let rawAutoStopGrace = env["RECAPPI_TEST_DETECTED_MEETING_AUTOSTOP_GRACE_SECONDS"],
           let parsedAutoStopGrace = TimeInterval(rawAutoStopGrace) {
            detectedMeetingAutoStopGraceSeconds = max(parsedAutoStopGrace, 0)
        } else {
            detectedMeetingAutoStopGraceSeconds = nil
        }

        let bundleID = env["RECAPPI_TEST_AUTO_PROMPT_BUNDLE_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let appName = env["RECAPPI_TEST_AUTO_PROMPT_APP_NAME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let bundleID, !bundleID.isEmpty {
            simulatedAutoPromptApp = SimulatedAutoPromptApp(
                bundleID: bundleID,
                name: (appName?.isEmpty == false ? appName! : bundleID)
            )
        } else {
            simulatedAutoPromptApp = nil
        }
        simulatedAutoPromptMeetingLabel = env["RECAPPI_TEST_AUTO_PROMPT_MEETING_LABEL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
