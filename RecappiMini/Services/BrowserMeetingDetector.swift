import Foundation

struct BrowserMeetingMatch: Equatable, Sendable {
    let meetingName: String
    let browserName: String
    let pageTitle: String?
    let pageURL: String?

    var suggestionTitle: String {
        "\(meetingName) in \(browserName)"
    }
}

enum BrowserMeetingDetector {
    private enum ScriptKind {
        case safari
        case chromium
    }

    private static let supportedBrowsers: [String: ScriptKind] = [
        "com.apple.Safari": .safari,
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.canary": .chromium,
        "com.brave.Browser": .chromium,
        "company.thebrowser.Browser": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "com.operasoftware.Opera": .chromium,
    ]

    static func supports(bundleID: String) -> Bool {
        supportedBrowsers[bundleID] != nil
    }

    static func inferMeetingSuggestion(bundleID: String, browserName: String) async -> String? {
        guard let output = await readBrowserContextOutput(bundleID: bundleID) else { return nil }
        return meetingSuggestion(fromScriptOutput: output, browserName: browserName)
    }

    static func classify(
        urlString: String?,
        title: String?,
        browserName: String
    ) -> BrowserMeetingMatch? {
        let trimmedURL = urlString?.trimmingCharacters(in: .whitespacesAndNewlines)
        let host = trimmedURL
            .flatMap(URL.init(string:))
            .flatMap(\.host)?
            .lowercased()

        guard let host else { return nil }

        let meetingName: String?
        switch host {
        case let host where host == "meet.google.com" || host.hasSuffix(".meet.google.com"):
            meetingName = "Google Meet"
        case let host where host == "teams.microsoft.com" || host.hasSuffix(".teams.microsoft.com") || host == "teams.live.com":
            meetingName = "Microsoft Teams"
        case let host where host == "zoom.us" || host.hasSuffix(".zoom.us"):
            meetingName = "Zoom Web"
        case let host where host == "webex.com" || host.hasSuffix(".webex.com"):
            meetingName = "Webex"
        default:
            meetingName = nil
        }

        guard let meetingName else { return nil }
        return BrowserMeetingMatch(
            meetingName: meetingName,
            browserName: browserName,
            pageTitle: title,
            pageURL: trimmedURL,
        )
    }

    static func meetingSuggestion(fromScriptOutput output: String, browserName: String) -> String? {
        for context in BrowserTabContext.parseMany(output: output) {
            if let match = classify(
                urlString: context.urlString,
                title: context.pageTitle,
                browserName: browserName
            ) {
                return match.suggestionTitle
            }
        }

        return nil
    }

    private static func readBrowserContextOutput(bundleID: String) async -> String? {
        guard let scriptKind = supportedBrowsers[bundleID] else { return nil }

        return await Task.detached(priority: .utility) {
            do {
                return try runAppleScript(script(for: bundleID, kind: scriptKind))
            } catch {
                return nil
            }
        }.value
    }

    private static func script(for bundleID: String, kind: ScriptKind) -> String {
        switch kind {
        case .safari:
            return """
            if application id "\(bundleID)" is not running then return ""
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                set previousDelimiters to AppleScript's text item delimiters
                set AppleScript's text item delimiters to linefeed
                set tabRows to {}
                repeat with windowRef in windows
                    repeat with tabRef in tabs of windowRef
                        set tabURL to URL of tabRef as text
                        set tabTitle to name of tabRef as text
                        if tabURL is not "" then set end of tabRows to tabURL & tab & tabTitle
                    end repeat
                end repeat
                set output to tabRows as text
                set AppleScript's text item delimiters to previousDelimiters
                return output
            end tell
            """
        case .chromium:
            return """
            if application id "\(bundleID)" is not running then return ""
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                set previousDelimiters to AppleScript's text item delimiters
                set AppleScript's text item delimiters to linefeed
                set tabRows to {}
                repeat with windowRef in windows
                    repeat with tabRef in tabs of windowRef
                        set tabURL to URL of tabRef as text
                        set tabTitle to title of tabRef as text
                        if tabURL is not "" then set end of tabRows to tabURL & tab & tabTitle
                    end repeat
                end repeat
                set output to tabRows as text
                set AppleScript's text item delimiters to previousDelimiters
                return output
            end tell
            """
        }
    }

    private static func runAppleScript(_ source: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = Data(stdout.fileHandleForReading.readDataToEndOfFile())
        let error = Data(stderr.fileHandleForReading.readDataToEndOfFile())
        let combined = String(decoding: output + error, as: UTF8.self)

        guard process.terminationStatus == 0 else {
            throw BrowserMeetingDetectorError.appleScriptFailed(combined)
        }

        return combined
    }
}

struct BrowserTabContext: Equatable, Sendable {
    let urlString: String?
    let pageTitle: String?

    init?(output: String) {
        let lines = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard let first = lines.first else { return nil }
        urlString = first
        pageTitle = lines.dropFirst().first
    }

    private init(urlString: String?, pageTitle: String?) {
        self.urlString = urlString
        self.pageTitle = pageTitle
    }

    static func parseMany(output: String) -> [BrowserTabContext] {
        let rows = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let tabSeparated = rows.compactMap { row -> BrowserTabContext? in
            guard row.contains("\t") else { return nil }
            let parts = row.components(separatedBy: "\t")
            guard let first = parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !first.isEmpty else {
                return nil
            }
            let title = parts.dropFirst().joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return BrowserTabContext(
                urlString: first,
                pageTitle: title.isEmpty ? nil : title
            )
        }
        if !tabSeparated.isEmpty {
            return tabSeparated
        }

        return BrowserTabContext(output: output).map { [$0] } ?? []
    }
}

private enum BrowserMeetingDetectorError: Error {
    case appleScriptFailed(String)
}
