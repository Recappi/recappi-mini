import AppKit
import Foundation

@MainActor
extension CloudLibraryStore {
    func copySelectedTranscript() {
        guard let text = selectedTranscript?.text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func downloadSelectedAudio() async {
        guard let recording = selectedRecording else { return }
        isDownloading = true

        do {
            let destination = try downloadDestination(for: recording)
            lastDownloadedAudioURL = try await runAuthorized { client in
                try await client.downloadRecordingAudio(id: recording.id, destination: destination)
            }
            playbackAudioURLsByRecordingID[recording.id] = lastDownloadedAudioURL
        } catch {
            apply(error: error)
        }

        isDownloading = false
    }

    func preparePlaybackAudioForSelection() async {
        guard let recording = selectedRecording else { return }
        guard selectedPlaybackAudioURL == nil else { return }
        isPreparingPlaybackAudio = true
        playbackErrorMessage = nil

        do {
            let destination = try playbackCacheDestination(for: recording)
            if FileManager.default.fileExists(atPath: destination.path) {
                playbackAudioURLsByRecordingID[recording.id] = destination
            } else {
                playbackAudioURLsByRecordingID[recording.id] = try await runAuthorized { client in
                    try await client.downloadRecordingAudio(id: recording.id, destination: destination)
                }
            }
        } catch let error as RecappiAPIError where error == .unauthorized {
            apply(error: error)
        } catch {
            playbackErrorMessage = NetworkErrorPresenter.userFacingMessage(for: error)
        }

        isPreparingPlaybackAudio = false
    }

    func syncSelectedRecordingToLocal() async {
        guard let recording = selectedRecording else { return }
        if localSessionURLsByRecordingID[recording.id] != nil { return }

        isSyncingToLocal = true
        transcriptErrorMessage = nil
        playbackErrorMessage = nil

        do {
            let transcript = try await transcriptForSyncIfAvailable(recording)
            let sessionDir = try createSyncedSessionDirectory(for: recording)
            let audioURL = RecordingStore.audioFileURL(in: sessionDir)
                .deletingPathExtension()
                .appendingPathExtension(audioFileExtension(for: recording))

            _ = try await runAuthorized { client in
                try await client.downloadRecordingAudio(id: recording.id, destination: audioURL)
            }

            if let transcript {
                try RecordingStore.saveTranscriptArtifacts(transcript, in: sessionDir)
            }
            RecordingStore.saveSessionMetadata(metadata(for: recording), in: sessionDir)
            _ = RecordingStore.saveRemoteManifest(remoteManifest(for: recording, transcript: transcript), in: sessionDir)

            localSessionURLsByRecordingID[recording.id] = sessionDir
            playbackAudioURLsByRecordingID[recording.id] = audioURL
            lastDownloadedAudioURL = audioURL
        } catch let error as RecappiAPIError where error == .unauthorized {
            apply(error: error)
        } catch {
            playbackErrorMessage = NetworkErrorPresenter.userFacingMessage(for: error)
        }

        isSyncingToLocal = false
    }

    func revealLastDownloadedAudio() {
        guard let lastDownloadedAudioURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastDownloadedAudioURL])
    }

    func revealSelectedLocalSession() {
        guard let selectedLocalSessionURL else { return }
        try? RecordingStore.removeLegacyTranscriptionAlias(in: selectedLocalSessionURL)
        syncSelectedTranscriptArtifactsIfPossible()
        NSWorkspace.shared.open(selectedLocalSessionURL)
    }


    func downloadDestination(for recording: CloudRecording) throws -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let directory = downloads.appendingPathComponent("Recappi Mini", isDirectory: true)
        let basename = sanitizedFilename(recording.title ?? "recording-\(recording.id)")
        let ext = audioFileExtension(for: recording)
        return directory.appendingPathComponent("\(basename).\(ext)", isDirectory: false)
    }

    func playbackCacheDestination(for recording: CloudRecording) throws -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = caches
            .appendingPathComponent("Recappi Mini", isDirectory: true)
            .appendingPathComponent("Cloud Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(recording.id).\(audioFileExtension(for: recording))")
    }

    func audioFileExtension(for recording: CloudRecording) -> String {
        switch recording.contentType?.lowercased() {
        case "audio/aac", "audio/aacp":
            return "m4a"
        case "audio/wav", "audio/x-wav":
            return "wav"
        case "audio/mpeg", "audio/mp3":
            return "mp3"
        case "audio/mp4", "audio/m4a", "audio/x-m4a", "video/mp4":
            return "m4a"
        default:
            return "audio"
        }
    }


    func sanitizedFilename(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
            .union(.newlines)
            .union(.controlCharacters)
        let cleaned = raw
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "recording" : String(cleaned.prefix(96))
    }
}
