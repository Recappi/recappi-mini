import Foundation

enum UITestPaths {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var automationOverridesDirectory: URL {
        repoRoot.appendingPathComponent(".build/xcode", isDirectory: true)
    }

    static var appBundle: URL {
        if let override = ProcessInfo.processInfo.environment["RECAPPI_TEST_APP"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        return repoRoot.appendingPathComponent("build/RecappiMini.app")
    }

    static var recordingFixture: URL {
        repoRoot.appendingPathComponent("Tests/Fixtures/Audio/automation-recording.m4a")
    }

    static var uploadFixture: URL {
        repoRoot.appendingPathComponent("Tests/Fixtures/Audio/automation-upload.wav")
    }

    static var cookieOverrideFile: URL {
        automationOverridesDirectory.appendingPathComponent("recappi_test_cookie.txt")
    }

    static var backendOverrideFile: URL {
        automationOverridesDirectory.appendingPathComponent("recappi_test_backend_url.txt")
    }

    static var recordingsRootOverrideFile: URL {
        automationOverridesDirectory.appendingPathComponent("recappi_test_recordings_root.txt")
    }

    static func readOverride(from url: URL) -> String? {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static var liveCookieValue: String? {
        if let env = ProcessInfo.processInfo.environment["RECAPPI_TEST_COOKIE"], !env.isEmpty {
            return env
        }
        return readOverride(from: cookieOverrideFile)
    }

    static var backendOverrideValue: String? {
        if let env = ProcessInfo.processInfo.environment["RECAPPI_TEST_BACKEND_URL"], !env.isEmpty {
            return env
        }
        return readOverride(from: backendOverrideFile)
    }

    static var recordingsRootOverrideValue: String? {
        if let env = ProcessInfo.processInfo.environment["RECAPPI_TEST_RECORDINGS_ROOT"], !env.isEmpty {
            return env
        }
        return readOverride(from: recordingsRootOverrideFile)
    }
}
