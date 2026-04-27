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
    private enum ScriptKind: Sendable {
        case arc
        case safari
        case chromium
    }

    private static let supportedBrowsers: [String: ScriptKind] = [
        "com.apple.Safari": .safari,
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.canary": .chromium,
        "com.brave.Browser": .chromium,
        "company.thebrowser.Browser": .arc,
        "com.microsoft.edgemac": .chromium,
        "com.vivaldi.Vivaldi": .chromium,
        "com.operasoftware.Opera": .chromium,
    ]

    static func supports(bundleID: String) -> Bool {
        supportedBrowsers[BundleCollapser.parent(of: bundleID)] != nil
    }

    static func inferMeetingSuggestion(bundleID: String, browserName: String) async -> String? {
        let canonicalBundleID = BundleCollapser.parent(of: bundleID)
        for output in await readBrowserContextOutputs(bundleID: canonicalBundleID) {
            if let suggestion = meetingSuggestion(fromScriptOutput: output, browserName: browserName) {
                return suggestion
            }
        }

        return nil
    }

    static func focusMeetingTab(bundleID: String) async -> Bool {
        let canonicalBundleID = BundleCollapser.parent(of: bundleID)
        guard let scriptKind = supportedBrowsers[canonicalBundleID] else { return false }

        return await Task.detached(priority: .userInitiated) {
            for script in focusScripts(for: canonicalBundleID, kind: scriptKind) {
                do {
                    let output = try runScript(script.source, language: script.language)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if output == "1" { return true }
                } catch {
                    continue
                }
            }

            return false
        }.value
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

    private static func readBrowserContextOutputs(bundleID: String) async -> [String] {
        guard let scriptKind = supportedBrowsers[bundleID] else { return [] }

        return await Task.detached(priority: .utility) {
            var outputs: [String] = []
            for script in scripts(for: bundleID, kind: scriptKind) {
                do {
                    let output = try runScript(script.source, language: script.language)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !output.isEmpty {
                        outputs.append(output)
                    }
                } catch {
                    continue
                }
            }
            return outputs
        }.value
    }

    private static func focusScripts(for bundleID: String, kind: ScriptKind) -> [BrowserScript] {
        switch kind {
        case .arc:
            return [arcFocusMeetingTabScript()]
        case .safari:
            return [safariFocusMeetingTabScript(for: bundleID)]
        case .chromium:
            return [chromiumFocusMeetingTabScript(for: bundleID)]
        }
    }

    private static func scripts(for bundleID: String, kind: ScriptKind) -> [BrowserScript] {
        switch kind {
        case .arc:
            return [
                arcWindowTabsScript(),
                arcSpacesScript(),
                script(for: bundleID, kind: .chromium),
                arcActiveTabScript(),
            ]
        case .safari, .chromium:
            return [script(for: bundleID, kind: kind)]
        }
    }

    private static func arcFocusMeetingTabScript() -> BrowserScript {
        BrowserScript(source: """
        if application "Arc" is not running then return "0"
        tell application "Arc"
            if (count of windows) is 0 then return "0"
            repeat with windowRef in windows
                try
                    repeat with spaceRef in spaces of windowRef
                        try
                            repeat with tabRef in tabs of spaceRef
                                try
                                    set tabURL to URL of tabRef as text
                                    if my recappiIsMeetingURL(tabURL) then
                                        focus spaceRef
                                        select tabRef
                                        set index of windowRef to 1
                                        activate
                                        return "1"
                                    end if
                                end try
                            end repeat
                        end try
                    end repeat
                end try

                try
                    repeat with tabRef in tabs of windowRef
                        try
                            set tabURL to URL of tabRef as text
                            if my recappiIsMeetingURL(tabURL) then
                                select tabRef
                                set index of windowRef to 1
                                activate
                                return "1"
                            end if
                        end try
                    end repeat
                end try
            end repeat
            activate
        end tell
        return "0"

        \(meetingURLAppleScriptHandler)
        """)
    }

    private static func safariFocusMeetingTabScript(for bundleID: String) -> BrowserScript {
        BrowserScript(source: """
        if application id "\(bundleID)" is not running then return "0"
        tell application id "\(bundleID)"
            if (count of windows) is 0 then return "0"
            repeat with windowRef in windows
                repeat with tabRef in tabs of windowRef
                    try
                        set tabURL to URL of tabRef as text
                        if my recappiIsMeetingURL(tabURL) then
                            set current tab of windowRef to tabRef
                            set index of windowRef to 1
                            activate
                            return "1"
                        end if
                    end try
                end repeat
            end repeat
            activate
        end tell
        return "0"

        \(meetingURLAppleScriptHandler)
        """)
    }

    private static func chromiumFocusMeetingTabScript(for bundleID: String) -> BrowserScript {
        BrowserScript(source: """
        if application id "\(bundleID)" is not running then return "0"
        tell application id "\(bundleID)"
            if (count of windows) is 0 then return "0"
            repeat with windowRef in windows
                set tabIndex to 0
                repeat with tabRef in tabs of windowRef
                    set tabIndex to tabIndex + 1
                    try
                        set tabURL to URL of tabRef as text
                        if my recappiIsMeetingURL(tabURL) then
                            set active tab index of windowRef to tabIndex
                            set index of windowRef to 1
                            activate
                            return "1"
                        end if
                    end try
                end repeat
            end repeat
            activate
        end tell
        return "0"

        \(meetingURLAppleScriptHandler)
        """)
    }

    private static let meetingURLAppleScriptHandler = """
    on recappiIsMeetingURL(tabURL)
        set tabURLText to tabURL as text
        return tabURLText contains "://meet.google.com" ¬
            or tabURLText contains ".meet.google.com" ¬
            or tabURLText contains "://teams.microsoft.com" ¬
            or tabURLText contains ".teams.microsoft.com" ¬
            or tabURLText contains "://teams.live.com" ¬
            or tabURLText contains ".teams.live.com" ¬
            or tabURLText contains "://zoom.us" ¬
            or tabURLText contains ".zoom.us" ¬
            or tabURLText contains "://webex.com" ¬
            or tabURLText contains ".webex.com"
    end recappiIsMeetingURL
    """

    private static func arcWindowTabsScript() -> BrowserScript {
        // Arc's AppleScript support is closer to its own dictionary than to
        // Chromium's. This mirrors the stable approach used by Raycast's Arc
        // extension: ask Arc directly for every tab's properties, then extract
        // URL/title from those records.
        BrowserScript(source: """
        if application "Arc" is not running then return ""
        tell application "Arc"
            if (count of windows) is 0 then return ""
            set previousDelimiters to AppleScript's text item delimiters
            set AppleScript's text item delimiters to linefeed
            set tabRows to {}
            repeat with windowRef in windows
                try
                    set allTabs to properties of every tab of windowRef
                    repeat with tabRecord in allTabs
                        try
                            set tabURL to URL of tabRecord as text
                            set tabTitle to title of tabRecord as text
                            if tabURL is not "" then set end of tabRows to tabURL & (ASCII character 9) & tabTitle
                        end try
                    end repeat
                end try
            end repeat
            set output to tabRows as text
            set AppleScript's text item delimiters to previousDelimiters
            return output
        end tell
        """)
    }

    private static func arcSpacesScript() -> BrowserScript {
        // Arc exposes Spaces; its tabs are not reliably represented as
        // plain Chromium `tabs of window`. JXA can walk windows -> spaces
        // -> tabs, with activeTab/window tabs fallbacks for Little Arc and
        // older builds.
        BrowserScript(
            language: "JavaScript",
            source: """
            (() => {
              const app = Application("Arc");
              if (!app.running()) return "";

              const rows = [];
              const seen = {};
              const push = (url, title) => {
                const cleanURL = String(url || "").trim();
                if (!cleanURL) return;
                const cleanTitle = String(title || "").trim();
                const row = cleanURL + "\\t" + cleanTitle;
                if (seen[row]) return;
                seen[row] = true;
                rows.push(row);
              };
              const pushTab = (tab) => {
                try {
                  push(tab.url(), tab.title());
                } catch (_) {}
              };

              try {
                app.windows().forEach((windowRef) => {
                  try { pushTab(windowRef.activeTab()); } catch (_) {}

                  try {
                    windowRef.spaces().forEach((spaceRef) => {
                      try { spaceRef.tabs().forEach(pushTab); } catch (_) {}
                    });
                  } catch (_) {}

                  try { windowRef.tabs().forEach(pushTab); } catch (_) {}
                });
              } catch (_) {}

              return rows.join("\\n");
            })();
            """
        )
    }

    private static func arcActiveTabScript() -> BrowserScript {
        BrowserScript(source: """
        if application "Arc" is not running then return ""
        tell application "Arc"
            if (count of windows) is 0 then return ""
            set activeTabRef to properties of active tab of front window
            return (URL of activeTabRef as text) & (ASCII character 9) & (title of activeTabRef as text)
        end tell
        """)
    }

    private static func script(for bundleID: String, kind: ScriptKind) -> BrowserScript {
        switch kind {
        case .arc:
            return arcSpacesScript()
        case .safari:
            return BrowserScript(source: """
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
                        if tabURL is not "" then set end of tabRows to tabURL & (ASCII character 9) & tabTitle
                    end repeat
                end repeat
                set output to tabRows as text
                set AppleScript's text item delimiters to previousDelimiters
                return output
            end tell
            """)
        case .chromium:
            return BrowserScript(source: """
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
                        if tabURL is not "" then set end of tabRows to tabURL & (ASCII character 9) & tabTitle
                    end repeat
                end repeat
                set output to tabRows as text
                set AppleScript's text item delimiters to previousDelimiters
                return output
            end tell
            """)
        }
    }

    private static func runScript(_ source: String, language: String?) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        if let language {
            process.arguments = ["-l", language, "-e", source]
        } else {
            process.arguments = ["-e", source]
        }

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

private struct BrowserScript: Sendable {
    let language: String?
    let source: String

    init(language: String? = nil, source: String) {
        self.language = language
        self.source = source
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
