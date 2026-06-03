import Foundation
import Sentry

enum SentryReporter {
    private static let state = ReporterState()

    static var isEnabledForCurrentProcess: Bool {
        state.isEnabledForCurrentProcess
    }

    static func start() {
        guard ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] != "1" else {
            state.markDisabled(reason: "xcode_preview")
            return
        }
        guard let configuration = ReporterConfiguration.current() else {
            state.markDisabled(reason: "missing_dsn")
            return
        }
        guard state.markStartedIfNeeded(configuration: configuration) else { return }

        SentrySDK.start { options in
            options.dsn = configuration.dsn
            options.environment = configuration.environment
            options.releaseName = configuration.releaseName
            options.dist = configuration.build
            options.sendDefaultPii = false
            options.debug = configuration.debug
            options.diagnosticLevel = .warning
            options.maxBreadcrumbs = 150
            options.attachStacktrace = true
            options.attachAllThreads = false
            options.enableAutoSessionTracking = true
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 2.0
            options.swiftAsyncStacktraces = true
            options.tracesSampleRate = NSNumber(value: configuration.traceSampleRate)
            options.enableCaptureFailedRequests = false
            options.enableMetrics = false
            #if os(macOS)
            options.enableUncaughtNSExceptionReporting = true
            #endif
            #if !os(watchOS)
            options.enableSigtermReporting = configuration.enableSigtermReporting
            #endif
            #if canImport(MetricKit) && !os(tvOS)
            options.enableMetricKit = true
            options.enableMetricKitRawPayload = false
            #endif
            #if !(os(watchOS) || os(tvOS) || os(visionOS))
            if configuration.profileSessionSampleRate > 0 {
                options.configureProfiling = { profiling in
                    profiling.lifecycle = .manual
                    profiling.sessionSampleRate = Float(configuration.profileSessionSampleRate)
                    profiling.profileAppStarts = false
                }
            }
            #endif

            // Keep high-volume auto instrumentation constrained. Recappi uses
            // a low trace/profiling sample rate for jank investigation, while
            // URL/file details stay in the local DiagnosticsLog-safe pipeline.
            options.enableAutoPerformanceTracing = configuration.traceSampleRate > 0
            options.enableNetworkTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableFileIOTracing = false
            options.enableFileManagerSwizzling = false
            options.enableDataSwizzling = false

            options.onLastRunStatusDetermined = { status, _ in
                DiagnosticsLog.event("sentry", "last_run_status=\(String(describing: status))")
            }
        }

