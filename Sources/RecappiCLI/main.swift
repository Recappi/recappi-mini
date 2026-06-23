import Foundation
import RecappiCloudCore

@main
struct RecappiCLI {
    /// Bump when the JSON/JSONL envelope shape changes so agents can guard.
    static let schemaVersion = "2026-06-23"

    static func main() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let mode = OutputMode.resolve(arguments)
        let command = arguments.first.map(commandLabel) ?? "recappi"
        do {
            let exitCode = try await run(arguments: arguments, mode: mode)
            Foundation.exit(exitCode)
        } catch {
            // Usage mistakes become a stable usage.invalid_argument descriptor;
            // everything else flows through the core's descriptor mapping so the
            // exit code / code / retryable / hint all come from one source.
            let descriptor: RecappiCloudErrorDescriptor
            if let cliError = error as? CLIError {
                descriptor = cliError.descriptor
            } else {
                descriptor = .describe(error)
            }
            renderError(command: command, descriptor: descriptor, mode: mode)
            Foundation.exit(descriptor.exitCode)
        }
    }

    private static func run(arguments: [String], mode: OutputMode) async throws -> Int32 {
        // Help only on no-args or an explicit help request. A machine-mode
        // invocation with no command (`recappi --json`) or an unknown top-level
        // flag must hard-fail with a usage error, never print help + exit 0 —
        // an agent would otherwise read success + non-JSON.
        if arguments.isEmpty || arguments.first == "-h" || arguments.first == "--help" || arguments.first == "help" {
            printHelp()
            return 0
        }
        guard let command = arguments.first, !command.hasPrefix("-") else {
            throw CLIError.missingCommand
        }

        switch command {
        case "auth":
            return try await runAuth(arguments: Array(arguments.dropFirst()), mode: mode)
        case "upload":
            return try await runUpload(arguments: Array(arguments.dropFirst()), mode: mode)
        case "jobs":
            return try await runJobs(arguments: Array(arguments.dropFirst()), mode: mode)
        default:
            throw CLIError.unknownCommand(command)
        }
    }

    private static func commandLabel(_ first: String) -> String {
        ["auth", "upload", "jobs"].contains(first) ? first : "recappi"
    }

    // MARK: - auth status

    private static func runAuth(arguments: [String], mode: OutputMode) async throws -> Int32 {
        var parser = ArgumentScanner(arguments)
        let subcommand = parser.popValue() ?? "status"
        guard subcommand == "status" else {
            throw CLIError.unknownCommand("auth \(subcommand)")
        }
        parser.dropModeFlags()
        let origin = parser.popOption("--origin")
        try parser.rejectRemaining()

        do {
            let context = try RecappiCloudAuth().context(explicitOrigin: origin)
            guard let session = try await RecappiCloudAPIClient(context: context).getSession() else {
                throw RecappiCloudError.unauthorized
            }
            let data = AuthData(loggedIn: true, origin: context.origin, email: session.email, userId: session.userId)
            switch mode {
            case .json:
                emitJSONEnvelope(command: "auth status", ok: true, data: data, error: nil)
            case .jsonl:
                emitJSONLTerminal(command: "auth status", data: data, error: nil)
            case .human:
                printOut("✓ Signed in as \(session.email)")
                printErr("  \(context.origin) · \(session.userId)")
            }
            return 0
        } catch let error as RecappiCloudError where error == .notSignedIn || error == .unauthorized {
            let resolvedOrigin = try RecappiCloudOriginResolver().resolve(explicitOrigin: origin)
            let data = AuthData(loggedIn: false, origin: resolvedOrigin, email: nil, userId: nil)
            switch mode {
            case .json:
                // Not-signed-in is a valid, scriptable status answer (ok:true,
                // loggedIn:false) — not an error envelope — but still exit 3.
                emitJSONEnvelope(command: "auth status", ok: true, data: data, error: nil)
            case .jsonl:
                emitJSONLTerminal(command: "auth status", data: data, error: nil)
            case .human:
                printErr("✗ Not logged in.")
                printErr("Open Recappi Mini and sign in, then run this again.")
            }
            return 3
        }
    }

    // MARK: - upload

    private static func runUpload(arguments: [String], mode: OutputMode) async throws -> Int32 {
        var parser = ArgumentScanner(arguments)
        parser.dropModeFlags()
        let transcribe = parser.popFlag("--transcribe")
        let wait = parser.popFlag("--wait")
        let force = parser.popFlag("--force")
        let origin = parser.popOption("--origin")
        let title = parser.popOption("--title")
        let language = parser.popOption("--language") ?? "en"
        let provider = parser.popOption("--provider")
        let prompt = parser.popOption("--prompt")
        guard let path = parser.popValue() else {
            throw CLIError.missingPath
        }
        try parser.rejectRemaining()

        let context = try RecappiCloudAuth().context(explicitOrigin: origin)
        let client = RecappiCloudAPIClient(context: context)
        let uploader = RecappiCloudUploader(client: client)
        let options = RecappiCloudUploadOptions(
            title: title,
            transcribe: transcribe || wait,
            waitForTranscription: wait,
            language: language,
            force: force,
            provider: provider,
            prompt: prompt
        )

        let dedup = LineDedup()
        let batch = try await uploader.uploadPathBatch(URL(fileURLWithPath: path), options: options) { event in
            switch mode {
            case .human:
                guard let line = humanEventLine(event), dedup.shouldPrint(line) else { return }
                printErr(line)
            case .jsonl:
                // Skip the per-file `.finished` (a `result` event): the single
                // terminal result/error line below is the authoritative outcome,
                // so the stream has exactly one terminal event to key on.
                if case .finished = event { return }
                let opEvent = event.operationEvent(command: "upload")
                guard dedup.shouldPrint(jsonlKey(opEvent)) else { return }
                emitJSONLEvent(opEvent)
            case .json:
                return
            }
        }

        let data = UploadData(batch)
        let partial = batch.partialFailureDescriptor

        switch mode {
        case .json:
            emitJSONEnvelope(command: "upload", ok: partial == nil, data: data, error: partial)
        case .jsonl:
            // Terminal line: result on full success, error on any failure (with
            // data still attached so the agent sees successes + per-file errors).
            emitJSONLTerminal(command: "upload", data: data, error: partial)
        case .human:
            for result in batch.successes {
                printErr("✓ Uploaded \(URL(fileURLWithPath: result.filePath).lastPathComponent)")
                printOut(result.recordingId)
                if let transcriptId = result.transcriptId {
                    printErr("  ✓ Transcription complete · transcript \(transcriptId)")
                } else if let jobId = result.jobId {
                    printErr("  transcription \(result.status) · job \(jobId)")
                }
            }
            for failure in batch.failures {
                printErr("✗ \(URL(fileURLWithPath: failure.filePath).lastPathComponent): \(failure.error.message)")
            }
            if batch.totalCount > 1 {
                printErr("\(batch.successes.count)/\(batch.totalCount) uploaded\(batch.failures.isEmpty ? "" : ", \(batch.failures.count) failed")")
            }
        }
        return batch.exitCode
    }

    // MARK: - jobs wait

    private static func runJobs(arguments: [String], mode: OutputMode) async throws -> Int32 {
        var parser = ArgumentScanner(arguments)
        let subcommand = parser.popValue()
        guard subcommand == "wait" else {
            throw CLIError.unknownCommand("jobs \(subcommand ?? "")")
        }
        parser.dropModeFlags()
        let origin = parser.popOption("--origin")
        guard let jobId = parser.popValue() else {
            throw CLIError.missingJobId
        }
        try parser.rejectRemaining()

        let context = try RecappiCloudAuth().context(explicitOrigin: origin)
        let client = RecappiCloudAPIClient(context: context)
        let poller = RecappiCloudJobPoller(client: client)
        let dedup = LineDedup()
        let job = try await poller.waitForCompletion(jobId: jobId) { job in
            switch mode {
            case .human:
                let line = jobProgressLine(job)
                guard dedup.shouldPrint(line) else { return }
                printErr(line)
            case .jsonl:
                let event = RecappiCloudOperationEvent(
                    type: .progress,
                    command: "jobs wait",
                    jobId: job.id,
                    status: job.status.rawValue,
                    percent: job.chunkProgress?.percent
                )
                guard dedup.shouldPrint(jsonlKey(event)) else { return }
                emitJSONLEvent(event)
            case .json:
                return
            }
        }

        let data = JobData(job)
        switch mode {
        case .json:
            emitJSONEnvelope(command: "jobs wait", ok: true, data: data, error: nil)
        case .jsonl:
            emitJSONLTerminal(command: "jobs wait", data: data, error: nil)
        case .human:
            printErr("✓ Transcription complete")
            if let transcriptId = job.transcriptId {
                printOut(transcriptId)
            }
        }
        return 0
    }

    // MARK: - Output helpers

    /// stderr carries progress / human messages / errors so stdout stays a pure
    /// data stream (envelope JSON, JSONL events, or a bare id).
    private static func printErr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private static func printOut(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    private static func emitJSONEnvelope<T: Encodable>(
        command: String,
        ok: Bool,
        data: T?,
        error: RecappiCloudErrorDescriptor?
    ) {
        let envelope = Envelope(ok: ok, command: command, data: data, error: error, meta: Meta(schemaVersion: schemaVersion))
        write(envelope, pretty: true)
    }

    private static func emitJSONLEvent(_ event: RecappiCloudOperationEvent) {
        write(event, pretty: false)
    }

    /// Terminal JSONL line: `result` on success, `error` on failure. Data is
    /// embedded so the agent gets the final payload without a second call.
    private static func emitJSONLTerminal<T: Encodable>(
        command: String,
        data: T?,
        error: RecappiCloudErrorDescriptor?
    ) {
        let terminal = TerminalEvent(
            type: error == nil ? "result" : "error",
            command: command,
            data: data,
            error: error,
            meta: Meta(schemaVersion: schemaVersion)
        )
        write(terminal, pretty: false)
    }

    private static func renderError(command: String, descriptor: RecappiCloudErrorDescriptor, mode: OutputMode) {
        switch mode {
        case .json:
            emitJSONEnvelope(command: command, ok: false, data: Optional<NoData>.none, error: descriptor)
        case .jsonl:
            // Terminal error event, same TerminalEvent shape (with meta) as a
            // successful result so the JSONL contract is uniform.
            emitJSONLTerminal(command: command, data: Optional<NoData>.none, error: descriptor)
        case .human:
            printErr("recappi: \(descriptor.message)")
            if let hint = descriptor.hint {
                printErr("  → \(hint)")
            }
        }
    }

    private static func write<T: Encodable>(_ value: T, pretty: Bool) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    // MARK: - Human progress lines (stderr)

    private static func humanEventLine(_ event: RecappiCloudUploadEvent) -> String? {
        switch event {
        case .creatingRecording(let filePath):
            return "Preparing recording: \(URL(fileURLWithPath: filePath).lastPathComponent)"
        case .uploading(_, let progress):
            return "Uploading… \(percentText(progress * 100))"
        case .completingUpload:
            return "Finishing upload…"
        case .startingTranscription:
            return "Starting transcription…"
        case .transcriptionProgress(_, let status, let percent):
            if let percent { return "Transcribing… \(percentText(percent))" }
            return "Transcribing… \(friendlyStatus(status))"
        case .finished:
            return nil
        }
    }

    private static func jobProgressLine(_ job: RecappiCloudJob) -> String {
        if let percent = job.chunkProgress?.percent { return "Transcribing… \(percentText(percent))" }
        return "Transcribing… \(friendlyStatus(job.status))"
    }

    private static func friendlyStatus(_ status: RecappiCloudJobStatus) -> String {
        switch status {
        case .queued: return "queued"
        case .running: return "in progress"
        case .succeeded: return "done"
        case .failed: return "failed"
        }
    }

    private static func percentText(_ value: Double) -> String {
        "\(Int(max(0, min(100, value)).rounded()))%"
    }

    /// Dedup key for a JSONL event so repeated identical progress polls don't
    /// spam the stream.
    private static func jsonlKey(_ event: RecappiCloudOperationEvent) -> String {
        "\(event.type.rawValue)|\(event.status ?? "")|\(event.percent.map { String(Int($0)) } ?? "")|\(event.filePath ?? "")"
    }

    private static func printHelp() {
        print("""
        recappi — upload local audio to Recappi Cloud and transcribe it.

        Commands:
          recappi auth status [--origin <url>] [--json|--jsonl|--human]
              Show whether you're signed in (reuses the Recappi Mini login).

          recappi upload <file-or-dir> [--transcribe] [--wait] [--title <t>]
                         [--language <lang>] [--provider <p>] [--prompt <text>]
                         [--origin <url>] [--json|--jsonl|--human]
              Upload an audio file (or every supported file in a directory) as a
              new recording. --transcribe starts transcription; --wait blocks
              until it finishes. A directory uploads each file as its own
              recording and reports per-file success/failure.

          recappi jobs wait <jobId> [--origin <url>] [--json|--jsonl|--human]
              Wait for a transcription job to finish.

        For agents: always pass --json (single result) or --jsonl (event stream;
        last line is a `result` or `error` event). Output goes to stdout; human
        progress/messages go to stderr. JSON is the default when stdout is not a
        TTY. Failures still emit a stable {error:{code,retryable,hint}} you can
        branch on; exit codes: 0 ok · 2 usage · 3 not-logged-in · 4 input · 5
        Recappi Cloud.

        Sign in via the Recappi Mini app first; the CLI reuses that login (or set
        RECAPPI_AUTH_TOKEN).

        Agent JSON example:
          $ recappi upload meeting.m4a --transcribe --wait --json
          {"ok":true,"command":"upload","data":{...},"meta":{"schemaVersion":"2026-06-23"}}
        """)
    }
}

