import AVFoundation
import AppKit
import CoreAudio
@preconcurrency import ScreenCaptureKit
import Speech

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var state: RecorderState = .idle
    @Published var elapsedSeconds: Int = 0
    @Published var runningApps: [AudioApp] = []
    @Published var selectedApp: AudioApp?
    @Published var recordingSuggestion: RecordingSuggestion?
    @Published var meetingPrompt: MeetingPrompt?
    @Published var recordingAppName: String?
    @Published private(set) var detectedMeetingRecordingContext: DetectedMeetingRecordingContext?
    @Published private(set) var autoStopRequest: AutoStopRecordingRequest?
    @Published var audioLevel: Float = 0
    @Published var audioSpectrumLevels: [Float] = Array(repeating: 0, count: AudioRecorder.spectrumBucketCount)
    @Published var audioLevelHistory: [Float] = Array(repeating: 0, count: AudioRecorder.spectrumBucketCount)
    /// Ordered live-caption segments produced by the active transcriber.
    /// Empty when no caption history has been accumulated yet (or after
    /// an explicit reset). UI consumers branch on `isEmpty` for the
    /// placeholder state and read segment-level metadata for natural
    /// paragraph breaks + future bilingual rendering.
    @Published private(set) var liveCaptionSegments: [LiveCaptionSegment] = []
    @Published private(set) var liveCaptionMessage: String?
    /// True when every segment in `liveCaptionSegments` is `isFinal`. UI
    /// can use this to gate animations or styling for "stable" captions.
    @Published private(set) var liveCaptionIsFinal: Bool = false
    @Published private(set) var activeRecordingID: UUID?
    /// Session directory of the most-recent (or in-progress) recording.
    /// Populated on stop and kept through processing + error states so the
    /// UI can offer Retry / Show without stashing state at the view layer.
    @Published var lastSessionDir: URL?

    // --- System audio (ScreenCaptureKit) pipeline ---
    /// Hot-audio signal surfaced to the picker. Owned here so the UI
    /// observes the same refresh clock as runningApps updates.
    let activityMonitor = AudioActivityMonitor()

    private var stream: SCStream?
    private var systemOutput: SystemAudioOutput?
    private var liveCaptionTranscriber: Any?
    private let systemCaptureQueue = DispatchQueue(label: "RecappiMini.SystemCapture")
    private var audioDeviceMonitor: DefaultAudioDeviceMonitor?
    private var currentOutputAudioDeviceID: AudioDeviceID?

    // --- Microphone (AVCaptureSession) pipeline ---
    private var micSession: AVCaptureSession?
    private var micOutput: MicAudioOutput?
    private let micCaptureQueue = DispatchQueue(label: "RecappiMini.MicCapture")

    private var sessionDir: URL?
    private var timer: Timer?
    /// Timestamp of the last `audioLevel` publish; capped at 30 Hz so
    /// SwiftUI doesn't burn a re-render per ScreenCaptureKit buffer.
    private var lastLevelPublish: CFTimeInterval = 0
    private var lastHistoryPublish: CFTimeInterval = 0
    private let uiTestMode = UITestModeConfiguration.shared
    private var uiTestInjectedAudioApps: [String: AudioApp] = [:]
    private var uiTestInjectedActiveBundleIDs: Set<String> = []
    private var refreshAppsRetryTask: Task<Void, Never>?
    private var pendingDetectedMeetingRecordingContext: DetectedMeetingRecordingContext?

    static let spectrumBucketCount = AudioSpectrumConfiguration.bucketCount
    private static let historySampleInterval: CFTimeInterval = 0.18

    var currentSessionDir: URL? { sessionDir }

    // MARK: - App discovery

    func refreshApps(seedFromWorkspace: Bool = true) async {
        if seedFromWorkspace {
            refreshAppsFromWorkspaceSnapshot()
        }
        let selfBundleID = Bundle.main.bundleIdentifier ?? "com.recappi.mini"
        let active = effectiveActiveBundleIDs(from: activityMonitor.activeBundleIDs)

        do {
            let content = try await SCShareableContent.current
            let apps = Self.shareableContentAudioApps(
                from: content.applications,
                selfBundleID: selfBundleID,
                active: active
            )

            if !apps.isEmpty {
                applyRunningApps(appsWithUITestInjections(apps, active: active))
                cancelRefreshAppsRetry()
                return
            }

            let fallbackApps = Self.workspaceAudioApps(
                selfBundleID: selfBundleID,
                active: active
            )
            if !fallbackApps.isEmpty {
                applyRunningApps(appsWithUITestInjections(fallbackApps, active: active))
            }
            scheduleRefreshAppsRetry()
        } catch {
            let fallbackApps = Self.workspaceAudioApps(
                selfBundleID: selfBundleID,
                active: active
            )
            if !fallbackApps.isEmpty {
                applyRunningApps(appsWithUITestInjections(fallbackApps, active: active))
            } else if runningApps.isEmpty {
                self.runningApps = appsWithUITestInjections([], active: active)
            }
            scheduleRefreshAppsRetry()
        }
    }

    /// `SCShareableContent.current` is occasionally empty during app launch
    /// and right after process churn. Seed the picker from NSWorkspace so the
    /// menu still shows a useful list while ScreenCaptureKit catches up.
    func refreshAppsFromWorkspaceSnapshot() {
        let selfBundleID = Bundle.main.bundleIdentifier ?? "com.recappi.mini"
        let active = effectiveActiveBundleIDs(from: activityMonitor.activeBundleIDs)
        let fallbackApps = Self.workspaceAudioApps(
            selfBundleID: selfBundleID,
            active: active
        )
        let apps = appsWithUITestInjections(fallbackApps, active: active)
        guard !apps.isEmpty else { return }
        applyRunningApps(apps)
    }

    /// Active apps float above inactive; within each active/inactive group
    /// sort by the static bucket (meeting → browser → other) then name.
    static func sortOrder(_ lhs: AudioApp, _ rhs: AudioApp) -> Bool {
        if lhs.isActive != rhs.isActive { return lhs.isActive && !rhs.isActive }
        if lhs.bucket != rhs.bucket { return lhs.bucket < rhs.bucket }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    static func autoPromptCandidate(from apps: [AudioApp], active: Set<String>) -> AudioApp? {
        apps
            .filter { active.contains($0.id) && shouldAutoPrompt(for: $0) }
            .sorted(by: sortOrder)
            .first
    }

    static func shouldAutoPrompt(for app: AudioApp) -> Bool {
        app.bucket == .meeting
    }

    func selectApp(_ app: AudioApp?, clearPrompts: Bool = true) {
        selectedApp = app
        if clearPrompts {
            recordingSuggestion = nil
            meetingPrompt = nil
            pendingDetectedMeetingRecordingContext = nil
        }
    }

    func suggestRecording(for app: AudioApp) {
        suggestRecording(for: app, promptTitle: app.name)
    }

    func suggestRecording(for app: AudioApp, promptTitle: String) {
        meetingPrompt = nil
        recordingSuggestion = RecordingSuggestion(
            appID: app.id,
            appName: app.name,
            promptTitle: promptTitle
        )
    }

    func clearRecordingSuggestion() {
        recordingSuggestion = nil
    }

    func showMeetingPrompt(for app: AudioApp, promptTitle: String) {
        recordingSuggestion = nil
        meetingPrompt = MeetingPrompt(
            appID: app.id,
            appName: app.name,
            promptTitle: promptTitle
        )
    }

    func clearMeetingPrompt() {
        meetingPrompt = nil
    }

    func injectUITestAudioApp(bundleID: String, name: String) {
        setUITestAudioApp(bundleID: bundleID, name: name, active: true)
    }

    func setUITestAudioApp(bundleID: String, name: String, active: Bool) {
        let app = AudioApp(
            id: bundleID,
            name: name,
            icon: nil,
            scApp: nil,
            bucket: AudioAppCategories.bucket(for: bundleID),
            isActive: active
        )
        uiTestInjectedAudioApps[bundleID] = app
        if active {
            uiTestInjectedActiveBundleIDs.insert(bundleID)
        } else {
            uiTestInjectedActiveBundleIDs.remove(bundleID)
        }
        applyRunningApps(appsWithUITestInjections(runningApps, active: effectiveActiveBundleIDs(from: activityMonitor.activeBundleIDs)))
    }

    @discardableResult
    func acceptRecordingSuggestion() -> Bool {
        guard let suggestion = recordingSuggestion else { return false }
        guard let app = runningApps.first(where: { $0.id == suggestion.appID }) else {
            recordingSuggestion = nil
            return false
        }

        selectedApp = app
        pendingDetectedMeetingRecordingContext = DetectedMeetingRecordingContext(
            appID: suggestion.appID,
            appName: suggestion.appName,
            promptTitle: suggestion.promptTitle
        )
        recordingSuggestion = nil
        meetingPrompt = nil
        return true
    }

    func updateRecordingSuggestion(promptTitle: String, forAppID appID: String) {
        guard var suggestion = recordingSuggestion, suggestion.appID == appID else { return }
        guard suggestion.promptTitle != promptTitle else { return }
        suggestion = RecordingSuggestion(
            appID: suggestion.appID,
            appName: suggestion.appName,
            promptTitle: promptTitle
        )
        recordingSuggestion = suggestion
    }

    /// Re-apply the latest activity snapshot without a full SCShareableContent
    /// round-trip. Called when AudioActivityMonitor publishes a change.
    func applyActivity(_ active: Set<String>) {
        let effectiveActive = effectiveActiveBundleIDs(from: active)

        if let suggestion = recordingSuggestion, !effectiveActive.contains(suggestion.appID) {
            recordingSuggestion = nil
        }
        if let prompt = meetingPrompt, !effectiveActive.contains(prompt.appID) {
            meetingPrompt = nil
        }

        var mutated = runningApps
        var anyChanged = false
        for i in mutated.indices {
            let shouldBeActive = effectiveActive.contains(mutated[i].id)
            if mutated[i].isActive != shouldBeActive {
                mutated[i].isActive = shouldBeActive
                anyChanged = true
            }
        }
        if anyChanged {
            runningApps = mutated.sorted(by: Self.sortOrder)
        }
    }

    /// Shared wrapper so other services (AudioActivityMonitor) can collapse
    /// helper bundle ids the same way.
    static func parentBundle(of bundleID: String) -> String {
        BundleCollapser.parent(of: bundleID)
    }

    /// Prefer the real display name from the application bundle so e.g.
    /// "Google Chrome Helper (Renderer)" collapses to "Google Chrome".
    private static func displayName(for bundleID: String, fallback: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
           let bundle = Bundle(url: url),
           let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
               ?? (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
               ?? (bundle.infoDictionary?["CFBundleName"] as? String) {
            return name
        }
        return BundleCollapser.browserDisplayName(for: bundleID, fallback: fallback)
    }

    private func applyRunningApps(_ apps: [AudioApp]) {
        runningApps = apps

        guard let selectedID = selectedApp?.id else { return }
        if let refreshedSelection = apps.first(where: { $0.id == selectedID }) {
            selectedApp = refreshedSelection
        }
    }

    private func effectiveActiveBundleIDs(from active: Set<String>) -> Set<String> {
        if uiTestMode.isEnabled, !uiTestInjectedAudioApps.isEmpty {
            return uiTestInjectedActiveBundleIDs
        }
        return active.union(uiTestInjectedActiveBundleIDs)
    }

    private func appsWithUITestInjections(_ apps: [AudioApp], active: Set<String>) -> [AudioApp] {
        guard !uiTestInjectedAudioApps.isEmpty else { return apps }

        var byID = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0) })
        for (bundleID, injected) in uiTestInjectedAudioApps {
            var app = byID[bundleID] ?? injected
            app.isActive = active.contains(bundleID)
            byID[bundleID] = app
        }
        return Array(byID.values).sorted(by: Self.sortOrder)
    }

    private func scheduleRefreshAppsRetry(after delay: Duration = .seconds(1)) {
        guard refreshAppsRetryTask == nil else { return }

        refreshAppsRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.refreshAppsRetryTask = nil
            await self?.refreshApps(seedFromWorkspace: false)
        }
    }

    private func cancelRefreshAppsRetry() {
        refreshAppsRetryTask?.cancel()
        refreshAppsRetryTask = nil
    }

    private static func shareableContentAudioApps(
        from applications: [SCRunningApplication],
        selfBundleID: String,
        active: Set<String>
    ) -> [AudioApp] {
        var byParent: [String: SCRunningApplication] = [:]
        for scApp in applications {
            let bid = scApp.bundleIdentifier
            guard !bid.isEmpty else { continue }
            let parent = parentBundle(of: bid)
            guard shouldIncludeRunningApp(bundleID: parent, selfBundleID: selfBundleID) else { continue }
            if byParent[parent] == nil || scApp.bundleIdentifier == parent {
                byParent[parent] = scApp
            }
        }

        return byParent.compactMap { parentBid, scApp in
            let fallbackName = scApp.applicationName
            return makeAudioApp(
                bundleID: parentBid,
                fallbackName: fallbackName,
                active: active,
                scApp: scApp
            )
        }
        .sorted(by: sortOrder)
    }

    private static func workspaceAudioApps(
        selfBundleID: String,
        active: Set<String>
    ) -> [AudioApp] {
        var byParent: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications {
            guard !app.isTerminated else { continue }
            guard let bid = app.bundleIdentifier, !bid.isEmpty else { continue }
            let parent = parentBundle(of: bid)
            guard shouldIncludeRunningApp(bundleID: parent, selfBundleID: selfBundleID) else { continue }

            let isRegular = app.activationPolicy == .regular
            let isDirectBundle = bid == parent
            let isAudioActive = active.contains(parent)
            guard isRegular || isDirectBundle || isAudioActive else { continue }

            if byParent[parent] == nil || bid == parent {
                byParent[parent] = app
            }
        }

        return byParent.compactMap { parentBid, app in
            makeAudioApp(
                bundleID: parentBid,
                fallbackName: app.localizedName ?? "",
                active: active,
                scApp: nil
            )
        }
        .sorted(by: sortOrder)
    }

    private static func makeAudioApp(
        bundleID: String,
        fallbackName: String,
        active: Set<String>,
        scApp: SCRunningApplication?
    ) -> AudioApp? {
        let name = displayName(for: bundleID, fallback: fallbackName)
        guard !name.isEmpty else { return nil }

        let rawIcon = NSWorkspace.shared.icon(forFile:
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.path ?? "")
        rawIcon.size = NSSize(width: 16, height: 16)

        return AudioApp(
            id: bundleID,
            name: name,
            icon: rawIcon,
            scApp: scApp,
            bucket: AudioAppCategories.bucket(for: bundleID),
            isActive: active.contains(bundleID)
        )
    }

    private static func shouldIncludeRunningApp(bundleID: String, selfBundleID: String) -> Bool {
        guard bundleID != selfBundleID else { return false }
        guard !bundleID.hasPrefix("com.apple.") || isNotableAppleApp(bundleID) else { return false }
        return true
    }

    private static func isNotableAppleApp(_ bid: String) -> Bool {
        let notable: Set<String> = [
            "com.apple.Safari",
            "com.apple.FaceTime",
            "com.apple.Music",
            "com.apple.QuickTimePlayerX",
            "com.apple.VoiceMemos",
        ]
        return notable.contains(bid)
    }

    // MARK: - Start / Stop

    func startRecording() async throws {
        guard state == .idle else { return }
        activeRecordingID = UUID()
        let metadata = recordingSessionMetadata()
        let autoStopContext = detectedMeetingContextForNextRecording()
        pendingDetectedMeetingRecordingContext = nil
        recordingSuggestion = nil
        meetingPrompt = nil
        state = .starting

        if uiTestMode.isEnabled {
            try startUITestRecording(metadata: metadata, autoStopContext: autoStopContext)
            return
        }

        do {
            try await requestMicrophoneAccessIfNeeded()
            guard CapturePermissionPrimer.shared.hasScreenCaptureAccess() else {
                throw RecorderError.screenCaptureDenied
            }

            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                throw RecorderError.noDisplay
            }

            let sessionDir = try RecordingStore.createSessionDirectory()
            RecordingStore.saveSessionMetadata(metadata, in: sessionDir)
            self.sessionDir = sessionDir

            // Intermediate files; merged into recording.m4a at stop.
            let systemURL = sessionDir.appendingPathComponent("system.m4a")
            let micURL = sessionDir.appendingPathComponent("mic.m4a")

            let outputAudioDeviceID = try OutputDeviceAudioFormat.currentDefaultOutputDeviceID()
            self.currentOutputAudioDeviceID = outputAudioDeviceID

            // --- System audio pipeline ---
            let sysWriter = SegmentedAudioWriter(finalURL: systemURL, processingQueue: systemCaptureQueue)
            let sysOut = SystemAudioOutput(writer: sysWriter)
            sysOut.onMeterFrame = { [weak self] frame in
                self?.ingestMeterFrame(frame)
            }
            await startLiveCaptions(for: sysOut)
            self.systemOutput = sysOut

            let filter: SCContentFilter
            if let app = selectedApp {
                let liveApps = content.applications.filter {
                    BundleCollapser.matches($0.bundleIdentifier, selected: app.id)
                }
                if !liveApps.isEmpty {
                    filter = SCContentFilter(display: display, including: liveApps, exceptingWindows: [])
                    recordingAppName = app.name
                } else {
                    filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                    recordingAppName = nil
                }
            } else {
                filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
                recordingAppName = nil
            }

            let config = makeSystemAudioConfiguration()

            let scStream = SCStream(filter: filter, configuration: config, delegate: nil)
            try scStream.addStreamOutput(sysOut, type: .audio, sampleHandlerQueue: systemCaptureQueue)
            self.stream = scStream

            // --- Microphone pipeline ---
            let captureSession = AVCaptureSession()
            guard let micDevice = AVCaptureDevice.default(for: .audio) else {
                throw RecorderError.noMicrophone
            }
            let deviceInput = try AVCaptureDeviceInput(device: micDevice)
            guard captureSession.canAddInput(deviceInput) else {
                throw RecorderError.micSetupFailed
            }
            captureSession.addInput(deviceInput)

            let mcWriter = SegmentedAudioWriter(finalURL: micURL, processingQueue: micCaptureQueue)
            let mcOut = MicAudioOutput(writer: mcWriter)
            mcOut.onMeterFrame = { [weak self] frame in
                self?.ingestMeterFrame(frame)
            }
            let captureOutput = AVCaptureAudioDataOutput()
            captureOutput.audioSettings = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
            ]
            captureOutput.setSampleBufferDelegate(mcOut, queue: micCaptureQueue)
            guard captureSession.canAddOutput(captureOutput) else {
                throw RecorderError.micSetupFailed
            }
            captureSession.addOutput(captureOutput)
            self.micSession = captureSession
            self.micOutput = mcOut

            // --- Start both pipelines ---
            try startMonitoringOutputDeviceChanges()
            try await scStream.startCapture()
            captureSession.startRunning()

            self.audioLevel = 0
            self.audioSpectrumLevels = Array(repeating: 0, count: Self.spectrumBucketCount)
            self.audioLevelHistory = Array(repeating: 0, count: Self.spectrumBucketCount)
            self.lastLevelPublish = 0
            self.lastHistoryPublish = 0
            self.detectedMeetingRecordingContext = autoStopContext
            self.state = .recording
            self.elapsedSeconds = 0
            self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.elapsedSeconds += 1
                }
            }
        } catch {
            activeRecordingID = nil
            detectedMeetingRecordingContext = nil
            stopMonitoringOutputDeviceChanges()
            self.micSession?.stopRunning()
            self.stream = nil
            self.systemOutput = nil
            self.micSession = nil
            self.micOutput = nil
            self.stopLiveCaptions(saveTo: nil)
            throw error
        }
    }

    func stopRecording() async throws -> URL {
        guard state == .recording else {
            throw RecorderError.notRecording
        }

        detectedMeetingRecordingContext = nil
        self.state = .processing(.savingAudio)
        self.timer?.invalidate()
        self.timer = nil
        stopMonitoringOutputDeviceChanges()

        if uiTestMode.isEnabled {
            return try stopUITestRecording()
        }

        // Take local ownership and clear the live capture properties first.
        // If any async stop/finalize step throws, the microphone should still
        // be released immediately instead of staying captured until app quit.
        let scStream = self.stream
        let systemOutput = self.systemOutput
        let micOutput = self.micOutput
        let micSession = self.micSession
        let liveCaptionTranscriber = self.liveCaptionTranscriber
        self.stream = nil
        self.systemOutput = nil
        self.liveCaptionTranscriber = nil
        self.micSession = nil
        self.micOutput = nil

        micSession?.stopRunning()

        var stopCaptureError: Error?
        do {
            try await scStream?.stopCapture()
        } catch {
            stopCaptureError = error
        }

        let sessionDir = self.sessionDir
        if let sessionDir {
            self.lastSessionDir = sessionDir
        }
        stopLiveCaptions(liveCaptionTranscriber, saveTo: sessionDir)

        let finishedSystemURL = try await systemOutput?.finishWriting()
        let finishedMicURL = try await micOutput?.finishWriting()

        if let stopCaptureError {
            throw stopCaptureError
        }

        guard let sessionDir else {
            throw RecorderError.noSessionDir
        }

        // Merge system + mic into a single high-quality recording.m4a.
        let mergedURL = RecordingStore.audioFileURL(in: sessionDir)
        let sourceURLs = [finishedSystemURL, finishedMicURL].compactMap { $0 }

        do {
            try await AudioMixer.mix(
                sources: sourceURLs,
                to: mergedURL
            )
            AudioCaptureDiagnostics.write(
                sources: sourceURLs,
                output: mergedURL,
                to: sessionDir
            )
            // Only delete intermediates on success; on failure the caller
            // (stop/retry flow) can still inspect the two raw files.
            for sourceURL in sourceURLs {
                try? FileManager.default.removeItem(at: sourceURL)
            }
        } catch {
            AudioCaptureDiagnostics.write(
                sources: sourceURLs,
                output: nil,
                to: sessionDir
            )
            // Merge failed — leave intermediates for debugging and surface the
            // error to the caller. Transcription downstream needs recording.m4a
            // to exist, so rethrow.
            throw error
        }

        return sessionDir
    }

    /// Merge the latest peak + spectrum from either audio source into the
    /// live recording meter. Called from the capture queues — we hop to the
    /// main actor, take the max of system + mic, and cap publish rate to 30 Hz.
    nonisolated func ingestMeterFrame(_ frame: AudioMeterFrame) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let now = CACurrentMediaTime()

            // Hold peak with light decay so a single-buffer spike still reads
            // visually over the ~33ms publish window.
            let smoothed = max(self.audioLevel * 0.82, frame.peak)

            if now - self.lastLevelPublish >= 1.0 / 30.0 {
                self.lastLevelPublish = now
                self.audioLevel = smoothed

                let incoming = normalizeSpectrum(frame.bands)
                let decayed = self.audioSpectrumLevels.map { $0 * 0.72 }
                self.audioSpectrumLevels = zip(decayed, incoming).map(max)
            }

            if now - self.lastHistoryPublish >= Self.historySampleInterval {
                self.lastHistoryPublish = now
                let historyValue = min(1, pow(max(smoothed, 0), 0.75))
                var history = self.audioLevelHistory
                history.append(historyValue)
                if history.count > Self.spectrumBucketCount {
                    history.removeFirst(history.count - Self.spectrumBucketCount)
                }
                self.audioLevelHistory = history
            }
        }
    }

    func reset() {
        cancelRefreshAppsRetry()
        stopMonitoringOutputDeviceChanges()
        state = .idle
        elapsedSeconds = 0
        audioLevel = 0
        audioSpectrumLevels = Array(repeating: 0, count: Self.spectrumBucketCount)
        audioLevelHistory = Array(repeating: 0, count: Self.spectrumBucketCount)
        lastLevelPublish = 0
        lastHistoryPublish = 0
        liveCaptionSegments = []
        liveCaptionMessage = nil
        liveCaptionIsFinal = false
        activeRecordingID = nil
        sessionDir = nil
        lastSessionDir = nil
        recordingSuggestion = nil
        meetingPrompt = nil
        micSession?.stopRunning()
        stream = nil
        systemOutput = nil
        stopLiveCaptions(saveTo: nil)
        liveCaptionTranscriber = nil
        currentOutputAudioDeviceID = nil
        micSession = nil
        micOutput = nil
        recordingAppName = nil
        detectedMeetingRecordingContext = nil
        pendingDetectedMeetingRecordingContext = nil
        autoStopRequest = nil
    }

    private func normalizeSpectrum(_ levels: [Float]) -> [Float] {
        if levels.count == Self.spectrumBucketCount {
            return levels
        }
        if levels.count > Self.spectrumBucketCount {
            return Array(levels.prefix(Self.spectrumBucketCount))
        }
        return levels + Array(repeating: 0, count: Self.spectrumBucketCount - levels.count)
    }

    private func applyLiveCaptionSnapshot(_ snapshot: LiveCaptionSnapshot) {
        switch snapshot.phase {
        case .preparing, .listening:
            liveCaptionMessage = snapshot.message
        case .unavailable, .failed:
            // Surface the error/reconnect status via `liveCaptionMessage`
            // but do NOT wipe `liveCaptionSegments`: a transient
            // WebSocket failure should not erase the caption history
            // the user has already accumulated. Preserving the last-
            // known segments means a flaky network surfaces as a
            // status badge while the user keeps reading what they
            // already had.
            liveCaptionMessage = snapshot.message
        }

        // Only adopt segments when the snapshot actually carries them
        // (typical for `.listening`); status-only snapshots leave the
        // existing segments untouched so the panel does not flash the
        // placeholder during a brief preparing/listening round-trip.
        if !snapshot.segments.isEmpty {
            liveCaptionSegments = snapshot.segments
            liveCaptionIsFinal = snapshot.allSegmentsFinal
        }
    }

    func setSpeechLanguage(_ localeIdentifier: String) {
        let selected = SpeechLanguageOption.option(for: localeIdentifier)
        AppConfig.shared.cloudLanguage = selected.id

        guard state == .recording else { return }
        restartLiveCaptions(localeIdentifier: selected.id)
    }

    private func restartLiveCaptions(localeIdentifier: String) {
        guard #available(macOS 26.0, *) else { return }
        guard let systemOutput else { return }

        let oldTranscriber = liveCaptionTranscriber
        liveCaptionTranscriber = nil
        systemOutput.onLiveCaptionSampleBuffer = nil
        stopLiveCaptions(oldTranscriber, saveTo: nil)

        liveCaptionSegments = []
        liveCaptionMessage = "Switching live caption language…"
        liveCaptionIsFinal = false

        startLiveCaptionProvider(for: systemOutput, localeIdentifier: localeIdentifier)
    }

    private func startLiveCaptions(for systemOutput: SystemAudioOutput) async {
        guard #available(macOS 26.0, *) else {
            liveCaptionMessage = "Live captions require macOS 26."
            return
        }

        if AppConfig.shared.backendRealtimeLiveCaptionsEnabled {
            startLiveCaptionProvider(
                for: systemOutput,
                localeIdentifier: AppConfig.shared.normalizedCloudLanguage
            )
            return
        }

        let speechStatus = await LiveCaptionTranscriber.requestSpeechAuthorizationIfNeeded()
        guard speechStatus == .authorized else {
            liveCaptionMessage = "Enable Speech Recognition to use live captions."
            return
        }

        startLiveCaptionProvider(
            for: systemOutput,
            localeIdentifier: AppConfig.shared.selectedSpeechLanguage.id
        )
    }

    private func startLiveCaptionProvider(
        for systemOutput: SystemAudioOutput,
        localeIdentifier: String
    ) {
        if AppConfig.shared.backendRealtimeLiveCaptionsEnabled {
            guard let bearerToken = AuthSessionStore.shared.bearerToken() else {
                liveCaptionMessage = "Sign in to Recappi Cloud to use backend live captions."
                liveCaptionSegments = []
                liveCaptionIsFinal = false
                return
            }

            let client = RecappiAPIClient(
                origin: AppConfig.shared.effectiveBackendBaseURL,
                bearerToken: bearerToken
            )
            let backendTranscriber = BackendRealtimeLiveCaptionTranscriber(
                client: client,
                language: Self.normalizedRealtimeLanguage(localeIdentifier)
            ) { [weak self] snapshot in
                self?.applyLiveCaptionSnapshot(snapshot)
            }
            liveCaptionTranscriber = backendTranscriber
            systemOutput.onLiveCaptionSampleBuffer = { [weak backendTranscriber] sampleBuffer in
                backendTranscriber?.append(sampleBuffer)
            }
            backendTranscriber.start()
            return
        }

        guard #available(macOS 26.0, *) else { return }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            liveCaptionSegments = []
            liveCaptionMessage = "Enable Speech Recognition to use live captions."
            liveCaptionIsFinal = false
            return
        }

        let liveTranscriber = LiveCaptionTranscriber { [weak self] snapshot in
            self?.applyLiveCaptionSnapshot(snapshot)
        }
        liveCaptionTranscriber = liveTranscriber
        systemOutput.onLiveCaptionSampleBuffer = { [weak liveTranscriber] sampleBuffer in
            liveTranscriber?.append(sampleBuffer)
        }
        liveTranscriber.start(localeIdentifier: localeIdentifier)
    }

    private static func normalizedRealtimeLanguage(_ localeIdentifier: String) -> String {
        let trimmed = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if let base = trimmed.split(separator: "-").first, !base.isEmpty {
            return String(base)
        }
        return "en"
    }

    private func stopLiveCaptions(saveTo sessionDir: URL?) {
        stopLiveCaptions(liveCaptionTranscriber, saveTo: sessionDir)
    }

    private func stopLiveCaptions(_ transcriber: Any?, saveTo sessionDir: URL?) {
        if #available(macOS 26.0, *), let transcriber = transcriber as? LiveCaptionTranscriber {
            transcriber.stop(saveTo: sessionDir)
        }
        if let transcriber = transcriber as? BackendRealtimeLiveCaptionTranscriber {
            transcriber.stop(saveTo: sessionDir)
        }
    }

    // MARK: - Permissions

    private func requestMicrophoneAccessIfNeeded() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted { throw RecorderError.micDenied }
        case .denied, .restricted:
            throw RecorderError.micDenied
        @unknown default:
            throw RecorderError.micDenied
        }
    }

    func requestAutoStopForDetectedMeetingIfNeeded() {
        guard state == .recording, let context = detectedMeetingRecordingContext else { return }
        detectedMeetingRecordingContext = nil
        autoStopRequest = AutoStopRecordingRequest(context: context)
    }

    @discardableResult
    func focusRecordingSourceIfAvailable() -> Bool {
        guard state == .recording else { return false }
        guard let bundleID = selectedApp?.id ?? detectedMeetingRecordingContext?.appID else { return false }

        Task { [bundleID] in
            if BrowserMeetingDetector.supports(bundleID: bundleID),
               await BrowserMeetingDetector.focusMeetingTab(bundleID: bundleID) {
                return
            }

            _ = await MainActor.run {
                Self.activateApplication(bundleID: bundleID)
            }
        }

        return true
    }

    @discardableResult
    private static func activateApplication(bundleID: String) -> Bool {
        let canonicalBundleID = BundleCollapser.parent(of: bundleID)
        let runningApps = NSWorkspace.shared.runningApplications.filter { app in
            guard let runningBundleID = app.bundleIdentifier else { return false }
            return BundleCollapser.matches(runningBundleID, selected: canonicalBundleID)
        }

        let app = runningApps.first { $0.bundleIdentifier == canonicalBundleID }
            ?? runningApps.first
        if let app {
            _ = app.unhide()
            return app.activate(options: [.activateAllWindows])
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: canonicalBundleID) else {
            return false
        }
        NSWorkspace.shared.open(url)
        return true
    }

    private func startUITestRecording(
        metadata: RecordingSessionMetadata,
        autoStopContext: DetectedMeetingRecordingContext?
    ) throws {
        guard let fixturePath = uiTestMode.audioFixturePath, !fixturePath.isEmpty else {
            throw RecorderError.missingUITestFixture
        }
        guard FileManager.default.fileExists(atPath: fixturePath) else {
            throw RecorderError.missingUITestFixture
        }

        let sessionDir = try RecordingStore.createSessionDirectory()
        RecordingStore.saveSessionMetadata(metadata, in: sessionDir)
        self.sessionDir = sessionDir
        self.lastSessionDir = nil
        self.audioLevel = 0
        self.audioSpectrumLevels = Array(repeating: 0, count: Self.spectrumBucketCount)
        self.audioLevelHistory = Array(repeating: 0, count: Self.spectrumBucketCount)
        self.lastLevelPublish = 0
        self.lastHistoryPublish = 0
        self.liveCaptionSegments = []
        self.liveCaptionMessage = nil
        self.liveCaptionIsFinal = false
        if let simulatedLiveCaptionText = uiTestMode.simulatedLiveCaptionText,
           !simulatedLiveCaptionText.isEmpty {
            // UI tests inject a single fixture string; surface it as one
            // simulated segment with a stable id so consumers exercise
            // the segment-aware code path even without a real upstream.
            self.liveCaptionSegments = [
                LiveCaptionSegment(
                    id: "ui-test-fixture",
                    sourceText: simulatedLiveCaptionText,
                    translatedText: nil,
                    isFinal: false,
                    sequence: 0
                )
            ]
            self.liveCaptionIsFinal = false
        }
        self.detectedMeetingRecordingContext = autoStopContext
        self.state = .recording
        self.elapsedSeconds = 0
        self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsedSeconds += 1
            }
        }
    }

    private func recordingSessionMetadata() -> RecordingSessionMetadata {
        let sourceApp = selectedApp
        let promptTitle = meetingPrompt?.promptTitle ?? recordingSuggestion?.promptTitle
        let appName = sourceApp?.name ?? meetingPrompt?.appName ?? recordingSuggestion?.appName
        let bundleID = sourceApp?.id ?? meetingPrompt?.appID ?? recordingSuggestion?.appID
        let sourceTitle = promptTitle ?? appName ?? "All system audio"
        return RecordingSessionMetadata.capture(
            sourceTitle: sourceTitle,
            sourceAppName: appName,
            sourceBundleID: bundleID
        )
    }

    private func detectedMeetingContextForNextRecording() -> DetectedMeetingRecordingContext? {
        if let pendingDetectedMeetingRecordingContext {
            return pendingDetectedMeetingRecordingContext
        }
        guard let prompt = meetingPrompt else { return nil }
        return DetectedMeetingRecordingContext(
            appID: prompt.appID,
            appName: prompt.appName,
            promptTitle: prompt.promptTitle
        )
    }

    private func stopUITestRecording() throws -> URL {
        guard let sessionDir else { throw RecorderError.noSessionDir }
        guard let fixturePath = uiTestMode.audioFixturePath, !fixturePath.isEmpty else {
            throw RecorderError.missingUITestFixture
        }

        let destination = RecordingStore.audioFileURL(in: sessionDir)
        let fixtureURL = URL(fileURLWithPath: fixturePath)
        if FileManager.default.fileExists(atPath: destination.path) {
            try? FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: fixtureURL, to: destination)
        self.lastSessionDir = sessionDir
        return sessionDir
    }

    private func makeSystemAudioConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        // Keep ScreenCaptureKit on a conservative app-friendly format.
        // Some output devices report 6/8/16-channel layouts or unusual
        // sample rates; forwarding those directly into realtime AAC encoding
        // has produced loud noise on other machines.
        config.sampleRate = 48_000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        return config
    }

    private func startMonitoringOutputDeviceChanges() throws {
        let monitor = try DefaultAudioDeviceMonitor { [weak self] change in
            Task { @MainActor [weak self] in
                await self?.handleAudioDeviceChange(change)
            }
        }
        self.audioDeviceMonitor = monitor
    }

    private func stopMonitoringOutputDeviceChanges() {
        audioDeviceMonitor?.stop()
        audioDeviceMonitor = nil
    }

    private func handleAudioDeviceChange(_ change: DefaultAudioDeviceMonitor.Change) async {
        switch change {
        case .output(let deviceID):
            await handleOutputDeviceChange(deviceID)
        case .input:
            reconfigureMicrophoneForDefaultInput()
        }
    }

    private func handleOutputDeviceChange(_ deviceID: AudioDeviceID) async {
        guard state == .recording else { return }
        guard currentOutputAudioDeviceID != deviceID else { return }
        guard let stream else {
            currentOutputAudioDeviceID = deviceID
            return
        }

        currentOutputAudioDeviceID = deviceID

        do {
            try await stream.updateConfiguration(makeSystemAudioConfiguration())
        } catch {
            print("Failed to update output audio configuration: \(error.localizedDescription)")
        }
    }

    private func reconfigureMicrophoneForDefaultInput() {
        guard state == .recording else { return }
        guard let micSession else { return }
        guard let newDevice = AVCaptureDevice.default(for: .audio) else { return }

        let existingInputs = micSession.inputs.compactMap { $0 as? AVCaptureDeviceInput }
        if existingInputs.contains(where: { $0.device.uniqueID == newDevice.uniqueID }) {
            return
        }

        do {
            let newInput = try AVCaptureDeviceInput(device: newDevice)

            micSession.beginConfiguration()
            existingInputs.forEach { micSession.removeInput($0) }

            if micSession.canAddInput(newInput) {
                micSession.addInput(newInput)
                micSession.commitConfiguration()
                return
            }

            for oldInput in existingInputs where micSession.canAddInput(oldInput) {
                micSession.addInput(oldInput)
            }
            micSession.commitConfiguration()
            print("Failed to switch microphone input: capture session rejected the new device")
        } catch {
            print("Failed to switch microphone input: \(error.localizedDescription)")
        }
    }
}
