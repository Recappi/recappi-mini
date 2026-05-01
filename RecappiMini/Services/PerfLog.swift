import Foundation

/// Lightweight timing instrumentation gated behind
/// `RECAPPI_PERF_LOG=1` (see `UITestModeConfiguration.perfLogEnabled`).
///
/// Goals:
/// - Zero overhead when disabled (single bool check + early return).
/// - No PII / no transcript text in the output. Only counts and durations.
/// - Single common prefix `[RecappiPerf]` so log filters are obvious.
///
/// Usage:
/// ```
/// PerfLog.start("loadTranscriptForSelection")
/// // … work …
/// PerfLog.end("loadTranscriptForSelection", extra: "segments=\(count)")
/// ```
/// or for cheap, fire-and-forget timings:
/// ```
/// PerfLog.measure("displaySegmentRows") { /* work */ }
/// ```
enum PerfLog {
    @inline(__always)
    private static var isEnabled: Bool {
        UITestModeConfiguration.shared.perfLogEnabled
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var startTimes: [String: CFAbsoluteTime] = [:]

    static func start(_ label: String) {
        guard isEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        startTimes[label] = now
        lock.unlock()
    }

    static func end(_ label: String, extra: String? = nil) {
        guard isEnabled else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        let started = startTimes.removeValue(forKey: label)
        lock.unlock()
        guard let started else { return }
        let ms = (now - started) * 1000.0
        let suffix = extra.map { " \($0)" } ?? ""
        NSLog("[RecappiPerf] \(label) ms=\(String(format: "%.1f", ms))\(suffix)")
    }

    @discardableResult
    static func measure<T>(_ label: String, extra: String? = nil, _ work: () throws -> T) rethrows -> T {
        guard isEnabled else { return try work() }
        let begin = CFAbsoluteTimeGetCurrent()
        let result = try work()
        let ms = (CFAbsoluteTimeGetCurrent() - begin) * 1000.0
        let suffix = extra.map { " \($0)" } ?? ""
        NSLog("[RecappiPerf] \(label) ms=\(String(format: "%.1f", ms))\(suffix)")
        return result
    }

    /// Fire a milestone event with optional metadata. Useful for code paths
    /// that don't have a clear start/end pair (e.g. an `onAppear` triggered
    /// by SwiftUI render).
    static func event(_ label: String, extra: String? = nil) {
        guard isEnabled else { return }
        let suffix = extra.map { " \($0)" } ?? ""
        NSLog("[RecappiPerf] \(label)\(suffix)")
    }
}
