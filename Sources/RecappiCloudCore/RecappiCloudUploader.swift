import AVFoundation
import Foundation

public struct RecappiCloudAudioFile: Equatable, Sendable {
    public let url: URL
    public let contentType: String
    public let durationMs: Int?

    public init(url: URL, contentType: String, durationMs: Int?) {
        self.url = url
        self.contentType = contentType
        self.durationMs = durationMs
    }
}

public struct RecappiCloudAudioInspector: Sendable {
    public init() {}

    public func inspect(fileURL: URL) async throws -> RecappiCloudAudioFile {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw RecappiCloudError.fileMissing(fileURL.path)
        }

        guard let contentType = Self.cloudUploadContentType(for: fileURL) else {
            throw RecappiCloudError.unsupportedFileType(fileURL.path)
        }

        let durationMs = await Self.durationMs(for: fileURL)
        if !Self.isWavContentType(contentType), durationMs == nil {
            throw RecappiCloudError.durationUnavailable(fileURL.path)
        }

        return RecappiCloudAudioFile(url: fileURL, contentType: contentType, durationMs: durationMs)
    }

    public func audioFiles(in url: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw RecappiCloudError.fileMissing(url.path)
        }

        if !isDirectory.boolValue {
            guard Self.cloudUploadContentType(for: url) != nil else {
                throw RecappiCloudError.unsupportedFileType(url.path)
            }
            return [url]
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw RecappiCloudError.directoryHasNoSupportedFiles(url.path)
        }

        let files = enumerator.compactMap { entry -> URL? in
            guard let fileURL = entry as? URL,
                  (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  Self.cloudUploadContentType(for: fileURL) != nil else {
                return nil
            }
            return fileURL
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        if files.isEmpty {
            throw RecappiCloudError.directoryHasNoSupportedFiles(url.path)
        }
        return files
    }

    public static func cloudUploadContentType(for fileURL: URL) -> String? {
        switch fileURL.pathExtension.lowercased() {
        case "wav":
            return "audio/wav"
        case "mp3":
            return "audio/mp3"
        case "aif", "aiff":
            return "audio/aiff"
        case "aac":
            return "audio/aac"
        case "m4a":
            return "audio/aac"
        case "ogg":
            return "audio/ogg"
        case "flac":
            return "audio/flac"
        default:
            return nil
        }
    }

    public static func isWavContentType(_ contentType: String) -> Bool {
        contentType.lowercased() == "audio/wav" || contentType.lowercased() == "audio/x-wav"
    }

    private static func durationMs(for fileURL: URL) async -> Int? {
        let asset = AVURLAsset(url: fileURL)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return max(1, Int((seconds * 1000).rounded()))
    }
}

public struct RecappiCloudJobPoller: Sendable {
    private let client: RecappiCloudAPIClient
    private let sleep: @Sendable (Duration) async throws -> Void

    public init(
        client: RecappiCloudAPIClient,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in try await Task.sleep(for: duration) }
    ) {
        self.client = client
        self.sleep = sleep
    }

    public func waitForCompletion(
        jobId: String,
        timeout: Duration = .seconds(60 * 60 * 6),
        onProgress: @escaping @Sendable (RecappiCloudJob) async -> Void = { _ in }
    ) async throws -> RecappiCloudJob {
        let startedAt = ContinuousClock.now
        while true {
            let job = try await client.getJob(jobId: jobId)
            await onProgress(job)

            switch job.status {
            case .queued, .running:
                if startedAt.duration(to: .now) >= timeout {
                    throw RecappiCloudError.jobTimedOut(jobId)
                }
                try await sleep(.seconds(2))
            case .succeeded:
                return job
            case .failed:
                throw RecappiCloudError.jobFailed(job.error ?? "Transcription failed.")
            }
        }
    }
}

public struct RecappiCloudUploader: Sendable {
    private let client: RecappiCloudAPIClient
    private let inspector: RecappiCloudAudioInspector
    private let poller: RecappiCloudJobPoller

    public init(
        client: RecappiCloudAPIClient,
        inspector: RecappiCloudAudioInspector = RecappiCloudAudioInspector(),
        poller: RecappiCloudJobPoller? = nil
    ) {
        self.client = client
        self.inspector = inspector
        self.poller = poller ?? RecappiCloudJobPoller(client: client)
    }

    public func uploadPath(
        _ pathURL: URL,
        options: RecappiCloudUploadOptions,
        onEvent: @escaping @Sendable (RecappiCloudUploadEvent) async -> Void = { _ in }
    ) async throws -> [RecappiCloudUploadResult] {
        let fileURLs = try inspector.audioFiles(in: pathURL)
        var results: [RecappiCloudUploadResult] = []
        for fileURL in fileURLs {
            let result = try await uploadFile(fileURL, options: options, onEvent: onEvent)
            results.append(result)
        }
        return results
    }

    public func uploadFile(
        _ fileURL: URL,
        options: RecappiCloudUploadOptions,
        onEvent: @escaping @Sendable (RecappiCloudUploadEvent) async -> Void = { _ in }
    ) async throws -> RecappiCloudUploadResult {
        let audio = try await inspector.inspect(fileURL: fileURL)
        let title = options.title ?? fileURL.deletingPathExtension().lastPathComponent
        await onEvent(.creatingRecording(filePath: fileURL.path))
        let created = try await client.createRecording(
            title: title,
            contentType: audio.contentType,
            durationMs: audio.durationMs
        )

        var uploadCompleted = false
        do {
            let parts = try await client.uploadRecording(
                recordingId: created.id,
                fileURL: audio.url,
                partSize: created.partSize
            ) { progress in
                await onEvent(.uploading(filePath: fileURL.path, progress: progress))
            }

            await onEvent(.completingUpload(filePath: fileURL.path))
            let completed = try await client.completeRecording(recordingId: created.id, parts: parts)
            uploadCompleted = true

            guard options.transcribe || options.waitForTranscription else {
                let result = RecappiCloudUploadResult(
                    filePath: fileURL.path,
                    recordingId: created.id,
                    jobId: nil,
                    transcriptId: nil,
                    status: completed.status
                )
                await onEvent(.finished(result))
                return result
            }

            guard completed.status == "ready" else {
                throw RecappiCloudError.recordingNotReady(created.id)
            }

            await onEvent(.startingTranscription(recordingId: created.id))
            let start = try await client.startTranscription(
                recordingId: created.id,
                language: options.language,
                force: options.force,
                provider: options.provider,
                prompt: options.prompt
            )

            var transcriptId = start.transcriptId
            var finalStatus = start.status
            if options.waitForTranscription {
                let job = try await poller.waitForCompletion(jobId: start.jobId) { job in
                    await onEvent(.transcriptionProgress(
                        jobId: job.id,
                        status: job.status,
                        percent: job.chunkProgress?.percent
                    ))
                }
                transcriptId = job.transcriptId
                finalStatus = job.status
            }

            let result = RecappiCloudUploadResult(
                filePath: fileURL.path,
                recordingId: created.id,
                jobId: start.jobId,
                transcriptId: transcriptId,
                status: finalStatus.rawValue
            )
            await onEvent(.finished(result))
            return result
        } catch {
            if !uploadCompleted {
                await client.abortRecordingIfNeeded(recordingId: created.id)
            }
            throw error
        }
    }
}