        state.markEnabled(SentrySDK.isEnabled)
        startProfilerIfNeeded(configuration)
        configureBaseScope(configuration)
    }

    static func recordDiagnostic(level: String, category: String, message: String) {
        let telemetry = DiagnosticTelemetry(level: level, category: category, message: message)
        let contextSnapshot = state.updateRecordingContext(from: telemetry)

        guard state.isEnabledForCurrentProcess, SentrySDK.isEnabled else { return }

        addBreadcrumb(telemetry)
        if let contextSnapshot {
            configureRecordingScope(contextSnapshot)
        }

        guard telemetry.shouldCaptureError else { return }
        captureDiagnosticError(telemetry, recordingContext: state.recordingContextSnapshot())
    }

    static func setUserIdentity(_ session: UserSession) {
        let user = sentryUser(for: session)
        if state.isEnabledForCurrentProcess, SentrySDK.isEnabled {
            SentrySDK.setUser(user)
        }
        DiagnosticsLog.event("sentry", "user.set userHash=\(session.userId.hashValue)")
    }

    static func clearUserIdentity() {
        if state.isEnabledForCurrentProcess, SentrySDK.isEnabled {
            SentrySDK.setUser(nil)
        }
        DiagnosticsLog.event("sentry", "user.cleared")
    }

    static func pauseAppHangTrackingForExpectedModal(reason: String) {
        guard state.pauseExpectedModalAppHangTracking() else { return }
        if state.isEnabledForCurrentProcess, SentrySDK.isEnabled {
            SentrySDK.pauseAppHangTracking()
        }
        DiagnosticsLog.event("sentry", "app_hang_tracking.pause reason=\(reason)")
    }

    static func resumeAppHangTrackingForExpectedModal(reason: String) {
        guard state.resumeExpectedModalAppHangTracking() else { return }
        if state.isEnabledForCurrentProcess, SentrySDK.isEnabled {
            SentrySDK.resumeAppHangTracking()
        }
        DiagnosticsLog.event("sentry", "app_hang_tracking.resume reason=\(reason)")
    }

    static func sentryUser(for session: UserSession) -> User {
        // Keep `sendDefaultPii = false` meaningful: attach the stable backend
        // user id for support/debugging, but don't send email/name unless the
        // product explicitly opts into that later.
        User(userId: session.userId)
    }

    static func sanitizedTelemetryMessage(_ message: String, maxLength: Int = 1_200) -> String {
        var value = message
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .replacingOccurrences(of: "\"", with: "'")

        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        if !homePath.isEmpty {
            value = value.replacingOccurrences(of: homePath, with: "~")
        }
        value = value.replacingOccurrences(
            of: #"/Users/[^ ]+"#,
            with: "~/…",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"https?://[^ ]+"#,
            with: "<url>",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"(?i)(bearer|token|password|secret)=[^ ]+"#,
            with: "$1=<redacted>",
            options: .regularExpression
        )

        guard value.count > maxLength else { return value }
        return String(value.prefix(maxLength)) + "..."
    }

    static func safeTelemetryFields(from message: String) -> [String: String] {
        let safeKeys: Set<String> = [
            "attempts",
            "appearance",
            "bilingual",
            "build",
            "backend",
            "cloudCaptions",
            "code",
            "contentType",
            "cause",
            "closeCode",
            "deviceHash",
            "diskFreeMb",
            "dir",
            "domain",
            "durationMs",
            "elapsedSeconds",
            "file",
            "generation",
            "includeMic",
            "job",
            "jobID",
            "language",
            "lowPower",
            "method",
            "micBuffers",
            "micIncluded",
            "micLastAgo",
            "mode",
            "outputDevice",
            "originHash",
            "partCount",
            "partSize",
            "path",
            "pid",
            "provider",
            "recording",
            "recordingID",
            "screenCapture",
            "selectedBundle",
            "sessionId",
            "section",
            "sinceOpenMs",
            "size",
            "stage",
            "status",
            "statusCode",
            "systemBuffers",
            "systemLastAgo",
            "transcript",
            "uiTest",
            "userHash",
            "version",
        ]
        var fields: [String: String] = [:]
        for rawToken in message.split(separator: " ") {
            let token = String(rawToken)
            guard let separator = token.firstIndex(of: "=") else { continue }
            let key = String(token[..<separator])
            guard safeKeys.contains(key) else { continue }
            let rawValue = String(token[token.index(after: separator)...])
            let value = sanitizedTelemetryValue(rawValue)
            guard !value.isEmpty else { continue }
            fields[key] = value
        }
        return fields
    }

    static func operationName(from message: String) -> String {
        let firstToken = message.split(separator: " ").first.map(String.init) ?? "unknown"
        guard !firstToken.isEmpty else { return "unknown" }
        return sanitizedTelemetryValue(firstToken, maxLength: 80)
    }

    static func shouldCaptureDiagnosticError(level: String, category: String, message: String) -> Bool {
        DiagnosticTelemetry(level: level, category: category, message: message).shouldCaptureError
    }

    static func diagnosticFingerprint(level: String, category: String, message: String) -> [String] {
        DiagnosticTelemetry(level: level, category: category, message: message).fingerprint
    }

    static func normalizedSampleRate(_ value: String?, default defaultValue: Double) -> Double {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return clampedSampleRate(defaultValue)
        }
        guard let parsed = Double(value), parsed.isFinite else {
            return clampedSampleRate(defaultValue)
        }
        return clampedSampleRate(parsed)
    }

    static func nativeSigtermReportingEnabled(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    private static func addBreadcrumb(_ telemetry: DiagnosticTelemetry) {
        let breadcrumb = Breadcrumb(
            level: sentryLevel(for: telemetry.level),
            category: "recappi.\(telemetry.category)"
        )
        breadcrumb.type = "default"
        breadcrumb.message = telemetry.safeMessage
        breadcrumb.data = telemetry.fields
        SentrySDK.addBreadcrumb(breadcrumb)
    }

    private static func captureDiagnosticError(
        _ telemetry: DiagnosticTelemetry,
        recordingContext: RecordingContextSnapshot
    ) {
        let description = "\(telemetry.category).\(telemetry.operation): \(telemetry.safeMessage)"
        let nsError = NSError(
            domain: "RecappiMini.\(telemetry.category)",
            code: stableCode(for: telemetry.operation),
            userInfo: [
                NSLocalizedDescriptionKey: description,
                "recappi.category": telemetry.category,
                "recappi.operation": telemetry.operation,
                "recappi.message": telemetry.safeMessage,
            ]
        )

        SentrySDK.capture(error: nsError) { scope in
            scope.setLevel(sentryLevel(for: telemetry.level))
            scope.setTag(value: telemetry.category, key: "recappi.category")
            scope.setTag(value: telemetry.operation, key: "recappi.operation")
            scope.setFingerprint(telemetry.fingerprint)
            for (key, value) in recordingContext.tags {
                scope.setTag(value: value, key: key)
            }
            for (key, value) in telemetry.searchableTags {
                scope.setTag(value: value, key: key)
            }
            scope.setContext(
                value: recordingContext.context.merging(telemetry.fields) { _, new in new },
                key: "recappi"
            )
            scope.setContext(
                value: ["message": telemetry.safeMessage],
                key: "diagnostics"
            )
        }
    }

    private static func configureBaseScope(_ configuration: ReporterConfiguration) {
        SentrySDK.configureScope { scope in
            scope.setTag(value: configuration.version, key: "app.version")
            scope.setTag(value: configuration.build, key: "app.build")
            scope.setTag(value: configuration.environment, key: "environment")
            scope.setContext(
                value: [
                    "version": configuration.version,
                    "build": configuration.build,
                    "release": configuration.releaseName,
                    "trace_sample_rate": String(configuration.traceSampleRate),
                    "profile_session_sample_rate": String(configuration.profileSessionSampleRate),
                ],
                key: "recappi_app"
            )
        }
    }

    private static func configureRecordingScope(_ snapshot: RecordingContextSnapshot) {
        SentrySDK.configureScope { scope in
            if let session = snapshot.sessionDir {
                scope.setTag(value: session, key: "recording.session")
            } else {
                scope.removeTag(key: "recording.session")
            }
            if let backend = snapshot.captureBackend {
                scope.setTag(value: backend, key: "recording.backend")
            } else {
                scope.removeTag(key: "recording.backend")
            }
            scope.setContext(value: snapshot.context, key: "recappi_recording")
        }
    }

    private static func sentryLevel(for level: String) -> SentryLevel {
        switch level {
        case "error":
            return .error
        case "warning":
            return .warning
        default:
            return .info
        }
    }

    private static func sanitizedTelemetryValue(_ value: String, maxLength: Int = 200) -> String {
        let trimmed = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitizedTelemetryMessage(trimmed, maxLength: maxLength)
    }

    private static func stableCode(for operation: String) -> Int {
        var hash = UInt32(2_166_136_261)
        for byte in operation.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16_777_619
        }
        return Int(hash & 0x7fff_ffff)
    }

    private static func clampedSampleRate(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private static func startProfilerIfNeeded(_ configuration: ReporterConfiguration) {
        guard state.isEnabledForCurrentProcess, SentrySDK.isEnabled else { return }
        guard configuration.profileSessionSampleRate > 0 else { return }
        #if !(os(watchOS) || os(tvOS) || os(visionOS))
        SentrySDK.startProfiler()
        DiagnosticsLog.event(
            "sentry",
            "profiler.start sampleRate=\(configuration.profileSessionSampleRate) traceSampleRate=\(configuration.traceSampleRate)"
        )
        #endif
    }
}

