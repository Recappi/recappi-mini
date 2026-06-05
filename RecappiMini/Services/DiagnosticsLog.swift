import Foundation
import os

enum DiagnosticsLog {
    private static let logger = Logger(subsystem: "recappi.diagnostics", category: "runtime")
    private static let writer = DiagnosticsFileWriter(fileName: "diagnostics.log")
    private static let crashHandlerInstaller = DiagnosticsCrashHandlerInstaller()

    static var fileURL: URL { writer.fileURL }
    static var logsDirectoryURL: URL { writer.logsDirectoryURL }

    static func event(_ category: String, _ message: String) {
        append(level: "info", category: category, message: message)
    }

    static func warning(_ category: String, _ message: String) {
        append(level: "warning", category: category, message: message)
    }

    static func error(_ category: String, _ message: String) {
        append(level: "error", category: category, message: message)
    }

    static func critical(_ category: String, _ message: String) {
        append(level: "error", category: category, message: message, synchronously: true)
    }

    static func installCrashHandlers() {
        crashHandlerInstaller.install()
    }

    static func createLogArchive() throws -> URL {
        writer.flush()
        let archiveURL = try DiagnosticsLogArchive.create(
            logsDirectory: logsDirectoryURL,
            currentLogURL: fileURL
        )
        event("diagnostics", "archive.created file=\(archiveURL.lastPathComponent)")
        return archiveURL
    }

    static func errorSummary(_ error: Error) -> String {
        let nsError = error as NSError
        let message = error.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return "domain=\(nsError.domain) code=\(nsError.code) message=\(sanitize(message))"
    }

    static func sanitize(_ value: String, maxLength: Int = 240) -> String {
        let collapsed = value
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .replacingOccurrences(of: "\"", with: "'")
        guard collapsed.count > maxLength else { return collapsed }
        return String(collapsed.prefix(maxLength)) + "..."
    }

    private static func append(
        level: String,
        category: String,
        message: String,
        synchronously: Bool = false
    ) {
        let safeCategory = sanitize(category, maxLength: 48)
        let safeMessage = sanitize(message, maxLength: 1_200)
        let line = "level=\(level) category=\(safeCategory) \(safeMessage)"
        switch level {
        case "error":
            logger.error("\(line, privacy: .public)")
        case "warning":
            logger.warning("\(line, privacy: .public)")
        default:
            logger.info("\(line, privacy: .public)")
        }
        SentryReporter.recordDiagnostic(level: level, category: safeCategory, message: safeMessage)
        writer.append(line, synchronously: synchronously)
    }

    #if DEBUG
    static func flushForTests() {
        writer.flush()
    }
    #endif
}

