import AVFoundation
import AppKit
import CoreAudio
import RecappiCaptureCore
@preconcurrency import ScreenCaptureKit

private struct AudioAppBundleMetadata {
    let displayName: String?
    let icon: NSImage?
}

private struct PreparedMicrophoneCapture: @unchecked Sendable {
    let session: AVCaptureSession
    let output: MicAudioOutput

    func startRunning() {
        session.startRunning()
    }
}

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
    @Published var state: RecorderState = .idle
    @Published var runningApps: [AudioApp] = []
    @Published var selectedApp: AudioApp?
    @Published var recordingSuggestion: RecordingSuggestion?
    @Published var meetingPrompt: MeetingPrompt?
    @Published var recordingAppName: String?
    @Published private(set) var detectedMeetingRecordingContext: DetectedMeetingRecordingContext?
    @Published private(set) var autoStopRequest: AutoStopRecordingRequest?
    let runtimeState = RecordingRuntimeState(bucketCount: AudioRecorder.spectrumBucketCount)
    var elapsedSeconds: Int {
        get { runtimeState.elapsedSeconds }
        set { runtimeState.elapsedSeconds = newValue }
    }
    var audioLevel: Float {
        get { runtimeState.audioLevel }
        set { runtimeState.audioLevel = newValue }
    }
    var audioSpectrumLevels: [Float] {
        get { runtimeState.audioSpectrumLevels }
        set { runtimeState.audioSpectrumLevels = newValue }
    }
    var audioLevelHistory: [Float] {
        get { runtimeState.audioLevelHistory }
        set { runtimeState.audioLevelHistory = newValue }
    }
    /// Ordered live-caption segments produced by the active transcriber.
    /// Empty when no caption history has been accumulated yet (or after
    /// an explicit reset). UI consumers branch on `isEmpty` for the
    /// placeholder state and read segment-level metadata for natural
    /// paragraph breaks + future bilingual rendering.
    @Published private(set) var liveCaptionSegments: [LiveCaptionSegment] = []
    @Published private(set) var liveCaptionMessage: String?
    @Published private(set) var liveCaptionStatusPhase: LiveCaptionSnapshot.Phase?
    @Published private(set) var activeLiveCaptionConfiguration: LiveCaptionRecordingConfiguration?
    @Published private(set) var liveCaptionLifecycleRevision: UInt64 = 0
    /// True when every segment in `liveCaptionSegments` is `isFinal`. UI
    /// can use this to gate animations or styling for "stable" captions.
    @Published private(set) var liveCaptionIsFinal: Bool = false
    @Published private(set) var activeRecordingID: UUID?
    @Published private(set) var includesMicrophoneAudio: Bool = AppConfig.shared.recordingIncludeMicrophoneAudio
    private var hasIncludedMicrophoneAudioInCurrentRecording = AppConfig.shared.recordingIncludeMicrophoneAudio
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
    /// Phase 2 — explicit lifecycle for the active live-caption
    /// provider. `.transitioning` is observable to `stopRecording`, so
    /// a stop arriving mid-restart no longer drops caption history.
    /// See `LiveCaptionState` for the case semantics.
    private var liveCaptionState: LiveCaptionState = .none {
        didSet { liveCaptionLifecycleRevision &+= 1 }
    }
    /// Per-`liveCaptionState` snapshot subscription. Created when a
    /// `RealtimeLiveCaptionActor` is installed as the active provider,
    /// cancelled when the state advances past `.running(.backend(...))`.
    /// The MainActor `for-await` loop bridges the actor's
    /// `AsyncStream<LiveCaptionSnapshot>` into
    /// `applyLiveCaptionSnapshot(_:)` so the UI sees the same shape it
    /// did under the legacy callback.
    private var liveCaptionSnapshotTask: Task<Void, Never>?
    /// Accumulator for caption entries produced across the lifetime of
    /// a single recording. Each transcriber drains its `[LiveCaption-
    /// Entry]` snapshot here on rotation; `stopRecording` flushes once
    /// at the end. Replaces the per-transcriber disk-writer that used
    /// to lose carryover when a stop interrupted a restart.
    private let liveCaptionStore = RecordingCaptionStore()
    private var liveCaptionCarryoverSegments: [LiveCaptionSegment] = []
    private let systemCaptureQueue = DispatchQueue(label: "RecappiMini.SystemCapture")
    private var coreAudioTapCapture: CoreAudioProcessTapCapture?
    private var audioDeviceMonitor: DefaultAudioDeviceMonitor?
    private var currentOutputAudioDeviceID: AudioDeviceID?
    private var microphoneDeviceNotificationTokens: [NSObjectProtocol] = []

    // --- Microphone (AVCaptureSession) pipeline ---
    private var micSession: AVCaptureSession?
    private var micOutput: MicAudioOutput?
    private let micCaptureQueue = DispatchQueue(label: "RecappiMini.MicCapture")

    private var sessionDir: URL?
    private var timer: Timer?
    /// Timestamp of the last `audioLevel` publish; capped at
    /// `levelPublishInterval` (~20 Hz) so SwiftUI doesn't burn a
    /// re-render per ScreenCaptureKit buffer. The capture-side meter
    /// gate only emits ~12 Hz/source, so above ~20 Hz the extra publish
    /// ticks carry decay-only updates while re-rendering every view that
    /// observes this object — pure cost until the meter splits onto its
    /// own observable.
    private var lastLevelPublish: CFTimeInterval = 0
    private var lastHistoryPublish: CFTimeInterval = 0
    private var pendingMeterPeak: Float = 0
    private var pendingMeterBands: [Float] = Array(repeating: 0, count: AudioRecorder.spectrumBucketCount)
    /// Reused storage for the per-publish spectrum compute. Held across
    /// publishes so `ingestMeterFrame` no longer allocates a `decayed`
    /// intermediate + a fresh result array on every publish; it is
    /// filled element-wise from the live `audioSpectrumLevels` (decay)
    /// and `pendingMeterBands` (peak), then assigned once so the
    /// `@Published` property still fires exactly one change per publish.
    private var spectrumPublishScratch: [Float] = Array(repeating: 0, count: AudioRecorder.spectrumBucketCount)
    private let uiTestMode = UITestModeConfiguration.shared
    private var uiTestInjectedAudioApps: [String: AudioApp] = [:]
    private var uiTestInjectedActiveBundleIDs: Set<String> = []
    private var refreshAppsRetryTask: Task<Void, Never>?
    private var pendingDetectedMeetingRecordingContext: DetectedMeetingRecordingContext?
    /// Token returned by `ProcessInfo.beginActivity(_:reason:)` while a
    /// recording is in progress. Held for the lifetime of the
    /// recording so macOS doesn't suspend the network stack mid-stream
    /// (App Nap / idle system sleep). Released on `stop`/`reset`.
    private var recordingActivityToken: NSObjectProtocol?

    static let spectrumBucketCount = AudioSpectrumConfiguration.bucketCount
    /// Minimum spacing between `audioLevel` / `audioSpectrumLevels`
    /// publishes (~20 Hz). Lowered from 30 Hz: the capture meter gate
    /// emits ~12 Hz/source, so ticks above ~20 Hz mostly re-render the
    /// whole UI with decay-only deltas. The peak-decay smoothing math
    /// (0.82 hold / 0.72 spectrum decay) is unchanged; only the publish
    /// cadence drops, so the visible meter is ~33% fewer full re-renders.
    private static let levelPublishInterval: CFTimeInterval = 1.0 / 20.0
    private static let historySampleInterval: CFTimeInterval = 0.18
    private static var audioAppBundleMetadataByID: [String: AudioAppBundleMetadata] = [:]
    private nonisolated static let keepRawCaptureSourcesEnvKey = "RECAPPI_KEEP_RAW_CAPTURE_SOURCES"
    private nonisolated static let keepRawCaptureSourcesDefaultKey = "recappi.debug.keepRawCaptureSources"

    override init() {
        super.init()
        warmMicrophoneDeviceCache()
    }

    var currentSessionDir: URL? { sessionDir }

    private func warmMicrophoneDeviceCache() {
        let queue = micCaptureQueue
        queue.async {
            MicrophoneInputDevice.warmDeviceCache()
        }
    }

    func setRecordingMeterVisible(_ visible: Bool) {
        systemOutput?.setMeteringEnabled(visible)
        micOutput?.setMeteringEnabled(visible)
        guard !visible else { return }
        audioLevel = 0
        audioSpectrumLevels = Array(repeating: 0, count: Self.spectrumBucketCount)
        audioLevelHistory = Array(repeating: 0, count: Self.spectrumBucketCount)
        pendingMeterPeak = 0
        pendingMeterBands = Array(repeating: 0, count: Self.spectrumBucketCount)
    }