private struct DiagnosticTelemetry {
    let level: String
    let category: String
    let safeMessage: String
    let operation: String
    let fields: [String: String]

    init(level: String, category: String, message: String) {
        self.level = level
        self.category = SentryReporter.sanitizedTelemetryMessage(category, maxLength: 48)
        self.safeMessage = SentryReporter.sanitizedTelemetryMessage(message)
        self.operation = SentryReporter.operationName(from: message)
        self.fields = SentryReporter.safeTelemetryFields(from: message)
    }

    var shouldCaptureError: Bool {
        guard level == "error" else { return false }
        if category == "crash", operation == "uncaught_exception" {
            return false
        }
        if isCancelledNetworkRequest {
            return false
        }
        if isExpectedClientConnectionFailure {
            return false
        }
        if isExpectedMissingTranscript {
            return false
        }
        if isExpectedSubscriptionRenewal {
            return false
        }
        if isExpectedRealtimeClaimRateLimit {
            return false
        }
        if isTransientLiveCaptionSocketDisconnect {
            return false
        }
        if isExpectedLocalOnlyRecordingDelete404 {
            return false
        }
        if isExpectedRecordingUploadLayerNoise {
            return false
        }
        return true
    }

    private var isCancelledNetworkRequest: Bool {
        fields["domain"] == NSURLErrorDomain && fields["code"] == String(NSURLErrorCancelled)
    }

