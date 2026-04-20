import Foundation

enum AutomationPaths {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var buildAppScript: URL {
        repoRoot.appendingPathComponent("scripts/build-app.sh")
    }

    static var fixtureScript: URL {
        repoRoot.appendingPathComponent("scripts/generate-test-audio-fixtures.sh")
    }

    static var automationScript: URL {
        repoRoot.appendingPathComponent("scripts/run-automation-tests.sh")
    }

    static var appBundle: URL {
        if let override = ProcessInfo.processInfo.environment["RECAPPI_TEST_APP"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }

        return repoRoot.appendingPathComponent("build/RecappiMini.app")
    }

    static var fixturesDirectory: URL {
        repoRoot.appendingPathComponent("Tests/Fixtures/Audio")
    }

    static var recordingFixture: URL {
        fixturesDirectory.appendingPathComponent("automation-recording.m4a")
    }

    static var uploadFixture: URL {
        fixturesDirectory.appendingPathComponent("automation-upload.wav")
    }

    static var fixtureManifest: URL {
        fixturesDirectory.appendingPathComponent("fixture-manifest.json")
    }
}
