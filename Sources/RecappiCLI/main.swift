import Foundation
import RecappiCloudCore

@main
struct RecappiCLI {
    static func main() async {
        do {
            let exitCode = try await run(arguments: Array(CommandLine.arguments.dropFirst()))
            Foundation.exit(exitCode)
        } catch {
            let (message, code) = describe(error)
            printErr("recappi: \(message)")
            Foundation.exit(code)
        }
    }

    /// Map an error to a human, actionable message + a stable exit code:
    /// 1 general · 2 usage · 3 not-logged-in · 4 input/file · 5 server/conflict.
    private static func describe(_ error: Error) -> (String, Int32) {
        if let error = error as? RecappiCloudError {
            switch error {
            case .notSignedIn, .unauthorized:
                return ("Not logged in. Open Recappi Mini and sign in, then run this again.", 3)
            case .fileMissing, .unsupportedFileType, .durationUnavailable, .directoryHasNoSupportedFiles:
                return (error.errorDescription ?? "Input error.", 4)
            case .http(let statusCode, _):
                switch statusCode {
                case 401, 403:
                    return ("Not logged in. Open Recappi Mini and sign in, then run this again.", 3)
                case 409:
                    return ("Another upload is already in progress for your account. Wait for it to finish, then retry.", 5)
                default:
                    return (error.errorDescription ?? "Recappi Cloud request failed.", 5)
                }
            case .recordingNotReady, .jobFailed, .jobTimedOut, .invalidResponse, .invalidURL:
                return (error.errorDescription ?? "Something went wrong.", 1)
            }
        }
        if let error = error as? CLIError {
            return (error.errorDescription ?? "Usage error.", 2)
        }
        return (error.localizedDescription, 1)
    }

    /// Progress, status, and errors go to stderr so stdout stays a clean data
    /// stream (pure JSON under `--json`, pipeable result lines otherwise).
    private static func printErr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func run(arguments: [String]) async throws -> Int32 {
        guard let command = arguments.first else {
            printHelp()
            return 0
        }

        switch command {
        case "auth":
            return try await runAuth(arguments: Array(arguments.dropFirst()))
        case "upload":
            return try await runUpload(arguments: Array(arguments.dropFirst()))
        case "jobs":
            return try await runJobs(arguments: Array(arguments.dropFirst()))
        case "-h", "--help", "help":
            printHelp()
            return 0
        default:
            throw CLIError.unknownCommand(command)
        }
    }

    private static func runAuth(arguments: [String]) async throws -> Int32 {
        var parser = ArgumentScanner(arguments)
        let subcommand = parser.popValue() ?? "status"
        guard subcommand == "status" else {
            throw CLIError.unknownCommand("auth \(subcommand)")
        }
        let json = parser.popFlag("--json")
        let origin = parser.popOption("--origin")
        try parser.rejectRemaining()

        // Not logged in is a normal status answer, not a crash. `context()`
        // throws `.notSignedIn` when no token is found, so catch that (and an
        // expired session) here and report cleanly with exit code 3 — still
        // emitting `{loggedIn:false}` under --json so scripts get stable output.
        do {
            let context = try RecappiCloudAuth().context(explicitOrigin: origin)
            guard let session = try await RecappiCloudAPIClient(context: context).getSession() else {
                throw RecappiCloudError.unauthorized
            }
            if json {
                try printJSON(AuthStatusOutput(loggedIn: true, origin: context.origin, email: session.email, userId: session.userId))
            } else {
                print("✓ Signed in as \(session.email)")
                printErr("  \(context.origin) · \(session.userId)")
            }
            return 0
        } catch let error as RecappiCloudError where error == .notSignedIn || error == .unauthorized {
            let resolvedOrigin = RecappiCloudOriginResolver().resolve(explicitOrigin: origin)
            if json {
                try printJSON(AuthStatusOutput(loggedIn: false, origin: resolvedOrigin, email: nil, userId: nil))
            } else {
                printErr("✗ Not logged in.")
                printErr("Open Recappi Mini and sign in, then run this again.")
            }
            return 3
        }
    }

    private static func runUpload(arguments: [String]) async throws -> Int32 {
        var parser = ArgumentScanner(arguments)
        let json = parser.popFlag("--json")
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
        let results = try await uploader.uploadPath(URL(fileURLWithPath: path), options: options) { event in
            guard !json, let line = humanEventLine(event), dedup.shouldPrint(line) else { return }
            printErr(line)
        }

        if json {
            try printJSON(results.map(UploadOutput.init))
        } else {
            for result in results {
                let name = URL(fileURLWithPath: result.filePath).lastPathComponent
                printErr("✓ Uploaded \(name)")
                print(result.recordingId)
                if let transcriptId = result.transcriptId {
                    printErr("✓ Transcription complete")
                    printErr("  transcript \(transcriptId)")
                } else if let jobId = result.jobId {
                    printErr("  transcription \(result.status) · job \(jobId)")
                }
            }
            if results.count > 1 {
                printErr("✓ \(results.count) files uploaded")
            }
        }
        return 0
    }

