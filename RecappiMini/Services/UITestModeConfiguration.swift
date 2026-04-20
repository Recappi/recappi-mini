import Foundation

struct UITestModeConfiguration {
    static let shared = UITestModeConfiguration()

    let isEnabled: Bool
    let cookieValue: String?
    let backendURL: String?
    let audioFixturePath: String?
    let disableSummary: Bool
    let summaryStubEnabled: Bool

    private init(processInfo: ProcessInfo = .processInfo) {
        let env = processInfo.environment
        let args = Set(processInfo.arguments)

        isEnabled = env["RECAPPI_UI_TEST"] == "1" || args.contains("RECAPPI_UI_TEST")
        cookieValue = env["RECAPPI_TEST_COOKIE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        backendURL = env["RECAPPI_TEST_BACKEND_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        audioFixturePath = env["RECAPPI_TEST_AUDIO_FIXTURE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        disableSummary = env["RECAPPI_TEST_DISABLE_SUMMARY"] == "1"
        summaryStubEnabled = env["RECAPPI_TEST_SUMMARY_STUB"] == "1"
    }
}
