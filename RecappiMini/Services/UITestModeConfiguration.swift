import Foundation

struct UITestModeConfiguration {
    static let shared = UITestModeConfiguration()

    let isEnabled: Bool
    let authToken: String?
    let cookieValue: String?
    let backendURL: String?
    let audioFixturePath: String?
    let manualAuthEnabled: Bool

    private init(processInfo: ProcessInfo = .processInfo) {
        let env = processInfo.environment
        let args = Set(processInfo.arguments)

        isEnabled = env["RECAPPI_UI_TEST"] == "1" || args.contains("RECAPPI_UI_TEST")
        authToken = env["RECAPPI_TEST_AUTH_TOKEN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        cookieValue = env["RECAPPI_TEST_COOKIE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        backendURL = env["RECAPPI_TEST_BACKEND_URL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        audioFixturePath = env["RECAPPI_TEST_AUDIO_FIXTURE"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        manualAuthEnabled = env["RECAPPI_ENABLE_MANUAL_AUTH"] == "1"
    }
}