// MARK: - Output mode

private enum OutputMode {
    case human, json, jsonl

    /// `--jsonl`/`--json`/`--human` win; otherwise JSON when stdout is not a
    /// TTY (agents/pipes), human when interactive.
    static func resolve(_ arguments: [String]) -> OutputMode {
        if arguments.contains("--jsonl") { return .jsonl }
        if arguments.contains("--json") { return .json }
        if arguments.contains("--human") { return .human }
        return isatty(FileHandle.standardOutput.fileDescriptor) != 0 ? .human : .json
    }
}

// MARK: - Envelopes

private struct Meta: Encodable {
    let schemaVersion: String
}

private struct Envelope<T: Encodable>: Encodable {
    let ok: Bool
    let command: String
    let data: T?
    let error: RecappiCloudErrorDescriptor?
    let meta: Meta
}

private struct TerminalEvent<T: Encodable>: Encodable {
    let type: String
    let command: String
    let data: T?
    let error: RecappiCloudErrorDescriptor?
    let meta: Meta
}

private struct NoData: Encodable {}

private struct AuthData: Encodable {
    let loggedIn: Bool
    let origin: String
    let email: String?
    let userId: String?
}

private struct UploadData: Encodable {
    let successes: [RecappiCloudUploadResult]
    let failures: [RecappiCloudUploadFailure]
    let totalCount: Int
    let attemptedCount: Int

