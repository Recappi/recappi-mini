import Foundation
import os

enum DiagnosticsLog {
    private static let logger = Logger(subsystem: "recappi.diagnostics", category: "runtime")
    private static let writer = DiagnosticsFileWriter(fileName: "diagnostics.log")

    static var fileURL: URL { writer.fileURL }

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
}

private final class DiagnosticsFileWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "RecappiMini.DiagnosticsFileWriter")
    private let maxBytes = 1_000_000
    let fileURL: URL

    init(fileName: String) {
        let logsDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("RecappiMini", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logsDirectory,
            withIntermediateDirectories: true
        )
        self.fileURL = logsDirectory.appendingPathComponent(fileName)
    }

    func append(_ body: String) {
        let line = "\(Self.timestamp()) \(body)\n"
        queue.async { [fileURL, maxBytes] in
            Self.rotateIfNeeded(fileURL: fileURL, maxBytes: maxBytes)
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

    private static func rotateIfNeeded(fileURL: URL, maxBytes: Int) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue >= maxBytes else {
            return
        }

        let rotated = fileURL.deletingPathExtension()
            .appendingPathExtension("1")
            .appendingPathExtension(fileURL.pathExtension)
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: fileURL, to: rotated)
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
/// without rebuilding the app. Defaults are conservative in release
/// (off) and helpful in DEBUG (on) so developers see the trace stream
/// out of the box.
enum Diagnostics {
    private static let verboseRealtimeKey = "recappi.diagnostics.verboseRealtime"

    /// When true, the realtime live-caption actor emits high-cadence
    /// `rt-trace` entries (per-audio-frame send/exit, per-receive-loop
    /// iter, etc.) into `DiagnosticsLog`. The headline lifecycle and
    /// failure traces remain on regardless of this flag.
    static var verboseRealtime: Bool {
        #if DEBUG
        return UserDefaults.standard.object(forKey: verboseRealtimeKey) as? Bool ?? true
        #else
        return UserDefaults.standard.bool(forKey: verboseRealtimeKey)
        #endif
    }
}
