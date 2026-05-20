import AppKit
import SwiftUI

/// Two-pane cloud library window. The big surface area is split across
/// extension files in `Views/Cloud/`:
///   - `+Sidebar`        — recordings list, bottom bar, date grouping
///   - `+AccountHeader`  — top-of-sidebar account row and NSMenu popup
///   - `+Detail`         — detail pane router, detail pane content, row context menu
///   - `+States`         — loading / empty / error / auth-required surfaces + subtitle text
///   - `+Models`         — Model extensions (BillingStatus / TranscriptionJob /
///                         CloudRecordingProcessingAction) + cloudRecordingWebURL helper
struct CloudCenterPanel: View {
    @StateObject var store: CloudLibraryStore
    @StateObject var cloudAudioPlayer = CloudMeetingAudioPlayer()
    @ObservedObject var recorder: AudioRecorder
    @EnvironmentObject var sessionStore: AuthSessionStore
    @EnvironmentObject var appDelegate: AppDelegate
    @EnvironmentObject var config: AppConfig
    @State var showingDeleteConfirmation = false
    @State var pendingListScrollTargetID: String?
    @State var pendingProcessingAction: CloudRecordingProcessingAction?
    @State var pendingProcessingHasExistingTranscript = false
    @State var contextMenuTargetRecording: CloudRecording?
    @State var pendingRenameRecording: CloudRecording?
    @State var renameDraft: String = ""
    @State var cloudSearchQuery: String = ""
    @State var selectedCloudSearchSpeakerRawName: String?
    @State var cloudIndexedSearchResults: [CloudIndexedSearchResult] = []
    @State var isCloudSearchLoading = false