    init(_ batch: RecappiCloudUploadBatchResult) {
        successes = batch.successes
        failures = batch.failures
        totalCount = batch.totalCount
        attemptedCount = batch.attemptedCount
    }
}

private struct JobData: Encodable {
    let jobId: String
    let status: String
    let transcriptId: String?
    let percent: Double?

    init(_ job: RecappiCloudJob) {
        jobId = job.id
        status = job.status.rawValue
        transcriptId = job.transcriptId
        percent = job.chunkProgress?.percent
    }
}

// MARK: - Arg parsing

private struct ArgumentScanner {
    private var arguments: [String]

    init(_ arguments: [String]) {
        self.arguments = arguments
    }

    mutating func popValue() -> String? {
        guard let index = arguments.firstIndex(where: { !$0.hasPrefix("--") }) else {
            return nil
        }
        return arguments.remove(at: index)
    }

    mutating func popFlag(_ name: String) -> Bool {
        guard let index = arguments.firstIndex(of: name) else {
            return false
        }
        arguments.remove(at: index)
        return true
    }

    mutating func popOption(_ name: String) -> String? {
        guard let index = arguments.firstIndex(of: name) else {
            return nil
        }
        arguments.remove(at: index)
        guard index < arguments.count else {
            return nil
        }
        return arguments.remove(at: index)
    }