#if DEBUG
    /// Test seam: tests install a slow / scripted "stop" callback to
    /// hold the detached restart Task suspended past the moment a
    /// follow-up `restartLiveCaptions` invocation bumps the
    /// generation token. Production code never sets these.
    fileprivate var liveCaptionRestartStopOverrideForTesting: (@MainActor (LiveCaptionProvider?) async -> Void)?
    fileprivate var liveCaptionRestartStartOverrideForTesting: (@MainActor (String) -> Void)?

    /// Phase 2 — drain hook for snapshotting a provider's
    /// `[LiveCaptionEntry]` accumulator without touching its WebSocket
    /// state. Routed through the test seam so unit tests can drive the
    /// `RecordingCaptionStore` carryover path without standing up real
    /// network I/O.
    fileprivate var liveCaptionDrainOverrideForTesting: (@MainActor (LiveCaptionProvider?) -> [LiveCaptionEntry])?

    /// Install stub `stop` and `start` callbacks for the restart-
    /// live-captions flow. The stop closure is awaited; the start
    /// closure is invoked synchronously on the MainActor.
    func installLiveCaptionRestartHooksForTesting(
        stop: @MainActor @escaping (LiveCaptionProvider?) async -> Void,
        start: @MainActor @escaping (String) -> Void
    ) {
        liveCaptionRestartStopOverrideForTesting = stop
        liveCaptionRestartStartOverrideForTesting = start
    }

    /// Phase 2 — install the wider hook set used by the
    /// caption-loss-on-stop tests. Same `stop` / `start` semantics as
    /// `installLiveCaptionRestartHooksForTesting`, plus a `drain`
    /// callback that returns the entries the provider would have
    /// flushed to disk.
    func installPhase2LiveCaptionHooksForTesting(
        _ stub: StubLiveCaptionLifecycleHooks
    ) {
        liveCaptionRestartStopOverrideForTesting = stub.stop
        liveCaptionRestartStartOverrideForTesting = stub.start
        liveCaptionDrainOverrideForTesting = stub.drainEntries
    }

    /// Drive `restartLiveCaptions` from a test without needing the
    /// real `SystemAudioOutput`, ScreenCaptureKit, or macOS-26 guards.
    /// Mirrors production's serial-restart chain so the bug-#3 race
    /// reproduces (and stays fixed) in tests too.
    func restartLiveCaptionsForTesting(localeIdentifier: String) {
        let oldProvider = liveCaptionState.activeProvider
        // Phase 2 — snapshot the outgoing provider's captions into
        // the store BEFORE the close handshake begins. This is the
        // critical step that closes Codex Finding #2: even if a
        // `stopRecording` arrives while the transition Task is
        // suspended in its close-await, the old captions are already
        // in the store.
        let drainedEntries = drainEntriesUsingHooks(from: oldProvider)
        if !drainedEntries.isEmpty {
            liveCaptionStore.add(drainedEntries)
        }
        restartGeneration &+= 1
        let myGeneration = restartGeneration
        let previousRestartTask = pendingRestartTask
        let newTask = Task { @MainActor [weak self] in
            await previousRestartTask?.value
            await self?.performRestartLiveCaptionsBody(
                oldProvider: oldProvider,
                localeIdentifier: localeIdentifier,
                generation: myGeneration
            )
        }
        pendingRestartTask = newTask
        liveCaptionState = .transitioning(
            from: oldProvider,
            to: nil,
            transitionTask: newTask,
            generation: myGeneration
        )
    }

    /// Move the generation token forward without spawning a new
    /// restart. Used by the focused generation-guard unit test.
    func bumpRestartGenerationForTesting() {
        restartGeneration &+= 1
    }

    var restartGenerationForTesting: UInt64 { restartGeneration }

    /// Read-only handle on `pendingRestartTask` for the
    /// `reset()`-cancels-restart-chain regression test. Returns nil
    /// when there is no in-flight restart Task.
    var pendingRestartTaskForTesting: Task<Void, Never>? { pendingRestartTask }

    /// Install a custom long-running Task as `pendingRestartTask` so a
    /// test can verify `reset()` cancels (and clears) the in-flight
    /// restart chain. Production paths never assign to this field
    /// directly — `restartLiveCaptions(...)` is the only writer — but
    /// the seam lets us pin Bugbot Finding C without standing up a
    /// real restart Task.
    func setPendingRestartTaskForTesting(_ task: Task<Void, Never>?) {
        pendingRestartTask = task
    }

    /// Seed the live-caption state with a test sentinel object so the
    /// next call to `restartLiveCaptionsForTesting` captures a
    /// non-nil `oldProvider`. Used to reproduce the rapid-restart
    /// race where a follow-up restart captures `nil` and races
    /// ahead of the first restart's stop-await.
    func setLiveCaptionTranscriberForTesting(_ sentinel: AnyObject?) {
        if let sentinel {
            liveCaptionState = .running(
                provider: .testSentinel(sentinel),
                locale: "test-locale",
                generation: restartGeneration
            )
        } else {
            liveCaptionState = .none
        }
    }

    /// Phase 2 — seed the live-caption lifecycle into `.running` with
    /// a test sentinel. Mirrors what `startLiveCaptionProvider` does
    /// in production: installs a `.running(.testSentinel(...))`
    /// snapshot so downstream readers (including the stop-finalize
    /// path under test) observe a coherent `.running` snapshot.
    func installRunningLiveCaptionTranscriberForTesting(_ sentinel: AnyObject) {
        restartGeneration &+= 1
        liveCaptionState = .running(
            provider: .testSentinel(sentinel),
            locale: "test-locale",
            generation: restartGeneration
        )
    }

    /// Phase 2 — drive the stop-finalize path that `stopRecording`
    /// uses in production. Captures the same state-machine drain +
    /// flush logic without bringing up ScreenCaptureKit / mic / etc.
    func finalizeLiveCaptionsForStopTesting(saveTo sessionDir: URL?) async {
        await finalizeLiveCaptionsForStop(saveTo: sessionDir)
    }

    func applyLiveCaptionSnapshotForTesting(_ snapshot: LiveCaptionSnapshot) {
        applyLiveCaptionSnapshot(snapshot)
    }

    func installReconnectableBackendLiveCaptionProviderForTesting() {
        let client = RecappiAPIClient(origin: "https://example.test", bearerToken: "test-token")
        let connector = LiveRealtimeSessionConnector(client: client)
        let actor = RealtimeLiveCaptionActor(connector: connector, language: "en", mode: .transcription)
        liveCaptionState = .running(provider: .backend(actor), locale: "en-US", generation: restartGeneration)
    }

    func clearLiveCaptionProviderForTesting() {
        liveCaptionState = .none
    }
