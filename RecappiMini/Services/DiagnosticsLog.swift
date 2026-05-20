import Foundation
import os

enum DiagnosticsLog {
    private static let logger = Logger(subsystem: "recappi.diagnostics", category: "runtime")
    private static let writer = DiagnosticsFileWriter(fileName: "diagnostics.log")

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

    private static func append(level: String, category: String, message: String) {
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
        writer.append(line)
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

    func append(_ body: String) {
        let line = "\(Self.timestamp()) \(body)\n"
        queue.async { [fileURL, maxBytes, maxRotatedFiles] in
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

    private static func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
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