final class DiagnosticsFileWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let maxBytes: Int
    private let maxRotatedFiles: Int
    let fileURL: URL

    var logsDirectoryURL: URL { fileURL.deletingLastPathComponent() }

    init(
        fileName: String,
        directory logsDirectory: URL = DiagnosticsFileWriter.defaultLogsDirectory,
        maxBytes: Int = 1_000_000,
        maxRotatedFiles: Int = 5
    ) {
        self.queue = DispatchQueue(label: "RecappiMini.DiagnosticsFileWriter.\(UUID().uuidString)")
        self.maxBytes = maxBytes
        self.maxRotatedFiles = max(0, maxRotatedFiles)
        try? FileManager.default.createDirectory(
            at: logsDirectory,
            withIntermediateDirectories: true
        )
        self.fileURL = logsDirectory.appendingPathComponent(fileName)
    }

    func append(_ body: String, synchronously: Bool = false) {
        let line = "\(Self.timestamp()) \(body)\n"
        let work: @Sendable () -> Void = { [fileURL, maxBytes, maxRotatedFiles] in
            Self.rotateIfNeeded(
                fileURL: fileURL,
                maxBytes: maxBytes,
                maxRotatedFiles: maxRotatedFiles
            )
            guard let data = line.data(using: .utf8) else { return }
            if FileManager.default.fileExists(atPath: fileURL.path),
               let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL, options: .atomic)
            }
        }
        if synchronously {
            queue.sync(execute: work)
        } else {
            queue.async(execute: work)
        }
    }

    func flush() {
        queue.sync {}
    }

    static var defaultLogsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("RecappiMini", isDirectory: true)
    }

    private static func rotateIfNeeded(fileURL: URL, maxBytes: Int, maxRotatedFiles: Int) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue >= maxBytes else {
            return
        }

        let fileManager = FileManager.default
        guard maxRotatedFiles > 0 else {
            try? fileManager.removeItem(at: fileURL)
            return
        }

        let oldest = rotatedURL(for: fileURL, index: maxRotatedFiles)
        try? fileManager.removeItem(at: oldest)

        if maxRotatedFiles > 1 {
            for index in stride(from: maxRotatedFiles - 1, through: 1, by: -1) {
                let source = rotatedURL(for: fileURL, index: index)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let destination = rotatedURL(for: fileURL, index: index + 1)
                try? fileManager.removeItem(at: destination)
                try? fileManager.moveItem(at: source, to: destination)
            }
        }

        let first = rotatedURL(for: fileURL, index: 1)
        try? fileManager.removeItem(at: first)
        try? fileManager.moveItem(at: fileURL, to: first)
    }

    private static func rotatedURL(for fileURL: URL, index: Int) -> URL {
        let directory = fileURL.deletingLastPathComponent()
        let stem = fileURL.deletingPathExtension().lastPathComponent
        let ext = fileURL.pathExtension
        let rotatedName = "\(stem).\(index)"
        guard !ext.isEmpty else {
            return directory.appendingPathComponent(rotatedName)
        }
        return directory
            .appendingPathComponent(rotatedName)
            .appendingPathExtension(ext)
    }

    /// Cached once. Allocating an `ISO8601DateFormatter` per appended line is the
    /// single most expensive part of `append` on the hot path (`DiagnosticsLog`
    /// can emit dozens of lines/second during a recording). `ISO8601DateFormatter`
    /// is thread-safe for formatting, so a shared instance is safe here even though
    /// `append` is invoked from arbitrary threads before hopping onto `queue`.
    /// Output is byte-identical to the previous per-call formatter (same options +
    /// UTC timezone). The formatter is non-Sendable and lives in a nonisolated
    /// context, so `nonisolated(unsafe)` is the sound annotation for a value that
    /// is configured once and thereafter only read (formatted) concurrently.
    private nonisolated(unsafe) static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }
}

private final class DiagnosticsCrashHandlerInstaller: @unchecked Sendable {
    private let lock = NSLock()
    private var didInstall = false

    func install() {
        lock.lock()
        defer { lock.unlock() }
        guard !didInstall else { return }
        didInstall = true
        DiagnosticsExceptionHandlerState.previousHandler = NSGetUncaughtExceptionHandler()
        NSSetUncaughtExceptionHandler(recappiUncaughtExceptionHandler)
        DiagnosticsLog.event("crash", "objc_exception_handler.installed")
    }
}

private enum DiagnosticsExceptionHandlerState {
    nonisolated(unsafe) static var previousHandler: NSUncaughtExceptionHandler?
}

private let recappiUncaughtExceptionHandler: @convention(c) (NSException) -> Void = { exception in
    let stack = exception.callStackSymbols
        .prefix(12)
        .joined(separator: " | ")
    DiagnosticsLog.critical(
        "crash",
        "uncaught_exception name=\(DiagnosticsLog.sanitize(exception.name.rawValue, maxLength: 80)) reason='\(DiagnosticsLog.sanitize(exception.reason ?? "none", maxLength: 300))' stack='\(DiagnosticsLog.sanitize(stack, maxLength: 1_200))'"
    )
    DiagnosticsExceptionHandlerState.previousHandler?(exception)
}

