import Foundation
import RecappiCloudCore

@main
struct RecappiCLI {
    static func main() async {
        do {
            let exitCode = try await run(arguments: Array(CommandLine.arguments.dropFirst()))
            Foundation.exit(exitCode)
        } catch {
            FileHandle.standardError.write(Data("recappi: \(error.localizedDescription)\n".utf8))
            Foundation.exit(1)
        }
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

        let context = try RecappiCloudAuth().context(explicitOrigin: origin)
        let session = try await RecappiCloudAPIClient(context: context).getSession()
        guard let session else {
            throw RecappiCloudError.unauthorized
        }

        if json {
            try printJSON(AuthStatusOutput(origin: context.origin, email: session.email, userId: session.userId))
        } else {
            print("Signed in to \(context.origin)")
            print("\(session.email) (\(session.userId))")
        }
        return 0
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

        let results = try await uploader.uploadPath(URL(fileURLWithPath: path), options: options) { event in
            guard !json else { return }
            printHumanEvent(event)
        }

        if json {
            try printJSON(results.map(UploadOutput.init))
        } else {
            for result in results {
                print("Ready: recording \(result.recordingId)")
                if let jobId = result.jobId {
                    print("Job: \(jobId) (\(result.status))")
                }
                if let transcriptId = result.transcriptId {
                    print("Transcript: \(transcriptId)")
                }
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
        let job = try await poller.waitForCompletion(jobId: jobId) { job in
            guard !json else { return }
            printJobProgress(job)
        }

        if json {
            try printJSON(JobOutput(job))
        } else {
            print("Transcription complete")
            if let transcriptId = job.transcriptId {
                print("Transcript: \(transcriptId)")
            }
        }
        return 0
    }

    private static func printHumanEvent(_ event: RecappiCloudUploadEvent) {
        switch event {
        case .creatingRecording(let filePath):
            print("Creating recording: \(URL(fileURLWithPath: filePath).lastPathComponent)")
        case .uploading(_, let progress):
            print("Uploading \(percentText(progress * 100))")
        case .completingUpload:
            print("Completing upload")
        case .startingTranscription:
            print("Starting transcription")
        case .transcriptionProgress(_, let status, let percent):
            if let percent {
                print("Transcribing... \(percentText(percent))")
            } else {
                print("Transcribing... \(status.rawValue)")
            }
        case .finished:
            break
        }
    }

    private static func printJobProgress(_ job: RecappiCloudJob) {
        if let percent = job.chunkProgress?.percent {
            print("Transcribing... \(percentText(percent))")
        } else {
            print("Transcribing... \(job.status.rawValue)")
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
        recappi

        Commands:
          recappi auth status [--origin <url>] [--json]
          recappi upload <file-or-dir> [--title <title>] [--transcribe] [--wait] [--language <lang>] [--provider <provider>] [--prompt <text>] [--origin <url>] [--json]
          recappi jobs wait <jobId> [--origin <url>] [--json]
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
    let origin: String
    let email: String
    let userId: String
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