#endif

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

    func suggestRecording(for app: AudioApp, promptTitle: String, browserSessionKey: String? = nil) {
        meetingPrompt = nil
        recordingSuggestion = RecordingSuggestion(
            appID: app.id,
            appName: app.name,
            promptTitle: promptTitle,
            browserSessionKey: browserSessionKey
        )
    }

    func clearRecordingSuggestion() {
        recordingSuggestion = nil
    }

    func showMeetingPrompt(for app: AudioApp, promptTitle: String, browserSessionKey: String? = nil) {
        recordingSuggestion = nil
        meetingPrompt = MeetingPrompt(
            appID: app.id,
            appName: app.name,
            promptTitle: promptTitle,
            browserSessionKey: browserSessionKey
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
            promptTitle: suggestion.promptTitle,
            browserSessionKey: suggestion.browserSessionKey
        )
        recordingSuggestion = nil
        meetingPrompt = nil
        return true
    }

    func updateRecordingSuggestion(promptTitle: String, forAppID appID: String, browserSessionKey: String? = nil) {
        guard var suggestion = recordingSuggestion, suggestion.appID == appID else { return }
        let nextBrowserSessionKey = browserSessionKey ?? suggestion.browserSessionKey
        guard suggestion.promptTitle != promptTitle || suggestion.browserSessionKey != nextBrowserSessionKey else { return }
        suggestion = RecordingSuggestion(
            appID: suggestion.appID,
            appName: suggestion.appName,
            promptTitle: promptTitle,
            browserSessionKey: nextBrowserSessionKey
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
    private static func displayName(
        from metadata: AudioAppBundleMetadata,
        bundleID: String,
        fallback: String
    ) -> String {
        metadata.displayName ?? BundleCollapser.browserDisplayName(for: bundleID, fallback: fallback)
    }

    private static func audioAppBundleMetadata(for bundleID: String) -> AudioAppBundleMetadata {
        if let cached = audioAppBundleMetadataByID[bundleID] {
            return cached
        }

        let metadata = resolveAudioAppBundleMetadata(for: bundleID)
        audioAppBundleMetadataByID[bundleID] = metadata
        return metadata
    }

    private static func resolveAudioAppBundleMetadata(for bundleID: String) -> AudioAppBundleMetadata {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return AudioAppBundleMetadata(displayName: nil, icon: nil)
        }

        let bundle = Bundle(url: url)
        let name = (bundle?.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return AudioAppBundleMetadata(displayName: name, icon: icon)
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
        let sourceApps = applications.map {
            CaptureSourceApplication(bundleID: $0.bundleIdentifier, name: $0.applicationName)
        }
        let sources = CaptureSourceCatalog.sources(
            from: sourceApps,
            selfBundleID: selfBundleID,
            includeSystemSource: false
        )

        return sources.compactMap { source in
            guard let bundleID = source.bundleID else { return nil }
            return makeAudioApp(
                bundleID: bundleID,
                fallbackName: source.appName ?? source.label,
                active: active,
                scApp: nil
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
        let metadata = audioAppBundleMetadata(for: bundleID)
        let name = displayName(from: metadata, bundleID: bundleID, fallback: fallbackName)
        guard !name.isEmpty else { return nil }

        let rawIcon = (metadata.icon?.copy() as? NSImage) ?? NSImage()
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
        CaptureSourceCatalog.shouldInclude(bundleID: bundleID, selfBundleID: selfBundleID)
    }

    private func prepareMicrophoneCapture(micURL: URL) async throws -> PreparedMicrophoneCapture {
        let selectedMicrophoneID = AppConfig.shared.recordingMicrophoneDeviceID
        let selectionLogValue = Self.microphoneSelectionLogValue(for: selectedMicrophoneID)
        let shouldIncludeMicrophoneAudio = includesMicrophoneAudio
        let queue = micCaptureQueue

        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                do {
                    guard let micDevice = Self.preferredMicrophoneDevice(
                        selectedID: selectedMicrophoneID,
                        selectionLogValue: selectionLogValue
                    ) else {
                        throw RecorderError.noMicrophone
                    }
                    DiagnosticsLog.event(
                        "recording",
                        "mic.device name=\(DiagnosticsLog.sanitize(micDevice.localizedName, maxLength: 80)) uniqueIDHash=\(micDevice.uniqueID.hashValue) selection=\(selectionLogValue)"
                    )

                    let captureSession = AVCaptureSession()
                    let deviceInput = try AVCaptureDeviceInput(device: micDevice)
                    guard captureSession.canAddInput(deviceInput) else {
                        throw RecorderError.micSetupFailed
                    }
                    captureSession.addInput(deviceInput)

                    let mcWriter = SegmentedAudioWriter(finalURL: micURL, processingQueue: queue)
                    let mcOut = MicAudioOutput(writer: mcWriter)
                    mcOut.setIncludesAudio(shouldIncludeMicrophoneAudio)
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
                    captureOutput.setSampleBufferDelegate(mcOut, queue: queue)
                    guard captureSession.canAddOutput(captureOutput) else {
                        throw RecorderError.micSetupFailed
                    }
                    captureSession.addOutput(captureOutput)

                    continuation.resume(
                        returning: PreparedMicrophoneCapture(session: captureSession, output: mcOut)
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func startMicrophoneSession(_ capture: PreparedMicrophoneCapture) async {
        let queue = micCaptureQueue
        await withCheckedContinuation { continuation in
            queue.async {
                capture.startRunning()
                continuation.resume()
            }
        }
    }

    // MARK: - Start / Stop

    func startRecording() async throws {
        guard state == .idle else { return }
        setIncludesMicrophoneAudio(AppConfig.shared.recordingIncludeMicrophoneAudio)
        activeRecordingID = UUID()
        let metadata = recordingSessionMetadata()
        let autoStopContext = detectedMeetingContextForNextRecording()
        let disablesBackendLiveCaptions = RecappiPerformanceDebugOptions.disableBackendLiveCaptions()
        let usesMinimalRecordingUI = RecappiPerformanceDebugOptions.minimalRecordingUI()
        activeLiveCaptionConfiguration = disablesBackendLiveCaptions ? nil : liveCaptionRecordingConfiguration()
        DiagnosticsLog.event(
            "recording",
            "start.request selectedBundle=\(selectedApp?.id ?? "all-system-audio") includeMic=\(includesMicrophoneAudio) cloudCaptions=\(disablesBackendLiveCaptions ? "debug-disabled" : "backend") bilingual=\(activeLiveCaptionConfiguration?.showsTranslation ?? false) language=\(AppConfig.shared.normalizedCloudLanguage) perfMinimalUI=\(usesMinimalRecordingUI)"
        )
        pendingDetectedMeetingRecordingContext = nil
        recordingSuggestion = nil
        meetingPrompt = nil
        state = .starting

        if uiTestMode.isEnabled {
            DiagnosticsLog.event("recording", "start.ui_test fixture=\(uiTestMode.audioFixturePath ?? "none")")
            try startUITestRecording(metadata: metadata, autoStopContext: autoStopContext)
            return
        }

        do {
            try await requestMicrophoneAccessIfNeeded()
            DiagnosticsLog.event("permissions", "microphone.authorized")
            let systemAudioBackend = SystemAudioCaptureBackend.current
            let content: SCShareableContent?
            let display: SCDisplay?
            if systemAudioBackend == .screenCaptureKit {
                guard CapturePermissionPrimer.shared.hasScreenCaptureAccess() else {
                    DiagnosticsLog.warning("permissions", "screen_capture.denied_or_missing")
                    throw RecorderError.screenCaptureDenied
                }
                DiagnosticsLog.event("permissions", "screen_capture.authorized")

                let shareableContent = try await SCShareableContent.current
                guard let firstDisplay = shareableContent.displays.first else {
                    throw RecorderError.noDisplay
                }
                content = shareableContent
                display = firstDisplay
            } else {
                DiagnosticsLog.event("permissions", "system_audio.core_audio_tap requested")
                content = nil
                display = nil
            }

            let sessionDir = try RecordingStore.createSessionDirectory()
            RecordingStore.saveSessionMetadata(metadata, in: sessionDir)
            RecordingStore.stampAccount(AuthSessionStore.currentLocalSessionAccount(), in: sessionDir)
            self.sessionDir = sessionDir
            hasIncludedMicrophoneAudioInCurrentRecording = includesMicrophoneAudio
            DiagnosticsLog.event("recording", "session.created dir=\(sessionDir.lastPathComponent)")

            // Intermediate files; merged into recording.m4a at stop.
            let systemURL = sessionDir.appendingPathComponent("system.caf")
            let micURL = sessionDir.appendingPathComponent("mic.caf")

            let outputAudioDeviceID = try OutputDeviceAudioFormat.currentDefaultOutputDeviceID()
            self.currentOutputAudioDeviceID = outputAudioDeviceID

            // --- System audio pipeline ---
            let sysWriter = SegmentedAudioWriter(finalURL: systemURL, processingQueue: systemCaptureQueue)
            let sysOut = SystemAudioOutput(writer: sysWriter)
            sysOut.onMeterFrame = { [weak self] frame in
                self?.ingestMeterFrame(frame)
            }
            if disablesBackendLiveCaptions {
                DiagnosticsLog.warning(
                    "live-caption",
                    "provider.disabled reason=performance_debug flag=\(RecappiPerformanceDebugOptions.disableBackendLiveCaptionsEnvKey)"
                )
            } else {
                await startLiveCaptions(for: sysOut)
            }
            self.systemOutput = sysOut

            switch systemAudioBackend {
            case .screenCaptureKit:
                guard let content, let display else { throw RecorderError.noDisplay }
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
                DiagnosticsLog.event("recording", "system_audio.backend screen_capture_kit")

            case .coreAudioProcessTap:
                let tapCapture = CoreAudioProcessTapCapture(
                    selectedBundleID: selectedApp?.id,
                    selfBundleID: Bundle.main.bundleIdentifier ?? "com.recappi.mini",
                    output: sysOut,
                    captureQueue: systemCaptureQueue
                )
                try await Task.detached(priority: .userInitiated) {
                    try tapCapture.start()
                }.value
                self.coreAudioTapCapture = tapCapture
                recordingAppName = selectedApp?.name
                DiagnosticsLog.event("recording", "system_audio.backend core_audio_process_tap")
            }

            // --- Microphone pipeline ---
            let microphoneCapture = try await prepareMicrophoneCapture(micURL: micURL)
            self.micSession = microphoneCapture.session
            self.micOutput = microphoneCapture.output

            // --- Start both pipelines ---
            try startMonitoringOutputDeviceChanges()
            switch systemAudioBackend {
            case .screenCaptureKit:
                try await stream?.startCapture()
            case .coreAudioProcessTap:
                break
            }
            await startMicrophoneSession(microphoneCapture)
            microphoneCapture.output.setIncludesAudio(includesMicrophoneAudio)
            DiagnosticsLog.event(
                "recording",
                "capture.started dir=\(sessionDir.lastPathComponent) selectedBundle=\(selectedApp?.id ?? "all-system-audio") includeMic=\(includesMicrophoneAudio) microphone=\(microphoneSelectionLogValue) outputDevice=\(outputAudioDeviceID)"
            )

            self.audioLevel = 0
            self.audioSpectrumLevels = Array(repeating: 0, count: Self.spectrumBucketCount)
            self.audioLevelHistory = Array(repeating: 0, count: Self.spectrumBucketCount)
            self.lastLevelPublish = 0
            self.lastHistoryPublish = 0
            self.pendingMeterPeak = 0
            self.pendingMeterBands = Array(repeating: 0, count: Self.spectrumBucketCount)
            self.detectedMeetingRecordingContext = autoStopContext
            self.state = .recording
            beginRecordingProcessActivity()
            self.elapsedSeconds = 0
            self.timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.elapsedSeconds += 1
                }
            }
        } catch {
            DiagnosticsLog.error("recording", "start.failed \(DiagnosticsLog.errorSummary(error))")
            activeRecordingID = nil
            activeLiveCaptionConfiguration = nil
            detectedMeetingRecordingContext = nil
            stopMonitoringOutputDeviceChanges()
            self.micSession?.stopRunning()
            self.stream = nil
            self.coreAudioTapCapture?.stop()
            self.coreAudioTapCapture = nil
            self.systemOutput = nil
            self.micSession = nil
            self.micOutput = nil
            self.stopLiveCaptions(saveTo: nil)
            endRecordingProcessActivity()
            throw error
        }
    }

    /// Tell `ProcessInfo` that a user-initiated activity is running and
    /// the system should not put it to sleep. Pairs with
    /// `endRecordingProcessActivity()` — failing to balance these
    /// re-introduces the App Nap-driven socket stall this fix targets.
    private func beginRecordingProcessActivity() {
        guard recordingActivityToken == nil else { return }
        let token = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Recappi live captions"
        )
        recordingActivityToken = token
    }

    private func endRecordingProcessActivity() {
        guard let token = recordingActivityToken else { return }
        ProcessInfo.processInfo.endActivity(token)
        recordingActivityToken = nil
    }

    func stopRecording() async throws -> URL {
        guard state == .recording else {
            throw RecorderError.notRecording
        }

        DiagnosticsLog.event(
            "recording",
            "stop.request dir=\(sessionDir?.lastPathComponent ?? "none") elapsedSeconds=\(elapsedSeconds)"
        )
        detectedMeetingRecordingContext = nil
        activeLiveCaptionConfiguration = nil
        self.state = .processing(.savingAudio)
        self.timer?.invalidate()
        self.timer = nil
        stopMonitoringOutputDeviceChanges()
        endRecordingProcessActivity()

        if uiTestMode.isEnabled {
            return try stopUITestRecording()
        }

        // Take local ownership and clear the live capture properties first.
        // If any async stop/finalize step throws, the microphone should still
        // be released immediately instead of staying captured until app quit.
        let scStream = self.stream
        let coreAudioTapCapture = self.coreAudioTapCapture
        let systemOutput = self.systemOutput
        let micOutput = self.micOutput
        let micSession = self.micSession
        self.stream = nil
        self.coreAudioTapCapture = nil
        self.systemOutput = nil
        self.micSession = nil
        self.micOutput = nil

        micSession?.stopRunning()
        coreAudioTapCapture?.stop()

        var stopCaptureError: Error?
        do {
            try await scStream?.stopCapture()
        } catch {
            stopCaptureError = error
            DiagnosticsLog.error("recording", "screen_capture.stop.failed \(DiagnosticsLog.errorSummary(error))")
        }

        let sessionDir = self.sessionDir
        if let sessionDir {
            self.lastSessionDir = sessionDir
        }
        // Phase 2 — route through the state-aware finalize path so a
        // `stopRecording` arriving mid-restart drains the in-flight
        // transition properly and flushes `liveCaptionStore` once.
        // The store already holds the outgoing transcriber's entries
        // (snapshotted at restart time) so caption history is
        // preserved even if the transition Task gets cancelled here.
        await finalizeLiveCaptionsForStop(saveTo: sessionDir)

        let finishedSystemURL = try await systemOutput?.finishWriting()
        let finishedMicURL = try await micOutput?.finishWriting()
        let captureHealth = Self.captureHealthSnapshots(
            systemOutput: systemOutput,
            micOutput: micOutput
        )
        DiagnosticsLog.event(
            "recording",
            "writers.finished system=\(Self.fileSummary(finishedSystemURL)) mic=\(Self.fileSummary(finishedMicURL))"
        )
        DiagnosticsLog.event("recording", Self.captureHealthSummary(captureHealth))

        if hasIncludedMicrophoneAudioInCurrentRecording, finishedMicURL == nil {
            DiagnosticsLog.error(
                "recording",
                "mic.capture_missing dir=\(sessionDir?.lastPathComponent ?? "none")"
            )
            throw RecorderError.micCaptureFailed
        }

        if let stopCaptureError {
            throw stopCaptureError
        }

        guard let sessionDir else {
            throw RecorderError.noSessionDir
        }

        // Merge system + mic into a single high-quality recording.m4a.
        let mergedURL = RecordingStore.audioFileURL(in: sessionDir)
        let sourceURLs = [
            finishedSystemURL,
            hasIncludedMicrophoneAudioInCurrentRecording ? finishedMicURL : nil,
        ].compactMap { $0 }
        guard !sourceURLs.isEmpty else {
            DiagnosticsLog.error(
                "recording",
                "capture.no_audio_sources dir=\(sessionDir.lastPathComponent)"
            )
            AudioCaptureDiagnostics.write(
                sources: [],
                output: nil,
                to: sessionDir,
                captureHealth: captureHealth
            )
            throw RecorderError.noCapturedAudio
        }

        do {
            try await AudioMixer.mix(
                sources: sourceURLs,
                to: mergedURL
            )
            DiagnosticsLog.event(
                "recording",
                "mix.succeeded sources=\(sourceURLs.count) output=\(Self.fileSummary(mergedURL))"
            )
            AudioCaptureDiagnostics.write(
                sources: sourceURLs,
                output: mergedURL,
                to: sessionDir,
                captureHealth: captureHealth
            )
            // Only delete intermediates on success; on failure the caller
            // (stop/retry flow) can still inspect the two raw files.
            if Self.shouldKeepRawCaptureSources() {
                DiagnosticsLog.warning(
                    "recording",
                    "raw_sources.retained sources=\(sourceURLs.map(\.lastPathComponent).joined(separator: ","))"
                )
            } else {
                for sourceURL in sourceURLs {
                    try? FileManager.default.removeItem(at: sourceURL)
                }
            }
        } catch {
            DiagnosticsLog.error(
                "recording",
                "mix.failed sources=\(sourceURLs.count) \(DiagnosticsLog.errorSummary(error))"
            )
            AudioCaptureDiagnostics.write(
                sources: sourceURLs,
                output: nil,
                to: sessionDir,
                captureHealth: captureHealth
            )
            // Merge failed — leave intermediates for debugging and surface the
            // error to the caller. Transcription downstream needs recording.m4a
            // to exist, so rethrow.
            throw error
        }

        return sessionDir
    }

    func discardRecording() async {
        guard state == .recording else {
            reset()
            return
        }

        DiagnosticsLog.event(
            "recording",
            "discard.request dir=\(sessionDir?.lastPathComponent ?? "none") elapsedSeconds=\(elapsedSeconds)"
        )

        let scStream = self.stream
        let coreAudioTapCapture = self.coreAudioTapCapture
        let systemOutput = self.systemOutput
        let micOutput = self.micOutput
        let micSession = self.micSession
        let sessionDirToDelete = self.sessionDir

        detectedMeetingRecordingContext = nil
        activeLiveCaptionConfiguration = nil
        timer?.invalidate()
        timer = nil
        stopMonitoringOutputDeviceChanges()
        endRecordingProcessActivity()

        stream = nil
        self.coreAudioTapCapture = nil
        self.systemOutput = nil
        self.micSession = nil
        self.micOutput = nil
        micSession?.stopRunning()
        coreAudioTapCapture?.stop()

        clearDiscardedRecordingState()

        do {
            try await scStream?.stopCapture()
        } catch {
            DiagnosticsLog.error("recording", "discard.screen_capture.stop.failed \(DiagnosticsLog.errorSummary(error))")
        }

        await finalizeLiveCaptionsForStop(saveTo: nil)
        liveCaptionStore.clear()
        pendingRestartTask?.cancel()
        pendingRestartTask = nil
        liveCaptionState = .none

        _ = try? await systemOutput?.finishWriting()
        _ = try? await micOutput?.finishWriting()

        if let sessionDirToDelete {
            try? FileManager.default.removeItem(at: sessionDirToDelete)
        }
    }

    private func clearDiscardedRecordingState() {
        state = .idle
        elapsedSeconds = 0
        audioLevel = 0
        audioSpectrumLevels = Array(repeating: 0, count: Self.spectrumBucketCount)
        audioLevelHistory = Array(repeating: 0, count: Self.spectrumBucketCount)
        lastLevelPublish = 0
        lastHistoryPublish = 0
        pendingMeterPeak = 0
        pendingMeterBands = Array(repeating: 0, count: Self.spectrumBucketCount)
        liveCaptionSegments = []
        liveCaptionCarryoverSegments = []
        liveCaptionMessage = nil
        liveCaptionStatusPhase = nil
        activeLiveCaptionConfiguration = nil
        liveCaptionIsFinal = false
        activeRecordingID = nil
        sessionDir = nil
        lastSessionDir = nil
        recordingSuggestion = nil
        meetingPrompt = nil
        currentOutputAudioDeviceID = nil
        recordingAppName = nil
        detectedMeetingRecordingContext = nil
        pendingDetectedMeetingRecordingContext = nil
        autoStopRequest = nil
    }

    /// Merge the latest peak + spectrum from either audio source into the
    /// live recording meter. Called from the capture queues. We accumulate
    /// the max of system + mic frames between UI publishes; otherwise a
    /// high-frequency silent system stream can consume the publish-throttle
    /// window (~20 Hz, `levelPublishInterval`) and starve microphone frames
    /// from the visible waveform.
    nonisolated func ingestMeterFrame(_ frame: AudioMeterFrame) {
        RecordingPerformanceProbe.shared.noteMeterTaskScheduled()
        Task { @MainActor [weak self] in
            guard let self else { return }
            RecordingPerformanceProbe.shared.noteMeterFrameOnMain()
            self.ingestMeterFrame(frame, now: CACurrentMediaTime())
        }
    }

    func ingestMeterFrameForTesting(_ frame: AudioMeterFrame, now: CFTimeInterval) {
        ingestMeterFrame(frame, now: now)
    }

    private func ingestMeterFrame(_ frame: AudioMeterFrame, now: CFTimeInterval) {
        let incoming = normalizeSpectrum(frame.bands)
        if pendingMeterBands.count != Self.spectrumBucketCount {
            pendingMeterBands = Array(repeating: 0, count: Self.spectrumBucketCount)
        }
        pendingMeterPeak = max(pendingMeterPeak, frame.peak)
        // In-place max-merge into the reused accumulator. `incoming` is
        // `spectrumBucketCount`-long (normalizeSpectrum) and
        // `pendingMeterBands` was just re-sized to match, so the indices
        // align. This runs every frame (~12 Hz/source) — replacing the
        // old `zip(...).map(max)` here removes a per-frame array alloc.
        for i in pendingMeterBands.indices {
            pendingMeterBands[i] = max(pendingMeterBands[i], incoming[i])
        }

        // Hold peak with light decay so a single-buffer spike still reads
        // visually over the publish window.
        let smoothed = max(audioLevel * 0.82, pendingMeterPeak)

        if now - lastLevelPublish >= Self.levelPublishInterval {
            lastLevelPublish = now
            audioLevel = smoothed

            // Compute decay (×0.72) max'd with the accumulated bands into
            // reused scratch, then assign once. Same values + same single
            // `@Published` fire as the old `decayed`/`zip(...).map(max)`
            // pair, but without their two per-publish allocations. We read
            // decay from the live `audioSpectrumLevels` (not scratch) so an
            // external replacement of that property — e.g. the UI-test
            // `seedStateBoardMeterIfNeeded` fixture — is still respected.
            let current = audioSpectrumLevels
            if spectrumPublishScratch.count != Self.spectrumBucketCount {
                spectrumPublishScratch = Array(repeating: 0, count: Self.spectrumBucketCount)
            }
            let bandCount = min(current.count, pendingMeterBands.count)
            for i in 0..<Self.spectrumBucketCount {
                let decayed = i < current.count ? current[i] * 0.72 : 0
                let band = i < bandCount ? pendingMeterBands[i] : 0
                spectrumPublishScratch[i] = max(decayed, band)
            }
            audioSpectrumLevels = spectrumPublishScratch
            pendingMeterPeak = 0
            // Zero the accumulator in place — reuses the buffer instead of
            // allocating a fresh zero array each publish.
            for i in pendingMeterBands.indices {
                pendingMeterBands[i] = 0
            }
            RecordingPerformanceProbe.shared.noteLevelPublish()
        }

        if now - lastHistoryPublish >= Self.historySampleInterval {
            lastHistoryPublish = now
            let historyValue = min(1, pow(max(smoothed, 0), 0.75))
            var history = audioLevelHistory
            history.append(historyValue)
            if history.count > Self.spectrumBucketCount {
                history.removeFirst(history.count - Self.spectrumBucketCount)
            }
            audioLevelHistory = history
            RecordingPerformanceProbe.shared.noteHistoryPublish()
        }
    }

    func reset() {
        cancelRefreshAppsRetry()
        stopMonitoringOutputDeviceChanges()
        endRecordingProcessActivity()
        state = .idle
        elapsedSeconds = 0
        audioLevel = 0
        audioSpectrumLevels = Array(repeating: 0, count: Self.spectrumBucketCount)
        audioLevelHistory = Array(repeating: 0, count: Self.spectrumBucketCount)
        lastLevelPublish = 0
        lastHistoryPublish = 0
        pendingMeterPeak = 0
        pendingMeterBands = Array(repeating: 0, count: Self.spectrumBucketCount)
        liveCaptionSegments = []
        liveCaptionCarryoverSegments = []
        liveCaptionMessage = nil
        liveCaptionStatusPhase = nil
        activeLiveCaptionConfiguration = nil
        liveCaptionIsFinal = false
        activeRecordingID = nil
        sessionDir = nil
        lastSessionDir = nil
        recordingSuggestion = nil
        meetingPrompt = nil
        micSession?.stopRunning()
        stream = nil
        coreAudioTapCapture?.stop()
        coreAudioTapCapture = nil
        systemOutput = nil
        stopLiveCaptions(saveTo: nil)
        liveCaptionSnapshotTask?.cancel()
        liveCaptionSnapshotTask = nil
        // Cancel any in-flight restart chain so an orphaned task from
        // the previous recording can't chain into the next recording's
        // first `restartLiveCaptions` via `await previousRestartTask?.value`.
        // Without this, a fresh recording's first language/mode change
        // would block behind the dying session's close handshake
        // (Bugbot Finding C / `reset()` doesn't cancel pending restart task).
        pendingRestartTask?.cancel()
        pendingRestartTask = nil
        // Phase 2 — drop accumulated entries and the lifecycle on
        // recycle so the next recording starts from a clean slate.
        liveCaptionStore.clear()
        liveCaptionState = .none
        currentOutputAudioDeviceID = nil
        micSession = nil
        micOutput = nil
        recordingAppName = nil
        detectedMeetingRecordingContext = nil
        pendingDetectedMeetingRecordingContext = nil
        autoStopRequest = nil
    }

    func setIncludesMicrophoneAudio(_ included: Bool) {
        includesMicrophoneAudio = included
        AppConfig.shared.recordingIncludeMicrophoneAudio = included
        if included, state == .recording {
            hasIncludedMicrophoneAudioInCurrentRecording = true
        }
        micOutput?.setIncludesAudio(included)
        DiagnosticsLog.event("recording", "mic.include_changed included=\(included)")
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
        liveCaptionStatusPhase = snapshot.phase
        switch snapshot.phase {
        case .preparing, .listening:
            liveCaptionMessage = snapshot.message
        case .reconnecting, .unavailable, .failed:
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
            liveCaptionSegments = Self.mergedLiveCaptionSegments(
                carryover: liveCaptionCarryoverSegments,
                incoming: snapshot.segments
            )
            liveCaptionIsFinal = liveCaptionCarryoverSegments.allSatisfy(\.isFinal) && snapshot.allSegmentsFinal
        }
    }

    static func mergedLiveCaptionSegments(
        carryover: [LiveCaptionSegment],
        incoming: [LiveCaptionSegment]
    ) -> [LiveCaptionSegment] {
        guard !carryover.isEmpty else { return incoming }
        guard !incoming.isEmpty else { return carryover }
        return carryover + incoming
    }

    func setSpeechLanguage(_ localeIdentifier: String) {
        let selected = SpeechLanguageOption.option(for: localeIdentifier)
        AppConfig.shared.cloudLanguage = selected.id

        guard state == .recording else { return }
        restartLiveCaptions(localeIdentifier: selected.id)
    }

    func setLiveCaptionsBilingualEnabled(_ enabled: Bool) {
        AppConfig.shared.liveCaptionsBilingualEnabled = enabled

        guard state == .recording else { return }
        restartLiveCaptions(
            localeIdentifier: AppConfig.shared.normalizedCloudLanguage,
            message: "Switching live caption mode…"
        )
    }

    func setLiveCaptionsTranslationTargetLanguage(_ language: String) {
        AppConfig.shared.liveCaptionsTranslationTargetLanguage =
            LiveCaptionTranslationTargetLanguageOption.normalizedCode(language)

        guard state == .recording, AppConfig.shared.liveCaptionsBilingualEnabled else { return }
        restartLiveCaptions(
            localeIdentifier: AppConfig.shared.normalizedCloudLanguage,
            message: "Switching translation language…"
        )
    }

    /// Monotonically-increasing token used by `restartLiveCaptions` to
    /// detect that a newer restart has superseded an in-flight one.
    /// Each restart captures its own value before spawning the
    /// detached Task; if the value has moved by the time the Task
    /// resumes from `await stopLiveCaptionsAwaitingClose(...)`, the
    /// Task must decline to call `startLiveCaptionProvider`, otherwise
    /// it stomps the provider the newer restart already installed.
    private var restartGeneration: UInt64 = 0

    /// Tail of the restart chain. Each `restartLiveCaptions` Task
    /// `await`s the previous chain link's full value before doing
    /// its own work, ensuring the body of a follow-up restart cannot
    /// race ahead of a prior restart's stop-await. Without this, a
    /// rapid second restart that captures `oldTranscriber = nil`
    /// (because the first restart already cleared the field) would
    /// blow through `stopLiveCaptionsAwaitingClose`'s nil-guard and
    /// fire its next claim POST while the first restart's WebSocket
    /// is still mid-close — the exact concurrent-claim signature
    /// seen in production logs.
    private var pendingRestartTask: Task<Void, Never>?

    private func restartLiveCaptions(
        localeIdentifier: String,
        message: String = "Switching live caption language…"
    ) {
        guard !RecappiPerformanceDebugOptions.disableBackendLiveCaptions() else {
            DiagnosticsLog.warning(
                "live-caption",
                "restart.ignored reason=performance_debug_disabled"
            )
            return
        }
        guard #available(macOS 26.0, *) else { return }
        guard let systemOutput else { return }

        let oldProvider = liveCaptionState.activeProvider
        // Phase 2 — snapshot the outgoing provider's accumulated
        // captions into `liveCaptionStore` BEFORE clearing the field
        // and dispatching the close handshake. This is the load-
        // bearing step that closes Codex Finding #2: even if a
        // `stopRecording` arrives while the transition Task is
        // suspended in its close-await, the outgoing captions are
        // already safe in the store.
        let oldEntries = drainEntriesUsingHooks(from: oldProvider)
        if !oldEntries.isEmpty {
            liveCaptionStore.add(oldEntries)
        }
        // Tear down the previous snapshot subscription. A fresh one
        // is installed when `startLiveCaptionProvider` constructs the
        // next actor.
        liveCaptionSnapshotTask?.cancel()
        liveCaptionSnapshotTask = nil
        systemOutput.onLiveCaptionSampleBuffer = nil

        liveCaptionCarryoverSegments = liveCaptionSegments
        liveCaptionMessage = message
        liveCaptionStatusPhase = .preparing
        liveCaptionIsFinal = false

        restartGeneration &+= 1
        let myGeneration = restartGeneration
        let previousRestartTask = pendingRestartTask

        // Awaiting the old socket's close before claiming the new
        // session prevents the production "two GET /proxy/<userKey>
        // canceled" log signature: the server fan-out used to kill the
        // still-healthy WS the instant the next claim POST arrived.
        // We also chain off `previousRestartTask` so a second restart
        // that captured `oldProvider = nil` still waits for the
        // first restart's body (including its stop-await) to return.
        let newTask = Task { @MainActor [weak self] in
            await previousRestartTask?.value
            guard let self else { return }
            await self.performRestartLiveCaptionsBody(
                oldProvider: oldProvider,
                localeIdentifier: localeIdentifier,
                generation: myGeneration
            )
        }
        pendingRestartTask = newTask
        // Phase 2 — entering `.transitioning` makes the in-flight
        // restart observable to `finalizeLiveCaptionsForStop` (and
        // therefore to `stopRecording`). `to` is nil until the
        // close-await returns and `startLiveCaptionProvider` runs;
        // stop-then-start ordering is preserved.
        liveCaptionState = .transitioning(
            from: oldProvider,
            to: nil,
            transitionTask: newTask,
            generation: myGeneration
        )
    }

    /// Body of the detached Task spawned by `restartLiveCaptions`.
    /// Extracted so unit tests can pin the generation-guard behavior
    /// by injecting stubbed `stop` / `start` closures. Both
    /// production and tests share the same control flow — they only
    /// differ in what `await stop(...)` and `start(...)` actually do.
    private func performRestartLiveCaptionsBody(
        oldProvider: LiveCaptionProvider?,
        localeIdentifier: String,
        generation: UInt64
    ) async {
#if DEBUG
        if let stopOverride = liveCaptionRestartStopOverrideForTesting,
           let startOverride = liveCaptionRestartStartOverrideForTesting {
            await stopOverride(oldProvider)
            // Generation guard: if a newer restart bumped the token
            // while we were suspended in the `stop` await, decline to
            // call `start`. The newer restart's provider has already
            // been installed (or is about to be) and our `start`
            // would stomp it — exactly the race that produced the
            // overlapping `POST /sessions` signature in production.
            guard restartGeneration == generation else { return }
            // Phase 2 — also bail if a concurrent `stopRecording` /
            // `finalizeLiveCaptionsForStop` has advanced the
            // lifecycle past `.transitioning`. The generation token
            // alone doesn't cover this case (stop doesn't bump it).
            guard isCurrentLiveCaptionTransition(generation: generation) else { return }
            startOverride(localeIdentifier)
            return
        }
#endif
        await stopLiveCaptionsAwaitingClose(oldProvider, saveTo: nil)
        // Generation guard: see DEBUG branch above. Same rule, same
        // reason — a newer restart supersedes this Task's `start`.
        guard restartGeneration == generation else { return }
        // Same stop-supersede guard as the DEBUG branch.
        guard isCurrentLiveCaptionTransition(generation: generation) else { return }
        guard state == .recording, let systemOutput else { return }
        startLiveCaptionProvider(for: systemOutput, localeIdentifier: localeIdentifier)
    }

    /// Phase 2 — returns true when `liveCaptionState` is still
    /// `.transitioning(generation: <generation>)`. Used by
    /// `performRestartLiveCaptionsBody` to short-circuit the start
    /// hook when a concurrent stop has moved the lifecycle to
    /// `.stopping` or `.none` after the close-await began.
    private func isCurrentLiveCaptionTransition(generation: UInt64) -> Bool {
        if case .transitioning(_, _, _, let g) = liveCaptionState {
            return g == generation
        }
        return false
    }

    private func startLiveCaptions(for systemOutput: SystemAudioOutput) async {
        guard !RecappiPerformanceDebugOptions.disableBackendLiveCaptions() else {
            DiagnosticsLog.warning(
                "live-caption",
                "provider.disabled reason=performance_debug flag=\(RecappiPerformanceDebugOptions.disableBackendLiveCaptionsEnvKey)"
            )
            liveCaptionMessage = nil
            liveCaptionStatusPhase = nil
            liveCaptionIsFinal = false
            return
        }
        guard #available(macOS 26.0, *) else {
            DiagnosticsLog.warning("live-caption", "provider.unavailable reason=macos_version")
            liveCaptionMessage = "Live captions require macOS 26."
            return
        }

        startLiveCaptionProvider(
            for: systemOutput,
            localeIdentifier: AppConfig.shared.normalizedCloudLanguage
        )
    }

    private func startLiveCaptionProvider(
        for systemOutput: SystemAudioOutput,
        localeIdentifier: String
    ) {
        guard let bearerToken = AuthSessionStore.shared.bearerToken() else {
            DiagnosticsLog.warning("live-caption", "provider.unavailable reason=missing_bearer_token")
            liveCaptionMessage = "Sign in to Recappi Cloud to use live captions."
            liveCaptionStatusPhase = .unavailable
            liveCaptionIsFinal = false
            return
        }

        let client = RecappiAPIClient(
            origin: AppConfig.shared.effectiveBackendBaseURL,
            bearerToken: bearerToken
        )
        // Bilingual toggle picks the OpenAI translation session
        // (`includeSourceTranscript=true` so we still get the source row);
        // otherwise we mint the standard transcription session. The actor
        // multiplexes both shapes so the rest of the pipeline doesn't care.
        let lockedConfig = activeLiveCaptionConfiguration ?? liveCaptionRecordingConfiguration()
        let mode: RealtimeLiveCaptionMode = lockedConfig.showsTranslation
            ? .translation(
                targetLanguage: Self.normalizedRealtimeTranslationTargetLanguage(
                    lockedConfig.targetLanguage
                )
            )
            : .transcription
        let contextHint = mode.isTranslation ? nil : RecordingContextPrompt.liveCaptionHint(
            sceneRaw: AppConfig.shared.recordingSceneTemplate,
            extraPrompt: AppConfig.shared.recordingExtraPrompt
        )
        DiagnosticsLog.event(
            "live-caption",
            "provider.start backend=true mode=\(Self.liveCaptionModeLabel(mode)) language=\(Self.normalizedRealtimeLanguage(localeIdentifier)) target=\(lockedConfig.targetLanguage) contextHintChars=\(contextHint?.count ?? 0)"
        )
        // Hand the hint to the actor so it can emit the legacy
        // `conversation.item.create` system-message event on `session.created`.
        // Translation mode strips the hint at the actor's init time.
        let connector = LiveRealtimeSessionConnector(client: client)
        let backendActor = RealtimeLiveCaptionActor(
            connector: connector,
            language: Self.normalizedRealtimeLanguage(localeIdentifier),
            mode: mode,
            contextHint: contextHint
        )
        installBackendLiveCaptionActor(
            backendActor,
            for: systemOutput,
            localeIdentifier: localeIdentifier
        )
    }

    /// Install a freshly-constructed backend actor as the active live-
    /// caption provider: wire audio routing into the actor, spawn the
    /// snapshot-subscription Task, transition the state to
    /// `.running(.backend(...))`, and kick off the actor's `start()`.
    /// Extracted so the UI-test path (which constructs the actor with
    /// a different `RecappiAPIClient`) can share the same wiring.
    private func installBackendLiveCaptionActor(
        _ backendActor: RealtimeLiveCaptionActor,
        for systemOutput: SystemAudioOutput,
        localeIdentifier: String
    ) {
        // Phase 3d — promote the lifecycle to `.running`. Any
        // outgoing `.transitioning` state for the same generation
        // is replaced here. A LATER restart that bumped the
        // generation has already moved the state forward; the
        // generation-guard in `performRestartLiveCaptionsBody`
        // prevented us from being called in that case.
        liveCaptionState = .running(
            provider: .backend(backendActor),
            locale: localeIdentifier,
            generation: restartGeneration
        )

        // Audio: the system output hands us sample buffers on a
        // background queue. The actor's nonisolated `append(sampleBuffer:)`
        // does the PCM16 conversion off-actor and hops onto the actor
        // to enqueue the encoded frame, so we can plug it in directly.
        systemOutput.onLiveCaptionSampleBuffer = { [weak backendActor] sampleBuffer in
            backendActor?.append(sampleBuffer: sampleBuffer)
        }

        // Snapshot subscription: every `LiveCaptionSnapshot` the actor
        // publishes flows into `applyLiveCaptionSnapshot(_:)` on the
        // MainActor, same shape as the legacy callback.
        liveCaptionSnapshotTask?.cancel()
        let snapshots = Task { @MainActor [weak self] in
            for await snapshot in await backendActor.captionSnapshots() {
                guard !Task.isCancelled else { return }
                self?.applyLiveCaptionSnapshot(snapshot)
            }
        }
        liveCaptionSnapshotTask = snapshots

        Task { [weak backendActor] in
            await backendActor?.start()
        }
    }

    private static func normalizedRealtimeLanguage(_ localeIdentifier: String) -> String {
        let trimmed = localeIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if let base = trimmed.split(separator: "-").first, !base.isEmpty {
            return String(base)
        }
        return "en"
    }

    private static func normalizedRealtimeTranslationTargetLanguage(_ language: String) -> String {
        LiveCaptionTranslationTargetLanguageOption.normalizedCode(language)
    }

    private static func liveCaptionModeLabel(_ mode: RealtimeLiveCaptionMode) -> String {
        switch mode {
        case .transcription:
            return "transcription"
        case .translation:
            return "translation"
        }
    }

    var canReconnectLiveCaptions: Bool {
        if case .running(.backend, _, _) = liveCaptionState { return true }
        return uiTestMode.isEnabled && state == .recording
    }

    func reconnectLiveCaptionsNow() {
        if case .running(.backend(let backendActor), _, _) = liveCaptionState {
            DiagnosticsLog.event("live-caption", "reconnect.manual")
            Task { await backendActor.reconnectNow() }
            return
        }
        guard uiTestMode.isEnabled else {
            DiagnosticsLog.warning("live-caption", "reconnect.ignored reason=unsupported_provider")
            return
        }
        DiagnosticsLog.event("live-caption", "reconnect.manual.ui_test")
        liveCaptionMessage = "正在重新连接字幕服务"
        liveCaptionStatusPhase = .failed
    }

    private nonisolated static func fileSummary(_ url: URL?) -> String {
        guard let url else { return "none" }
        let size = (try? FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? NSNumber)?
            .int64Value ?? -1
        return "\(url.lastPathComponent):\(size)"
    }

    private nonisolated static func captureHealthSnapshots(
        systemOutput: SystemAudioOutput?,
        micOutput: MicAudioOutput?
    ) -> [CaptureAudioHealth] {
        let now = ProcessInfo.processInfo.systemUptime
        return [
            systemOutput?.healthSnapshot(now: now),
            micOutput?.healthSnapshot(now: now),
        ].compactMap { $0 }
    }

    private nonisolated static func captureHealthSummary(_ health: [CaptureAudioHealth]) -> String {
        guard !health.isEmpty else {
            return "capture.health none"
        }
        let details = health.map { item in
            var parts = ["\(item.source)Buffers=\(item.bufferCount)"]
            if let includedBufferCount = item.includedBufferCount {
                parts.append("\(item.source)Included=\(includedBufferCount)")
            }
            if let secondsSinceLastBuffer = item.secondsSinceLastBuffer {
                parts.append("\(item.source)LastAgo=\(String(format: "%.2f", secondsSinceLastBuffer))s")
            } else {
                parts.append("\(item.source)LastAgo=never")
            }
            parts.append("\(item.source)MeterFrames=\(item.meterFrameCount)")
            if let averagePeak = item.averagePeak {
                parts.append("\(item.source)AvgPeak=\(String(format: "%.4f", averagePeak))")
            } else {
                parts.append("\(item.source)AvgPeak=never")
            }
            if let maxPeak = item.maxPeak {
                parts.append("\(item.source)MaxPeak=\(String(format: "%.4f", maxPeak))")
            }
            return parts.joined(separator: " ")
        }
        return "capture.health \(details.joined(separator: " "))"
    }

    nonisolated static func shouldKeepRawCaptureSources(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        if let raw = environment[keepRawCaptureSourcesEnvKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !raw.isEmpty
        {
            return ["1", "true", "yes", "on"].contains(raw)
        }
        return userDefaults.bool(forKey: keepRawCaptureSourcesDefaultKey)
    }

    private func liveCaptionRecordingConfiguration() -> LiveCaptionRecordingConfiguration {
        LiveCaptionRecordingConfiguration(
            showsTranslation: AppConfig.shared.liveCaptionsBilingualEnabled,
            targetLanguage: Self.normalizedRealtimeTranslationTargetLanguage(
                AppConfig.shared.liveCaptionsTranslationTargetLanguage
            )
        )
    }

    private func stopLiveCaptions(saveTo sessionDir: URL?) {
        stopLiveCaptions(liveCaptionState.activeProvider, saveTo: sessionDir)
    }

    /// Fire-and-forget stop. Detaches into a Task so non-async call
    /// sites (state transitions, error cleanup) can keep their current
    /// signatures. `restartLiveCaptions` uses the async variant below
    /// when it needs to serialize against the next claim POST.
    private func stopLiveCaptions(_ provider: LiveCaptionProvider?, saveTo sessionDir: URL?) {
        guard let provider else { return }
        DiagnosticsLog.event(
            "live-caption",
            "provider.stop saveDir=\(sessionDir?.lastPathComponent ?? "none")"
        )
        switch provider {
        case .backend(let backendActor):
            Task { _ = await backendActor.stop(saveTo: sessionDir) }
#if DEBUG
        case .testSentinel:
            // Sentinels have no real I/O. Tests inject behaviour through
            // `liveCaptionRestartStopOverrideForTesting`; the legacy
            // fire-and-forget path is unreachable in those tests.
            break
#endif
        }
    }

    /// Stop the live captions and await the WebSocket close handshake
    /// before returning. `restartLiveCaptions` chains the next session
    /// claim after this so the server never sees two near-simultaneous
    /// claim POSTs for the same userKey.
    private func stopLiveCaptionsAwaitingClose(_ provider: LiveCaptionProvider?, saveTo sessionDir: URL?) async {
        guard let provider else { return }
        DiagnosticsLog.event(
            "live-caption",
            "provider.stop.await_close saveDir=\(sessionDir?.lastPathComponent ?? "none")"
        )
        switch provider {
        case .backend(let backendActor):
            _ = await backendActor.stop(saveTo: sessionDir)
#if DEBUG
        case .testSentinel:
            // Sentinels short-circuit via the test override hook; the
            // production path here is unreachable in tests.
            break
#endif
        }
    }

    // MARK: - Phase 2: caption persistence

    /// Phase 2 — snapshot a provider's `[LiveCaptionEntry]`
    /// accumulator without mutating its WebSocket state. The DEBUG
    /// test seam routes through `liveCaptionDrainOverrideForTesting`
    /// so unit tests can drive the carryover path without standing up
    /// real I/O. Production now dispatches to the backend actor's
    /// `drainEntriesNonblocking()` mirror.
    private func drainEntriesUsingHooks(from provider: LiveCaptionProvider?) -> [LiveCaptionEntry] {
#if DEBUG
        if let drainOverride = liveCaptionDrainOverrideForTesting {
            return drainOverride(provider)
        }
#endif
        guard let provider else { return [] }
        switch provider {
        case .backend(let backendActor):
            // Pull the latest entries snapshot from the actor's
            // nonisolated lock-guarded mirror. The mirror is updated on
            // every transcript-state mutation (see
            // `RealtimeLiveCaptionActor.updateDrainMirror`), so a
            // synchronous read here costs an `NSLock` acquisition rather
            // than a hop across actor isolation. The previous
            // implementation used a `DispatchSemaphore` to bridge from
            // MainActor into the actor; that approach risked starving
            // the cooperative thread pool when the actor's executor
            // queue had pending audio-frame Tasks ahead of the drain.
            return backendActor.drainEntriesNonblocking()
#if DEBUG
        case .testSentinel:
            // The drain hook above intercepts sentinel-bearing test
            // states. Reaching this case without a hook means a test
            // installed a sentinel but forgot to install a drain hook
            // — that's a test wiring bug; report it as empty.
            return []
#endif
        }
    }

    /// Phase 2 — central "stop the live captions and flush carryover"
    /// entry point. Replaces the previous direct call to
    /// `stopLiveCaptionsAwaitingClose(_:saveTo:)` from `stopRecording`,
    /// routing the active / transitioning provider's entries
    /// through `liveCaptionStore` so caption history is preserved
    /// across the restart-then-stop window (Codex Finding #2).
    private func finalizeLiveCaptionsForStop(saveTo sessionDir: URL?) async {
        let snapshot = liveCaptionState
        // Switch to `.stopping` so concurrent restart Tasks observe
        // the lifecycle has advanced and decline to install a new
        // provider after their `start` hook runs.
        switch snapshot {
        case .none:
            liveCaptionState = .stopping(provider: nil)
        case .running(let p, _, _):
            liveCaptionState = .stopping(provider: p)
        case .transitioning(_, let to, _, _):
            liveCaptionState = .stopping(provider: to)
        case .stopping:
            break
        }

        switch snapshot {
        case .none:
            break
        case .running(let provider, _, _):
            let entries = drainEntriesUsingHooks(from: provider)
            if !entries.isEmpty {
                liveCaptionStore.add(entries)
            }
            await stopLiveCaptionsAwaitingCloseUsingHooks(provider)
        case .transitioning(_, let to, let transitionTask, _):
            // The `from`-side entries were snapshotted into
            // `liveCaptionStore` synchronously inside
            // `restartLiveCaptions(...)` before the transition Task
            // was spawned. Cancel the Task so it can't promote the
            // lifecycle to `.running(to, ...)` underneath us; then
            // drain whatever the (possibly nil) `to` provider has
            // accumulated and close it.
            transitionTask.cancel()
            if let to {
                let entries = drainEntriesUsingHooks(from: to)
                if !entries.isEmpty {
                    liveCaptionStore.add(entries)
                }
                await stopLiveCaptionsAwaitingCloseUsingHooks(to)
            }
        case .stopping(let provider):
            // A concurrent stop already started; wait for its close,
            // then flush.
            if let provider {
                await stopLiveCaptionsAwaitingCloseUsingHooks(provider)
            }
        }

        liveCaptionSnapshotTask?.cancel()
        liveCaptionSnapshotTask = nil
        liveCaptionState = .none

        if let sessionDir {
            do {
                try await liveCaptionStore.flush(to: sessionDir)
            } catch {
                DiagnosticsLog.error(
                    "live-caption",
                    "store.flush.failed \(DiagnosticsLog.errorSummary(error))"
                )
            }
        }
    }

    /// Phase 2 — wraps `stopLiveCaptionsAwaitingClose` and the DEBUG
    /// test override so the stop-finalize and restart paths share one
    /// dispatch point.
    private func stopLiveCaptionsAwaitingCloseUsingHooks(_ provider: LiveCaptionProvider?) async {
#if DEBUG
        if let stopOverride = liveCaptionRestartStopOverrideForTesting {
            await stopOverride(provider)
            return
        }
#endif
        await stopLiveCaptionsAwaitingClose(provider, saveTo: nil)
    }

    // MARK: - Permissions

    private func requestMicrophoneAccessIfNeeded() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            DiagnosticsLog.event("permissions", "microphone.status authorized")
            return
        case .notDetermined:
            DiagnosticsLog.event("permissions", "microphone.request.start")
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            DiagnosticsLog.event("permissions", "microphone.request.result granted=\(granted)")
            if !granted { throw RecorderError.micDenied }
        case .denied, .restricted:
            DiagnosticsLog.warning("permissions", "microphone.status denied_or_restricted")
            throw RecorderError.micDenied
        @unknown default:
            DiagnosticsLog.warning("permissions", "microphone.status unknown")
            throw RecorderError.micDenied
        }
    }

    func requestAutoStopForDetectedMeetingIfNeeded() {
        guard state == .recording, let context = detectedMeetingRecordingContext else { return }
        detectedMeetingRecordingContext = nil
        autoStopRequest = AutoStopRecordingRequest(context: context)
    }

    func clearAutoStopRequest() {
        autoStopRequest = nil
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
        RecordingStore.stampAccount(AuthSessionStore.currentLocalSessionAccount(), in: sessionDir)
        self.sessionDir = sessionDir
        self.lastSessionDir = nil
        self.audioLevel = 0
        self.audioSpectrumLevels = Array(repeating: 0, count: Self.spectrumBucketCount)
        self.audioLevelHistory = Array(repeating: 0, count: Self.spectrumBucketCount)
        seedStateBoardMeterIfNeeded()
        self.lastLevelPublish = 0
        self.lastHistoryPublish = 0
        self.pendingMeterPeak = 0
        self.pendingMeterBands = Array(repeating: 0, count: Self.spectrumBucketCount)
        self.liveCaptionSegments = []
        self.liveCaptionCarryoverSegments = []
        self.liveCaptionMessage = nil
        self.liveCaptionStatusPhase = nil
        let simulatedTranslation = uiTestMode.simulatedLiveCaptionTranslationText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if simulatedTranslation?.isEmpty == false {
            self.activeLiveCaptionConfiguration = LiveCaptionRecordingConfiguration(
                showsTranslation: true,
                targetLanguage: Self.normalizedRealtimeTranslationTargetLanguage(
                    AppConfig.shared.liveCaptionsTranslationTargetLanguage
                )
            )
        } else if uiTestMode.simulatedLiveCaptionText?.isEmpty == false {
            // A monolingual UI fixture should stay monolingual regardless of
            // the developer machine's persisted Options popover defaults.
            // Tests that need the bilingual layout pass an explicit simulated
            // translation fixture above.
            self.activeLiveCaptionConfiguration = LiveCaptionRecordingConfiguration(
                showsTranslation: false,
                targetLanguage: Self.normalizedRealtimeTranslationTargetLanguage(
                    AppConfig.shared.liveCaptionsTranslationTargetLanguage
                )
            )
        } else {
            self.activeLiveCaptionConfiguration = liveCaptionRecordingConfiguration()
        }
        self.liveCaptionIsFinal = false
        let simulatedSource = uiTestMode.simulatedLiveCaptionText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if simulatedSource?.isEmpty == false || simulatedTranslation?.isEmpty == false {
            // UI tests inject fixture text; surface it as one simulated
            // segment so consumers exercise the segment-aware code path.
            self.liveCaptionSegments = [
                LiveCaptionSegment(
                    id: "ui-test-fixture",
                    sourceText: simulatedSource ?? "",
                    translatedText: simulatedTranslation?.isEmpty == false ? simulatedTranslation : nil,
                    isFinal: false,
                    sequence: 0
                )
            ]
            self.liveCaptionIsFinal = false
        }
        if let simulatedError = uiTestMode.simulatedLiveCaptionErrorMessage,
           !simulatedError.isEmpty {
            liveCaptionMessage = simulatedError
            liveCaptionStatusPhase = .failed
            liveCaptionIsFinal = false
        }
        if uiTestMode.useBackendRealtimeLiveCaptions {
            startBackendRealtimeLiveCaptionsForUITest()
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

    private func seedStateBoardMeterIfNeeded() {
        guard uiTestMode.stateBoardVisualFixtureEnabled else { return }
        let count = Self.spectrumBucketCount
        let denominator = Double(max(count - 1, 1))
        audioSpectrumLevels = (0..<count).map { index in
            let phase = Double(index) / denominator
            let wave = (sin(Double(index) * 0.52) + 1) / 2
            let envelope = 0.30 + 0.70 * (1 - abs(phase - 0.48))
            return Float(0.08 + 0.84 * wave * envelope)
        }
        audioLevelHistory = (0..<count).map { index in
            let phase = Double(index) / denominator
            let wave = (sin(phase * Double.pi * 3.2 - Double.pi / 3) + 1) / 2
            return Float(0.12 + 0.76 * wave)
        }
    }

    private func startBackendRealtimeLiveCaptionsForUITest() {
        guard let bearerToken = AuthSessionStore.shared.bearerToken() ?? uiTestMode.authToken,
              !bearerToken.isEmpty else {
            DiagnosticsLog.warning("live-caption", "provider.unavailable.ui_test reason=missing_bearer_token")
            liveCaptionMessage = "Sign in to Recappi Cloud to use backend live captions."
            liveCaptionStatusPhase = .unavailable
            liveCaptionIsFinal = false
            return
        }

        DiagnosticsLog.event("live-caption", "provider.start.ui_test backend=true mode=transcription")
        let client = RecappiAPIClient(
            origin: AppConfig.shared.effectiveBackendBaseURL,
            bearerToken: bearerToken
        )
        let connector = LiveRealtimeSessionConnector(client: client)
        let backendActor = RealtimeLiveCaptionActor(
            connector: connector,
            language: Self.normalizedRealtimeLanguage(AppConfig.shared.normalizedCloudLanguage),
            mode: .transcription
        )
        // UI tests do not exercise the system audio path, so the
        // sample-buffer wiring is skipped here — but the snapshot
        // subscription still bridges the actor's published phases
        // into the panel so the UI surfaces preparing → listening.
        liveCaptionState = .running(
            provider: .backend(backendActor),
            locale: AppConfig.shared.normalizedCloudLanguage,
            generation: restartGeneration
        )
        liveCaptionSnapshotTask?.cancel()
        let snapshots = Task { @MainActor [weak self] in
            for await snapshot in await backendActor.captionSnapshots() {
                guard !Task.isCancelled else { return }
                self?.applyLiveCaptionSnapshot(snapshot)
            }
        }
        liveCaptionSnapshotTask = snapshots
        Task { [backendActor] in
            await backendActor.start()
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
            sourceBundleID: bundleID,
            sceneTemplate: AppConfig.shared.recordingSceneTemplate,
            extraPrompt: Self.trimmedPrompt(AppConfig.shared.recordingExtraPrompt),
            includesMicrophoneAudio: includesMicrophoneAudio
        )
    }

    private static func trimmedPrompt(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func detectedMeetingContextForNextRecording() -> DetectedMeetingRecordingContext? {
        if let pendingDetectedMeetingRecordingContext {
            return pendingDetectedMeetingRecordingContext
        }
        guard let prompt = meetingPrompt else { return nil }
        return DetectedMeetingRecordingContext(
            appID: prompt.appID,
            appName: prompt.appName,
            promptTitle: prompt.promptTitle,
            browserSessionKey: prompt.browserSessionKey
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
        // Recappi only consumes the `.audio` output from this SCStream.
        // Keep the video side tiny so ScreenCaptureKit does not maintain a
        // default 1920x1080 / 60fps surface while recording audio.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 1
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
        startMonitoringMicrophoneDeviceConnections()
    }

    private func stopMonitoringOutputDeviceChanges() {
        audioDeviceMonitor?.stop()
        audioDeviceMonitor = nil
        stopMonitoringMicrophoneDeviceConnections()
    }

    private func startMonitoringMicrophoneDeviceConnections() {
        stopMonitoringMicrophoneDeviceConnections()

        let center = NotificationCenter.default
        let connected = center.addObserver(
            forName: AVCaptureDevice.wasConnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconfigureMicrophoneForConfiguredInput()
            }
        }

        let disconnected = center.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reconfigureMicrophoneForConfiguredInput()
            }
        }

        microphoneDeviceNotificationTokens = [connected, disconnected]
    }

    private func stopMonitoringMicrophoneDeviceConnections() {
        guard !microphoneDeviceNotificationTokens.isEmpty else { return }
        let center = NotificationCenter.default
        microphoneDeviceNotificationTokens.forEach { center.removeObserver($0) }
        microphoneDeviceNotificationTokens = []
    }

    private func handleAudioDeviceChange(_ change: DefaultAudioDeviceMonitor.Change) async {
        switch change {
        case .output(let deviceID):
            await handleOutputDeviceChange(deviceID)
        case .input:
            reconfigureMicrophoneForConfiguredInput()
        }
    }

    private func handleOutputDeviceChange(_ deviceID: AudioDeviceID) async {
        guard state == .recording else { return }
        guard currentOutputAudioDeviceID != deviceID else { return }
        guard SystemAudioCaptureBackend.current == .screenCaptureKit else {
            currentOutputAudioDeviceID = deviceID
            return
        }
        guard let stream else {
            currentOutputAudioDeviceID = deviceID
            return
        }

        currentOutputAudioDeviceID = deviceID

        do {
            try await stream.updateConfiguration(makeSystemAudioConfiguration())
        } catch {
            DiagnosticsLog.error(
                "recording",
                "screen_capture.output_reconfigure.failed outputDevice=\(deviceID) \(DiagnosticsLog.errorSummary(error))"
            )
        }
    }

    private var microphoneSelectionLogValue: String {
        let selected = AppConfig.shared.recordingMicrophoneDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.microphoneSelectionLogValue(for: selected)
    }

    private func preferredMicrophoneDevice() -> AVCaptureDevice? {
        let selected = AppConfig.shared.recordingMicrophoneDeviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.preferredMicrophoneDevice(
            selectedID: selected,
            selectionLogValue: Self.microphoneSelectionLogValue(for: selected)
        )
    }

    nonisolated private static func microphoneSelectionLogValue(for selectedID: String) -> String {
        let selected = selectedID.trimmingCharacters(in: .whitespacesAndNewlines)
        return selected.isEmpty ? "system-default" : "configured:\(selected.hashValue)"
    }

    nonisolated private static func preferredMicrophoneDevice(
        selectedID: String,
        selectionLogValue: String
    ) -> AVCaptureDevice? {
        let selected = selectedID.trimmingCharacters(in: .whitespacesAndNewlines)
        let device = MicrophoneInputDevice.captureDevice(preferredUniqueID: selected)

        if !selected.isEmpty, device?.uniqueID != selected {
            DiagnosticsLog.warning(
                "recording",
                "microphone.selected_unavailable selection=\(selectionLogValue) fallback=\(DiagnosticsLog.sanitize(device?.localizedName ?? "none", maxLength: 80))"
            )
        }

        return device
    }

    private func reconfigureMicrophoneForConfiguredInput() {
        guard state == .recording else { return }
        guard let micSession else { return }
        guard let newDevice = preferredMicrophoneDevice() else { return }

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
                DiagnosticsLog.event(
                    "recording",
                    "microphone.input_reconfigured name=\(DiagnosticsLog.sanitize(newDevice.localizedName, maxLength: 80)) selection=\(microphoneSelectionLogValue)"
                )
                return
            }

            for oldInput in existingInputs where micSession.canAddInput(oldInput) {
                micSession.addInput(oldInput)
            }
            micSession.commitConfiguration()
            DiagnosticsLog.error(
                "recording",
                "microphone.input_reconfigure.rejected deviceHash=\(newDevice.uniqueID.hashValue)"
            )
        } catch {
            DiagnosticsLog.error(
                "recording",
                "microphone.input_reconfigure.failed deviceHash=\(newDevice.uniqueID.hashValue) \(DiagnosticsLog.errorSummary(error))"
            )
        }
    }
}