enum DiagnosticsLogArchive {
    static func create(logsDirectory: URL, currentLogURL: URL, now: Date = Date()) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        let logFiles = try fileManager.contentsOfDirectory(
            at: logsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            let name = url.lastPathComponent
            return name == currentLogURL.lastPathComponent
                || (name.hasPrefix("diagnostics.") && name.hasSuffix(".log"))
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !logFiles.isEmpty else {
            throw DiagnosticsLogArchiveError.noLogFiles
        }

        let stamp = archiveTimestamp(now)
        let staging = logsDirectory.appendingPathComponent(".RecappiMiniLogs-\(stamp)", isDirectory: true)
        let archive = logsDirectory.appendingPathComponent("RecappiMiniLogs-\(stamp).zip")
        try? fileManager.removeItem(at: staging)
        try? fileManager.removeItem(at: archive)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        for file in logFiles {
            try fileManager.copyItem(
                at: file,
                to: staging.appendingPathComponent(file.lastPathComponent)
            )
        }

        let manifest = supportBundleManifest(
            generatedAt: ISO8601DateFormatter().string(from: now),
            logFiles: logFiles.map(\.lastPathComponent)
        )
        try manifest.write(
            to: staging.appendingPathComponent("README.txt"),
            atomically: true,
            encoding: .utf8
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--keepParent", staging.lastPathComponent, archive.lastPathComponent]
        process.currentDirectoryURL = logsDirectory
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              fileManager.fileExists(atPath: archive.path) else {
            throw DiagnosticsLogArchiveError.archiveFailed(status: process.terminationStatus)
        }

        return archive
    }

    private static func archiveTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func supportBundleManifest(generatedAt: String, logFiles: [String]) -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return """
        Recappi Mini diagnostics logs
        Generated: \(generatedAt)
        App: \(version) (\(build))
        OS: \(ProcessInfo.processInfo.operatingSystemVersionString)

        Files:
        \(logFiles.map { "- \($0)" }.joined(separator: "\n"))

        Send this zip file to Recappi support when reporting recording, upload, auth, Cloud, or update issues.
        """
    }
}

enum DiagnosticsLogArchiveError: LocalizedError, Equatable {
    case noLogFiles
    case archiveFailed(status: Int32)

    var errorDescription: String? {
        switch self {
        case .noLogFiles:
            return "No diagnostics log files were found."
        case .archiveFailed(let status):
            return "Could not create the diagnostics archive (ditto exited with status \(status))."
        }
    }
}

/// Diagnostic feature flags. Lightweight UserDefaults-backed toggles
/// that let support / dogfooders opt into verbose trace categories
/// without rebuilding the app. Defaults are conservative in both
/// release and DEBUG (off) — the high-cadence streams overflow the
/// 1 MB log rotation in under two minutes, so engineers opt in
/// explicitly via the UserDefaults key when reproducing an issue.
/// Values are read once at first access (see `cachedVerboseRealtime`)
/// and require an app restart to change.
enum Diagnostics {
    private static let verboseRealtimeKey = "recappi.diagnostics.verboseRealtime"

    /// Cached once at first access. `static let` is lazily initialised and
    /// thread-safe (dispatch_once-equivalent), so the hot-path read in
    /// `verboseRealtime` is a single load instead of a UserDefaults trip
    /// per audio frame (~50/s). Trade-off: flipping the UserDefaults key
    /// at runtime requires an app restart to take effect — acceptable
    /// because diagnostic toggles are set once per debug session.
    ///
    /// DEBUG default is `false` to match release: the 1 MB log rotation
    /// would otherwise spill the headline lifecycle traces inside ~60-90s
    /// of speech. Engineers opt in explicitly via the UserDefaults key
    /// when reproducing.
    private static let cachedVerboseRealtime: Bool = {
        #if DEBUG
        return UserDefaults.standard.object(forKey: verboseRealtimeKey) as? Bool ?? false
        #else
        return UserDefaults.standard.bool(forKey: verboseRealtimeKey)
        #endif
    }()

    /// When true, the realtime live-caption actor emits high-cadence
    /// `rt-trace` entries (per-audio-frame send/exit, per-receive-loop
    /// iter, etc.) into `DiagnosticsLog`. The headline lifecycle and
    /// failure traces remain on regardless of this flag.
    static var verboseRealtime: Bool { cachedVerboseRealtime }
}