    /// Output-mode flags are consumed up front by `OutputMode.resolve`; drop
    /// them here so `rejectRemaining()` doesn't treat them as unexpected.
    mutating func dropModeFlags() {
        _ = popFlag("--json")
        _ = popFlag("--jsonl")
        _ = popFlag("--human")
    }

    func rejectRemaining() throws {
        guard arguments.isEmpty else {
            throw CLIError.unexpectedArguments(arguments)
        }
    }
}

private enum CLIError: LocalizedError {
    case unknownCommand(String)
    case missingCommand
    case missingPath
    case missingJobId
    case unexpectedArguments([String])

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let command):
            return "Unknown command: \(command)"
        case .missingCommand:
            return "Missing command."
        case .missingPath:
            return "Missing file or directory path."
        case .missingJobId:
            return "Missing job id."
        case .unexpectedArguments(let arguments):
            return "Unexpected arguments: \(arguments.joined(separator: " "))"
        }
    }

    private var hint: String? {
        switch self {
        case .unknownCommand, .missingCommand:
            return "Run recappi --help for available commands."
        case .missingPath, .missingJobId, .unexpectedArguments:
            return nil
        }
    }

    /// All usage mistakes share the stable `usage.invalid_argument` code / exit 2.
    var descriptor: RecappiCloudErrorDescriptor {
        RecappiCloudErrorDescriptor(
            code: .invalidArgument,
            exitCode: 2,
            retryable: false,
            message: errorDescription ?? "Usage error.",
            hint: hint
        )
    }
}

/// Suppresses consecutive duplicate progress lines/events.
private final class LineDedup: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ""

    func shouldPrint(_ line: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard line != last else { return false }
        last = line
        return true
    }
}
