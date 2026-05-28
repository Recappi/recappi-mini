import AppKit
import SwiftUI

extension CloudCenterPanel {
    // MARK: - Sidebar

    var sidebar: some View {
        VStack(spacing: 0) {
            accountHeaderMenu
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)

            ScrollViewReader { proxy in
                List(selection: selectionBinding) {
                    ForEach(recordingDateSections) { section in
                        Section(section.title) {
                            ForEach(section.recordings) { recording in
                                CloudRecordingRow(
                                    recording: recording,
                                    isSelected: store.selectedRecordingID == recording.id,
                                    hasNewerVersion: store.recordingIDsWithNewerVersions.contains(recording.id)
                                )
                                .tag(recording.id)
                                .id(recording.id)
                                .contextMenu {
                                    rowContextMenu(for: recording)
                                }
                            }
                        }
                    }

                    if store.hasMorePages {
                        loadMoreSentinel
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.sidebar)
                .accessibilityIdentifier(AccessibilityIDs.Cloud.recordingsList)
                .onChange(of: pendingListScrollTargetID) { _, id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                    DispatchQueue.main.async {
                        pendingListScrollTargetID = nil
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    sidebarBottomBar
                }
            }
        }
        // `navigationSplitViewColumnWidth` is the right knob for the
        // production NSWindow flow, but it is only a *hint* that
        // NavigationSplitView reconciles with the host. The Xcode
        // Preview shell hosts at a fixed frame and ignores it, so
        // pair it with a hard `frame(minWidth:)` below to keep the
        // sidebar from collapsing in Canvas.
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 400)
        .frame(minWidth: 230)
    }

    @ViewBuilder
    var sidebarBottomBar: some View {
        VStack(spacing: 8) {
            if let current = nowPlayingRecording,
               cloudAudioPlayer.currentRecordingID != store.selectedRecordingID {
                CloudNowPlayingMiniPane(
                    recording: current,
                    isPlaying: cloudAudioPlayer.isPlaying,
                    currentTime: cloudAudioPlayer.currentTime,
                    duration: cloudAudioPlayer.duration,
                    playbackRate: cloudAudioPlayer.playbackRate,
                    onPlayPause: cloudAudioPlayer.togglePlayback,
                    onSelectRate: cloudAudioPlayer.setPlaybackRate(_:),
                    onSelectRecording: { selectNowPlayingRecording(current) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityIdentifier(AccessibilityIDs.Cloud.nowPlayingDock)
            }

            openRecappiCloudButton
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    var openRecappiCloudButton: some View {
        Button {
            if let url = URL(string: config.effectiveBackendBaseURL) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 6) {
                Text("Open Recappi Cloud")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.labelPrimary)
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.labelSecondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .glassEffect(in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .recappiTooltip("Open Recappi Cloud in your browser")
        .accessibilityIdentifier(AccessibilityIDs.Cloud.openWebDashboardButton)
    }

    // MARK: - Now Playing helpers

    var nowPlayingRecording: CloudRecording? {
        guard let id = cloudAudioPlayer.currentRecordingID else { return nil }
        return store.recordings.first(where: { $0.id == id })
    }

    func selectNowPlayingRecording(_ recording: CloudRecording) {
        store.select(recording)
        pendingListScrollTargetID = recording.id
    }

    // MARK: - Section grouping

    var recordingDateSections: [CloudRecordingDateSection] {
        var sections: [CloudRecordingDateSection] = []
        for recording in store.recordings {
            let bucket = recordingDateBucket(for: recording.createdAt)
            if sections.last?.id == bucket.id {
                sections[sections.count - 1].recordings.append(recording)
            } else {
                sections.append(
                    CloudRecordingDateSection(
                        id: bucket.id,
                        title: bucket.title,
                        recordings: [recording]
                    )
                )
            }
        }
        return sections
    }

    private func recordingDateBucket(for date: Date?) -> (id: String, title: String) {
        guard let date else {
            return ("unknown", "Unknown date")
        }

        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: Date())

        if startOfDay == today {
            return ("today", "Today")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), startOfDay == yesterday {
            return ("yesterday", "Yesterday")
        }

        let idFormatter = DateFormatter()
        idFormatter.calendar = calendar
        idFormatter.locale = .current
        idFormatter.dateFormat = "yyyy-MM-dd"

        let titleFormatter = DateFormatter()
        titleFormatter.calendar = calendar
        titleFormatter.locale = .current
        titleFormatter.dateStyle = .medium
        titleFormatter.timeStyle = .none

        return (idFormatter.string(from: startOfDay), titleFormatter.string(from: startOfDay))
    }

    var loadMoreSentinel: some View {
        HStack {
            Spacer(minLength: 0)

            if store.isLoadingMore {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
                    .tint(DT.waveformLit)
            } else {
                Color.clear
                    .frame(width: 1, height: 1)
            }

            Spacer(minLength: 0)
        }
        .frame(height: store.isLoadingMore ? 24 : 8)
        .padding(.top, 4)
        .task {
            guard store.hasMorePages, !store.isLoadingMore else { return }
            await store.loadMore()
        }
        .accessibilityIdentifier(AccessibilityIDs.Cloud.loadMoreButton)
    }
}
