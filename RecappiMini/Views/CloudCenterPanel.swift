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
    @State var contextMenuTargetRecording: CloudRecording?
    @State var pendingRenameRecording: CloudRecording?
    @State var renameDraft: String = ""

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
        .navigationTitle("Recappi Cloud")
        .navigationSubtitle(headerSubtitle)
        .toolbar { toolbarContent }
        .containerBackground(Palette.surfaceWindow, for: .window)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityIDs.Cloud.window)
        .onDisappear {
            cloudAudioPlayer.close()
        }
        .task {
            await store.loadInitialIfNeeded()
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
            pendingProcessingAction?.confirmationTitle ?? "Process this recording?",
            isPresented: processingConfirmationBinding,
            titleVisibility: .visible
        ) {
            if let action = pendingProcessingAction {
                Button(action.confirmationButtonTitle) {
                    pendingProcessingAction = nil
                    Task { await store.processSelectedRecording(action) }
                }
                .accessibilityIdentifier(action.confirmAccessibilityIdentifier)
            }

            Button("Cancel", role: .cancel) {}
        } message: {
            Text(pendingProcessingAction?.confirmationMessage ?? "")
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
        ToolbarItem(placement: .automatic) {
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
        }
        ToolbarItem(placement: .primaryAction) {
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