    private static func runJobs(arguments: [String]) async throws -> Int32 {
        var parser = ArgumentScanner(arguments)
        let subcommand = parser.popValue()
        guard subcommand == "wait" else {
            throw CLIError.unknownCommand("jobs \(subcommand ?? "")")
        }
        let json = parser.popFlag("--json")
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
            guard !json else { return }
            let line = jobProgressLine(job)
            guard dedup.shouldPrint(line) else { return }
            printErr(line)
        }

        if json {
            try printJSON(JobOutput(job))
        } else {
            printErr("✓ Transcription complete")
            if let transcriptId = job.transcriptId {
                print(transcriptId)
            }
        }
        return 0
    }

    /// One-line human description of an upload event, or nil for events with no
    /// user-facing line. Progress never exposes internal chunk/part counts —
    /// only an overall percentage, matching the app/web treatment.
    private static func humanEventLine(_ event: RecappiCloudUploadEvent) -> String? {
        switch event {
        case .creatingRecording(let filePath):
            return "Creating recording: \(URL(fileURLWithPath: filePath).lastPathComponent)"
        case .uploading(_, let progress):
            return "Uploading… \(percentText(progress * 100))"
        case .completingUpload:
            return "Finishing upload…"
        case .startingTranscription:
            return "Starting transcription…"
        case .transcriptionProgress(_, let status, let percent):
            if let percent {
                return "Transcribing… \(percentText(percent))"
            }
            return "Transcribing… \(friendlyStatus(status))"
        case .finished:
            return nil
        }
    }

    private static func jobProgressLine(_ job: RecappiCloudJob) -> String {
        if let percent = job.chunkProgress?.percent {
            return "Transcribing… \(percentText(percent))"
        }
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

    private static func printJSON<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func printHelp() {
        print("""
        recappi — upload local audio to Recappi Cloud and transcribe it.

        Commands:
          recappi auth status [--origin <url>] [--json]
              Show whether you're signed in (reuses the Recappi Mini login).

          recappi upload <file-or-dir> [--transcribe] [--wait] [--title <t>]
                         [--language <lang>] [--provider <p>] [--prompt <text>]
                         [--origin <url>] [--json]
              Upload an audio file (or every supported file in a directory) as a
              new recording. --transcribe also starts transcription; --wait
              blocks until it finishes.

          recappi jobs wait <jobId> [--origin <url>] [--json]
              Wait for a transcription job to finish.

        Output: results go to stdout (recording/transcript ids; pure JSON with
        --json); progress and messages go to stderr. Exit codes: 0 ok · 2 usage
        · 3 not logged in · 4 file/input · 5 Recappi Cloud error.

        Sign in via the Recappi Mini app first; the CLI reuses that login.
        """)
    }
}

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

    func rejectRemaining() throws {
        guard arguments.isEmpty else {
            throw CLIError.unexpectedArguments(arguments)
        }
    }
}

private enum CLIError: LocalizedError {
    case unknownCommand(String)
    case missingPath
    case missingJobId
    case unexpectedArguments([String])

    var errorDescription: String? {
        switch self {
        case .unknownCommand(let command):
            return "Unknown command: \(command)"
        case .missingPath:
            return "Missing file or directory path."
        case .missingJobId:
            return "Missing job id."
        case .unexpectedArguments(let arguments):
            return "Unexpected arguments: \(arguments.joined(separator: " "))"
        }
    }
}

private struct AuthStatusOutput: Encodable {
    let loggedIn: Bool
    let origin: String
    let email: String?
    let userId: String?
}

/// Suppresses consecutive duplicate progress lines (the job poller emits the
/// same percentage across polls). `@unchecked Sendable` is safe here: a single
/// CLI invocation drives one sequential progress stream, and the lock guards
/// the only mutable field.
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

private struct UploadOutput: Encodable {
    let filePath: String
    let recordingId: String
    let jobId: String?
    let transcriptId: String?
    let status: String

    init(_ result: RecappiCloudUploadResult) {
        filePath = result.filePath
        recordingId = result.recordingId
        jobId = result.jobId
        transcriptId = result.transcriptId
        status = result.status
    }
}

private struct JobOutput: Encodable {
    let jobId: String
    let status: String
    let transcriptId: String?

    init(_ job: RecappiCloudJob) {
        jobId = job.id
        status = job.status.rawValue
        transcriptId = job.transcriptId
    }
}