    init(store: CloudLibraryStore = CloudLibraryStore(), recorder: AudioRecorder) {
        _store = StateObject(wrappedValue: store)
        _recorder = ObservedObject(wrappedValue: recorder)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle("Cloud")
        .navigationSubtitle(headerSubtitle)
        .toolbar { toolbarContent }
        .containerBackground(.regularMaterial, for: .window)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.window)
        .onDisappear {
            cloudAudioPlayer.close()
        }
        .task {
            if !UITestModeConfiguration.shared.stateBoardVisualFixtureEnabled {
                await store.loadInitialIfNeeded()
            }
        }
        .task(id: cloudSearchTaskKey) {
            await refreshCloudSearchResults()
        }
        .confirmationDialog(
            "Delete this cloud recording?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Recording", role: .destructive) {
                Task { await store.deleteSelectedRecording() }
            }
            .accessibilityIdentifier(AccessibilityIDs.Cloud.confirmDeleteButton)

            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the remote recording and cannot be undone.")
        }
        .confirmationDialog(
            pendingProcessingAction?.confirmationTitle(hasExistingTranscript: pendingProcessingHasExistingTranscript)
                ?? "Process this recording?",
            isPresented: processingConfirmationBinding,
            titleVisibility: .visible
        ) {
            if let action = pendingProcessingAction {
                Button(action.confirmationButtonTitle) {
                    pendingProcessingAction = nil
                    pendingProcessingHasExistingTranscript = false
                    Task { await store.processSelectedRecording(action) }
                }
                .accessibilityIdentifier(action.confirmAccessibilityIdentifier)
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingProcessingAction?.confirmationMessage(hasExistingTranscript: pendingProcessingHasExistingTranscript) ?? "")
        }
        .alert(
            "Rename recording",
            isPresented: renameAlertBinding,
            presenting: pendingRenameRecording
        ) { recording in
            TextField("Title", text: $renameDraft)
            Button("Save") {
                // TODO: wire to backend rename endpoint once it lands.
                // The right-click → Rename UI is in place (this alert + the
                // sidebar menu item), but `RecappiAPIClient` has no PATCH
                // /api/recordings/{id} yet. When the endpoint exists, send
                // `renameDraft` (after trimming) for `recording.id`, then
                // refresh the row optimistically through `store`.
                _ = recording
                _ = renameDraft
                pendingRenameRecording = nil
            }
            Button("Cancel", role: .cancel) {
                pendingRenameRecording = nil
            }
        } message: { _ in
            Text("Choose a new title for this recording.")
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            CloudToolbarSearchInput(text: $cloudSearchQuery)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if isCurrentMeetingActive {
                Button {
                    appDelegate.setLiveCaptionPanelPresented(!appDelegate.isLiveCaptionPanelPresented)
                } label: {
                    Label(
                        appDelegate.isLiveCaptionPanelPresented ? "Hide Captions" : "Show Captions",
                        systemImage: appDelegate.isLiveCaptionPanelPresented ? "captions.bubble.fill" : "captions.bubble"
                    )
                }
                .help(appDelegate.isLiveCaptionPanelPresented ? "Hide live captions" : "Show live captions")
                .accessibilityIdentifier(AccessibilityIDs.Cloud.currentMeetingCaptionToggleButton)
            }

            Button {
                Task { await store.refresh() }
            } label: {
                if store.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(store.isRefreshing || sessionStore.isAuthBusy)
            .help("Refresh cloud recordings")
            .accessibilityIdentifier(AccessibilityIDs.Cloud.refreshButton)
        }
    }

    var isCloudSearchActive: Bool {
        !cloudSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || selectedCloudSearchSpeakerRawName != nil
    }

    var cloudSearchTaskKey: String {
        [
            cloudSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
            selectedCloudSearchSpeakerRawName ?? "",
            "\(store.recordings.count)",
            "\(store.transcriptCache.count)",
        ].joined(separator: "\u{1f}")
    }

    @MainActor
    func refreshCloudSearchResults() async {
        let query = cloudSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let speaker = selectedCloudSearchSpeakerRawName
        guard !query.isEmpty || speaker != nil else {
            cloudIndexedSearchResults = []
            isCloudSearchLoading = false
            return
        }
        isCloudSearchLoading = true
        let results = await store.searchCachedRecordings(
            query: query,
            speakerRawName: speaker,
            limit: 80
        )
        guard query == cloudSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines),
              speaker == selectedCloudSearchSpeakerRawName else { return }
        cloudIndexedSearchResults = results
        isCloudSearchLoading = false
    }

    // MARK: - Bindings

    var renameAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingRenameRecording != nil },
            set: { isPresented in
                if !isPresented {
                    pendingRenameRecording = nil
                }
            }
        )
    }

    var processingConfirmationBinding: Binding<Bool> {
        Binding(
            get: { pendingProcessingAction != nil },
            set: { isPresented in
                if !isPresented {
                    pendingProcessingAction = nil
                    pendingProcessingHasExistingTranscript = false
                }
            }
        )
    }

    var selectionBinding: Binding<String?> {
        Binding(
            get: { store.selectedRecordingID },
            set: { newID in
                guard let id = newID,
                      let rec = store.recordings.first(where: { $0.id == id }) else { return }
                store.select(rec)
            }
        )
    }
}

private struct CloudToolbarSearchInput: View {
    @Binding var text: String

    var body: some View {
        NativeToolbarSearchField(text: $text)
            .frame(width: 260, height: 28)
    }
}

private struct NativeToolbarSearchField: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search all recordings"
        field.controlSize = .regular
        field.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchFieldAction(_:))
        field.setAccessibilityIdentifier(AccessibilityIDs.Cloud.searchField)
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            text.wrappedValue = field.stringValue
        }

        @MainActor @objc func searchFieldAction(_ sender: NSSearchField) {
            text.wrappedValue = sender.stringValue
        }
    }
}

#if DEBUG
#Preview("Cloud Center Panel") {
    let store = CloudLibraryStore.previewLoaded(recordings: [
        .previewSample(id: "p-1", title: "Weekly engineering sync"),
        .previewSample(
            id: "p-2",
            title: "Design review with platform team",
            createdAt: Date().addingTimeInterval(-86_400)
        ),
        .previewSample(
            id: "p-3",
            title: "Quarterly planning roadmap",
            createdAt: Date().addingTimeInterval(-86_400 * 3)
        ),
    ])

    return CloudCenterPanel(store: store, recorder: AudioRecorder())
        .environmentObject(AuthSessionStore.shared)
        .environmentObject(AppConfig.shared)
        .environmentObject(AppDelegate.shared)
        .frame(width: 960, height: 640)
}
#endif
