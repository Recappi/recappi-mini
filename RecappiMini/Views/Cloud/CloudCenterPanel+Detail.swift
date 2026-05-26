import AppKit
import SwiftUI

extension CloudCenterPanel {
    // MARK: - Detail content

    @ViewBuilder
    var detailContent: some View {
        switch store.state {
        case .idle, .loading:
            if isCurrentMeetingActive {
                detailPane
            } else {
                loadingView
            }
        case .signedOut:
            if isCurrentMeetingActive {
                detailPane
            } else {
                authRequiredView(
                    title: "Sign in to browse your cloud recordings",
                    detail: "Recappi Cloud keeps processed recordings, transcripts, and downloadable audio in one place."
                )
            }
        case .expired:
            if isCurrentMeetingActive {
                detailPane
            } else {
                authRequiredView(
                    title: "Reconnect Recappi Cloud",
                    detail: "Your session expired. Reconnect once and the library will refresh automatically."
                )
            }
        case .failed(let message):
            if isCurrentMeetingActive {
                detailPane
            } else {
                errorView(message)
            }
        case .empty:
            if isCurrentMeetingActive {
                detailPane
            } else {
                emptyView
            }
        case .loaded:
            detailPane
        }
    }

    var isCurrentMeetingActive: Bool {
        switch recorder.state {
        case .starting, .recording:
            true
        default:
            false
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    var detailPane: some View {
        if let recording = store.selectedRecording {
            CloudRecordingDetail(
                recording: recording,
                recordingWebURL: cloudRecordingWebURL(
                    recordingID: recording.id,
                    backendBaseURL: AppConfig.shared.effectiveBackendBaseURL
                ),
                latestJob: store.selectedLatestTranscriptionJob,
                transcriptionJobs: store.selectedTranscriptionJobs,
                transcript: store.selectedTranscript,
                transcriptErrorMessage: store.transcriptErrorMessage,
                retranscriptionLimitMessage: store.retranscriptionLimitMessage,
                localSessionURL: store.selectedLocalSessionURL,
                playbackAudioURL: store.selectedPlaybackAudioURL,
                playbackSourceDescription: store.selectedPlaybackSourceDescription,
                playbackErrorMessage: store.playbackErrorMessage,
                cloudSearchQuery: $cloudSearchQuery,
                selectedSearchSpeakerRawName: $selectedCloudSearchSpeakerRawName,
                speakerOverrides: Binding(
                    get: { store.speakerOverridesByRecordingID[recording.id] ?? [:] },
                    set: { store.updateSpeakerOverrides($0, for: recording.id) }
                ),
                indexedSearchResults: cloudIndexedSearchResults,
                isCloudSearchLoading: isCloudSearchLoading,
                audioPlayer: cloudAudioPlayer,
                isTranscriptLoading: store.isSelectedTranscriptLoading,
                isJobHistoryLoading: store.isSelectedJobHistoryLoading,
                isPreparingPlaybackAudio: store.isPreparingPlaybackAudio,
                isDownloading: store.isDownloading,
                isDeleting: store.isDeleting,
                isSyncingToLocal: store.isSyncingToLocal,
                processingAction: store.activeRecordingProcessingAction,
                processingPhase: store.selectedProcessingPhase,
                hasDownloadedAudio: store.lastDownloadedAudioURL != nil,
                hasNewerVersion: store.hasNewerVersionForSelection,
                onLoadTranscript: { Task { await store.loadTranscriptForSelection() } },
                onCopyTranscript: store.copySelectedTranscript,
                onProcessRecording: { action in
                    if recording.activeTranscriptId == nil {
                        Task { await store.processSelectedRecording(action) }
                    } else {
                        pendingProcessingAction = action
                        pendingProcessingHasExistingTranscript = true
                    }
                },
                onPreparePlaybackAudio: { Task { await store.preparePlaybackAudioForSelection() } },
                onRevealLocalSession: store.revealSelectedLocalSession,
                onSyncToLocal: { Task { await store.syncSelectedRecordingToLocal() } },
                onDownloadAudio: { Task { await store.downloadSelectedAudio() } },
                onRevealAudio: store.revealLastDownloadedAudio,
                onDelete: { showingDeleteConfirmation = true },
                onAcknowledgeNewerVersion: { Task { await store.acknowledgeNewerVersion() } },
                onLoadTranscriptVersion: { jobID in
                    try await store.loadTranscriptVersion(recordingID: recording.id, jobID: jobID)
                }
            )
            .task(id: recording.id) {
                await store.loadTranscriptForSelection()
                await store.loadJobHistoryForSelection()
            }
            .task(id: store.selectedActiveJobPollingKey) {
                await store.pollSelectedActiveJobsUntilTerminal()
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.stack.badge.person.crop")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.dtLabelTertiary)
                Text("Select a recording")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.dtLabel)
                Text("Choose a cloud recording to inspect metadata, preview transcript, or download audio.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.dtLabelSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Row context menu

    @ViewBuilder
    func rowContextMenu(for recording: CloudRecording) -> some View {
        Button("Rename…", systemImage: "pencil") {
            renameDraft = recording.presentationTitle
            pendingRenameRecording = recording
        }

        Divider()

        Button("Open in browser", systemImage: "arrow.up.right.square") {
            if let url = cloudRecordingWebURL(
                recordingID: recording.id,
                backendBaseURL: config.effectiveBackendBaseURL
            ) {
                NSWorkspace.shared.open(url)
            }
        }

        if store.localSessionURLsByRecordingID[recording.id] == nil {
            Button("Sync to Mac", systemImage: "arrow.down.doc") {
                store.select(recording)
                Task { await store.syncSelectedRecordingToLocal() }
            }
        } else {
            Button("Reveal local copy", systemImage: "folder") {
                store.select(recording)
                store.revealSelectedLocalSession()
            }
        }

        Divider()

        Button("Delete recording", systemImage: "trash", role: .destructive) {
            store.select(recording)
            showingDeleteConfirmation = true
        }
    }
}