    private var isExpectedClientConnectionFailure: Bool {
        switch (fields["domain"], fields["code"]) {
        case (NSURLErrorDomain, String(NSURLErrorSecureConnectionFailed)),
             (NSURLErrorDomain, String(NSURLErrorNotConnectedToInternet)),
             (NSPOSIXErrorDomain, "57"):
            return true
        default:
            return false
        }
    }

    private var isExpectedMissingTranscript: Bool {
        let message = safeMessage.lowercased()
        let isTranscript404 = message.contains("status 404")
            && message.contains("transcript not found")
        guard isTranscript404 else { return false }

        if category == "network", operation == "request.failed" {
            return fields["path"]?.contains("/transcript") == true
        }
        if category == "cloud", operation == "transcript.load.failed" {
            return true
        }
        return false
    }

    private var isExpectedSubscriptionRenewal: Bool {
        let message = safeMessage.lowercased()
        guard message.contains("status 503"),
              message.contains("subscription is renewing") else {
            return false
        }

        switch (category, operation) {
        case ("network", "request.failed"),
             ("processing", "upload.failed"),
             ("processing", "process.failed"):
            return true
        default:
            return false
        }
    }

    private var isExpectedRealtimeClaimRateLimit: Bool {
        let message = safeMessage.lowercased()
        guard message.contains("status 429"),
              message.contains("session claim rate exceeded") else {
            return false
        }

        switch (category, operation) {
        case ("network", "request.failed"):
            return fields["path"] == "/api/openai/realtime/sessions"
        case ("live-caption", "claim.failed"):
            return true
        default:
            return false
        }
    }

    private var isTransientLiveCaptionSocketDisconnect: Bool {
        guard category == "live-caption",
              operation == "ws.failed",
              fields["cause"] == "receive.throw" else {
            return false
        }

        if fields["closeCode"] == "1005",
           fields["domain"] == NSPOSIXErrorDomain,
           fields["code"] == "57" {
            return true
        }

        return fields["closeCode"] == "0"
            && fields["domain"] == NSURLErrorDomain
            && fields["code"] == String(NSURLErrorSecureConnectionFailed)
    }

    private var isExpectedLocalOnlyRecordingDelete404: Bool {
        let message = safeMessage.lowercased()
        guard message.contains("status 404"),
              message.contains("recording not found") else {
            return false
        }

        switch (category, operation) {
        case ("network", "request.failed"):
            return fields["method"] == "DELETE"
                && fields["path"]?.contains("/api/recordings/local-") == true
        case ("cloud", "recording.delete.failed"):
            return fields["recordingID"]?.hasPrefix("local-") == true
        default:
            return false
        }
    }

    private var isExpectedRecordingUploadLayerNoise: Bool {
        switch (category, operation) {
        case ("network", "request.failed"):
            return fields["method"] == "PUT"
                && normalizedRequestPath?.range(
                    of: #"^/api/recordings/:id/parts/\d+$"#,
                    options: .regularExpression
                ) != nil
        case ("processing", "upload.attempt.failed"):
            return true
        case ("recording-panel", "process_session.failed"):
            return true
        default:
            return false
        }
    }

    var fingerprint: [String] {
        var parts = ["recappi", category, operation]
        guard category == "network", operation == "request.failed" else {
            return parts
        }

        appendFingerprintField("method", from: fields["method"], to: &parts)
        appendFingerprintField("path", from: normalizedRequestPath, to: &parts)
        appendFingerprintField("status", from: httpStatusCode, to: &parts)
        appendFingerprintField("domain", from: fields["domain"], to: &parts)
        appendFingerprintField("code", from: fields["code"], to: &parts)
        return parts
    }

    private var normalizedRequestPath: String? {
        guard var path = fields["path"], !path.isEmpty else { return nil }
        path = path.replacingOccurrences(
            of: #"/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(?=/|$)"#,
            with: "/:id",
            options: .regularExpression
        )
        path = path.replacingOccurrences(
            of: #"/rec_[A-Za-z0-9_-]+(?=/|$)"#,
            with: "/:recording",
            options: .regularExpression
        )
        return path
    }

    private var httpStatusCode: String? {
        if let statusCode = fields["statusCode"], Self.isThreeDigitStatus(statusCode) {
            return statusCode
        }
        if let status = fields["status"], Self.isThreeDigitStatus(status) {
            return status
        }
        let nsMessage = safeMessage as NSString
        let regex = try? NSRegularExpression(pattern: #"status[ =](\d{3})"#, options: [.caseInsensitive])
        guard let match = regex?.firstMatch(
            in: safeMessage,
            range: NSRange(location: 0, length: nsMessage.length)
        ) else {
            return nil
        }
        let range = match.range(at: 1)
        guard range.location != NSNotFound else { return nil }
        return nsMessage.substring(with: range)
    }

    private static func isThreeDigitStatus(_ value: String) -> Bool {
        value.range(of: #"^\d{3}$"#, options: .regularExpression) != nil
    }

    private func appendFingerprintField(_ key: String, from value: String?, to parts: inout [String]) {
        guard let value, !value.isEmpty else { return }
        parts.append("\(key):\(value)")
    }

    var searchableTags: [String: String] {
        var tags: [String: String] = [:]
        for key in [
            "dir",
            "recording",
            "recordingID",
            "job",
            "jobID",
            "stage",
            "status",
            "file",
            "provider",
            "backend",
            "domain",
            "code",
            "statusCode",
            "mode",
        ] {
            guard let value = fields[key], !value.isEmpty else { continue }
            tags["diag.\(key)"] = value
        }
        return tags
    }
}

private struct ReporterConfiguration: Equatable {
    let dsn: String
    let environment: String
    let version: String
    let build: String
    let bundleIdentifier: String
    let debug: Bool
    let traceSampleRate: Double
    let profileSessionSampleRate: Double
    let enableSigtermReporting: Bool

    var releaseName: String {
        "\(bundleIdentifier)@\(version)+\(build)"
    }

    static func current() -> ReporterConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        let bundle = Bundle.main
        let dsn = [
            environment["RECAPPI_SENTRY_DSN"],
            environment["SENTRY_DSN"],
            bundle.object(forInfoDictionaryKey: "SentryDSN") as? String,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }

        guard let dsn else { return nil }

        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let bundleIdentifier = bundle.bundleIdentifier ?? "com.recappi.mini"
        let sentryEnvironment = environment["SENTRY_ENVIRONMENT"]
            ?? (bundle.object(forInfoDictionaryKey: "SentryEnvironment") as? String)
            ?? "production"
        let debug = environment["RECAPPI_SENTRY_DEBUG"] == "1"
        let traceSampleRate = SentryReporter.normalizedSampleRate(
            environment["RECAPPI_SENTRY_TRACE_SAMPLE_RATE"] ?? environment["SENTRY_TRACES_SAMPLE_RATE"],
            default: 0.05
        )
        let profileSessionSampleRate = SentryReporter.normalizedSampleRate(
            environment["RECAPPI_SENTRY_PROFILE_SAMPLE_RATE"] ?? environment["SENTRY_PROFILES_SAMPLE_RATE"],
            default: 0.10
        )
        let enableSigtermReporting = SentryReporter.nativeSigtermReportingEnabled(
            environment["RECAPPI_SENTRY_ENABLE_SIGTERM_REPORTING"]
        )
        return ReporterConfiguration(
            dsn: dsn,
            environment: sentryEnvironment,
            version: version,
            build: build,
            bundleIdentifier: bundleIdentifier,
            debug: debug,
            traceSampleRate: traceSampleRate,
            profileSessionSampleRate: profileSessionSampleRate,
            enableSigtermReporting: enableSigtermReporting
        )
    }
}

private struct RecordingContextSnapshot: Equatable {
    var sessionDir: String?
    var captureBackend: String?
    var selectedBundle: String?
    var includeMic: String?
    var language: String?
    var captureHealth: String?

    var tags: [String: String] {
        var result: [String: String] = [:]
        if let sessionDir { result["recording.session"] = sessionDir }
        if let captureBackend { result["recording.backend"] = captureBackend }
        if let includeMic { result["recording.include_mic"] = includeMic }
        return result
    }

    var context: [String: String] {
        var result: [String: String] = [:]
        if let sessionDir { result["session_dir"] = sessionDir }
        if let captureBackend { result["capture_backend"] = captureBackend }
        if let selectedBundle { result["selected_bundle"] = selectedBundle }
        if let includeMic { result["include_mic"] = includeMic }
        if let language { result["language"] = language }
        if let captureHealth { result["capture_health"] = captureHealth }
        return result
    }
}

private final class ReporterState: @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    private var enabled = false
    private var disabledReason: String?
    private var configuration: ReporterConfiguration?
    private var recordingContext = RecordingContextSnapshot()
    private var appHangPauseGate = AppHangTrackingPauseGate()

    var isEnabledForCurrentProcess: Bool {
        lock.withLock { enabled }
    }

    func markStartedIfNeeded(configuration: ReporterConfiguration) -> Bool {
        lock.withLock {
            guard !didStart else { return false }
            didStart = true
            self.configuration = configuration
            return true
        }
    }

    func markEnabled(_ enabled: Bool) {
        lock.withLock {
            self.enabled = enabled
            self.disabledReason = enabled ? nil : "sdk_disabled"
        }
    }

    func markDisabled(reason: String) {
        lock.withLock {
            didStart = true
            enabled = false
            disabledReason = reason
        }
    }

    func pauseExpectedModalAppHangTracking() -> Bool {
        lock.withLock { appHangPauseGate.pause() }
    }

    func resumeExpectedModalAppHangTracking() -> Bool {
        lock.withLock { appHangPauseGate.resume() }
    }

    func updateRecordingContext(from telemetry: DiagnosticTelemetry) -> RecordingContextSnapshot? {
        lock.withLock {
            var next = recordingContext
            switch (telemetry.category, telemetry.operation) {
            case ("recording", "start.request"):
                next = RecordingContextSnapshot()
                next.selectedBundle = telemetry.fields["selectedBundle"]
                next.includeMic = telemetry.fields["includeMic"]
                next.language = telemetry.fields["language"]
            case ("recording", "session.created"),
                 ("recording", "stop.request"),
                 ("recording", "discard.request"),
                 ("processing", "process.start"),
                 ("processing", "process.failed"),
                 ("processing", "process.succeeded"):
                if let dir = telemetry.fields["dir"] {
                    next.sessionDir = dir
                }
            case ("recording", "system_audio.backend"):
                next.captureBackend = telemetry.safeMessage
                    .split(separator: " ")
                    .last
                    .map(String.init)
            case ("recording", "capture.health"):
                next.captureHealth = telemetry.safeMessage
            default:
                break
            }
            guard next != recordingContext else { return nil }
            recordingContext = next
            return next
        }
    }

    func recordingContextSnapshot() -> RecordingContextSnapshot {
        lock.withLock { recordingContext }
    }
}

struct AppHangTrackingPauseGate: Equatable {
    private(set) var depth = 0

    var isPaused: Bool {
        depth > 0
    }

    mutating func pause() -> Bool {
        depth += 1
        return depth == 1
    }

    mutating func resume() -> Bool {
        guard depth > 0 else { return false }
        depth -= 1
        return depth == 0
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
