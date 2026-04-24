import Accelerate
import AVFoundation
import AppKit
import CoreAudio
import CoreMedia
@preconcurrency import ScreenCaptureKit

struct AudioApp: Identifiable, Hashable {
    enum Bucket: Int, Sendable, Comparable {
        case meeting = 0
        case browser = 1
        case other = 2
        static func < (lhs: Bucket, rhs: Bucket) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let id: String  // bundle ID
    let name: String
    let icon: NSImage?
    let scApp: SCRunningApplication?
    let bucket: Bucket
    /// True when AudioActivityMonitor sees this bundle currently producing
    /// output audio. Active apps float to the top of the picker.
    var isActive: Bool

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: AudioApp, rhs: AudioApp) -> Bool {
        lhs.id == rhs.id
    }
}

struct RecordingSuggestion: Equatable, Sendable {
    let appID: String
    let appName: String
    let promptTitle: String
}

struct MeetingPrompt: Equatable, Sendable {
    let appID: String
    let appName: String
    let promptTitle: String
}

struct DetectedMeetingRecordingContext: Equatable, Sendable {
    let appID: String
    let appName: String
    let promptTitle: String
}

struct AutoStopRecordingRequest: Equatable, Identifiable, Sendable {
    let id = UUID()
    let context: DetectedMeetingRecordingContext
}

/// Bundle-ID whitelists for smart sorting. Helpers / renderers are filtered
/// out at the refresh step, so we classify by the user-visible parent bundle.
private enum AudioAppCategories {
    static let meetingBundles: Set<String> = [
        "us.zoom.xos",
        "us.zoom.Zoom",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.tinyspeck.slackmacgap",         // Slack (huddles)
        "com.hnc.Discord",
        "com.cisco.webexmeetingsapp",
        "com.cisco.webexmeetingsapp.WebexApp",
        "com.apple.FaceTime",
        "com.loom.desktop",
    ]

    static let browserBundles: Set<String> = [
        "com.apple.Safari",
        "com.google.Chrome",
        "com.google.Chrome.canary",
        "com.google.Chrome.beta",
        "com.brave.Browser",
        "org.mozilla.firefox",
        "org.mozilla.firefoxdeveloperedition",
        "company.thebrowser.Browser",        // Arc
        "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    static func bucket(for bundleID: String) -> AudioApp.Bucket {
        let canonical = BundleCollapser.parent(of: bundleID)
        if meetingBundles.contains(canonical) { return .meeting }
        if browserBundles.contains(canonical) { return .browser }
        return .other
    }
}

/// Collapses child bundle IDs onto their parent. Chrome-style multi-process
/// apps emit audio from `.helper(.Renderer)` / `.Agent` subprocesses; the
/// user recognises the app by its parent bundle, so both the selector and
/// the activity monitor need the same canonicalisation.
enum BundleCollapser {
    private static let markers: [String] = [
        ".helper", ".Helper",
        ".renderer", ".Renderer",
        ".agent", ".Agent",
        ".plugin_host",
    ]

    private static let canonicalBundleIDsByLowercase: [String: String] = [
        "com.apple.safari": "com.apple.Safari",
        "com.google.chrome": "com.google.Chrome",
        "com.google.chrome.beta": "com.google.Chrome.beta",
        "com.google.chrome.canary": "com.google.Chrome.canary",
        "com.brave.browser": "com.brave.Browser",
        "company.thebrowser.browser": "company.thebrowser.Browser",
        "company.thebrowser.arc": "company.thebrowser.Browser",
        "com.microsoft.edgemac": "com.microsoft.edgemac",
        "com.vivaldi.vivaldi": "com.vivaldi.Vivaldi",
        "com.operasoftware.opera": "com.operasoftware.Opera",
    ]

    static func parent(of bundleID: String) -> String {
        let stripped: String
        if let range = markers
            .compactMap({ bundleID.range(of: $0, options: [.caseInsensitive]) })
            .min(by: { $0.lowerBound < $1.lowerBound }) {
            stripped = String(bundleID[..<range.lowerBound])
        } else {
            stripped = bundleID
        }

        return canonicalBundleID(stripped)
    }

    static func matches(_ bundleID: String, selected selectedBundleID: String) -> Bool {
        let candidateParent = parent(of: bundleID)
        let selectedParent = parent(of: selectedBundleID)
        if candidateParent == selectedParent { return true }

        let candidate = bundleID.lowercased()
        let selected = selectedParent.lowercased()
        return candidate == selected || candidate.hasPrefix("\(selected).")
    }

    private static func canonicalBundleID(_ bundleID: String) -> String {
        canonicalBundleIDsByLowercase[bundleID.lowercased()] ?? bundleID
    }

    static func canonicalBrowserBundleID(for appName: String) -> String? {
        let normalized = appName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalized {
        case "arc", "arc browser":
            return "company.thebrowser.Browser"
        case "google chrome", "chrome":
            return "com.google.Chrome"
        case "safari":
            return "com.apple.Safari"
        case "brave browser", "brave":
            return "com.brave.Browser"
        case "microsoft edge", "edge":
            return "com.microsoft.edgemac"
        case "vivaldi":
            return "com.vivaldi.Vivaldi"
        case "opera":
            return "com.operasoftware.Opera"
        default:
            return nil
        }
    }

    static func browserDisplayName(for bundleID: String, fallback: String) -> String {
        switch parent(of: bundleID) {
        case "company.thebrowser.Browser":
            return "Arc"
        case "com.google.Chrome":
            return "Google Chrome"
        case "com.apple.Safari":
            return "Safari"
        default:
            if let canonical = canonicalBrowserBundleID(for: fallback) {
                switch canonical {
                case "company.thebrowser.Browser": return "Arc"
                case "com.google.Chrome": return "Google Chrome"
                case "com.apple.Safari": return "Safari"
                default: break
                }
            }
            return fallback
        }
    }
}

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
            detectedMeetingRecordingContext = nil
            stopMonitoringOutputDeviceChanges()
            self.stream = nil
            self.systemOutput = nil
            self.micSession = nil
            self.micOutput = nil
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

        // Stop system audio stream
        let systemOutput = self.systemOutput
        try await stream?.stopCapture()
        stream = nil
        self.systemOutput = nil
        let finishedSystemURL = try await systemOutput?.finishWriting()

        // Stop microphone capture
        let micOutput = self.micOutput
        micSession?.stopRunning()
        micSession = nil
        self.micOutput = nil
        let finishedMicURL = try await micOutput?.finishWriting()

        guard let sessionDir = self.sessionDir else {
            throw RecorderError.noSessionDir
        }
        self.lastSessionDir = sessionDir

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
        sessionDir = nil
        lastSessionDir = nil
        recordingSuggestion = nil
        meetingPrompt = nil
        stream = nil
        systemOutput = nil
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

// MARK: - Audio level extraction

struct AudioMeterFrame: Sendable {
    let peak: Float
    let bands: [Float]
}

enum AudioSpectrumConfiguration {
    static let bucketCount = 40
}

/// Peak amplitude + frequency buckets of a PCM `CMSampleBuffer`,
/// normalised to 0…1. Handles the two formats ScreenCaptureKit +
/// AVCaptureSession actually deliver on current macOS: 32-bit float
/// interleaved (SCStream default) and 16-bit signed integer
/// (AVCaptureSession microphones).
enum AudioLevelExtractor {
    /// Test-only hook so spectrum bucket tuning can be validated with
    /// deterministic synthetic signals.
    static func analyzeSamplesForTesting(
        _ samples: [Float],
        sampleRate: Double,
        bucketCount: Int = AudioSpectrumConfiguration.bucketCount
    ) -> [Float] {
        analyze(samples: samples, sampleRate: sampleRate, bucketCount: bucketCount).bands
    }

    static func meterFrame(
        _ sampleBuffer: CMSampleBuffer,
        bucketCount: Int = AudioSpectrumConfiguration.bucketCount
    ) -> AudioMeterFrame {
        guard
            let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
            let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
            let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else {
            return AudioMeterFrame(peak: 0, bands: Array(repeating: 0, count: bucketCount))
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let raw = dataPointer else {
            return AudioMeterFrame(peak: 0, bands: Array(repeating: 0, count: bucketCount))
        }

        let asbd = asbdPtr.pointee
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let channels = max(Int(asbd.mChannelsPerFrame), 1)

        if isFloat, asbd.mBitsPerChannel == 32 {
            let count = totalLength / MemoryLayout<Float>.size
            return raw.withMemoryRebound(to: Float.self, capacity: count) { ptr in
                let mono = collapseToMono(frameCount: count / channels, channels: channels) { frame, channel in
                    ptr[(frame * channels) + channel]
                }
                return analyze(samples: mono, sampleRate: Double(asbd.mSampleRate), bucketCount: bucketCount)
            }
        }

        if asbd.mBitsPerChannel == 16 {
            let count = totalLength / MemoryLayout<Int16>.size
            return raw.withMemoryRebound(to: Int16.self, capacity: count) { ptr in
                let mono = collapseToMono(frameCount: count / channels, channels: channels) { frame, channel in
                    Float(ptr[(frame * channels) + channel]) / 32768
                }
                return analyze(samples: mono, sampleRate: Double(asbd.mSampleRate), bucketCount: bucketCount)
            }
        }

        return AudioMeterFrame(peak: 0, bands: Array(repeating: 0, count: bucketCount))
    }

    private static func collapseToMono(
        frameCount: Int,
        channels: Int,
        sampleAt: (_ frame: Int, _ channel: Int) -> Float
    ) -> [Float] {
        guard frameCount > 0 else { return [] }
        return (0..<frameCount).map { frame in
            var sum: Float = 0
            for channel in 0..<channels {
                sum += sampleAt(frame, channel)
            }
            return sum / Float(channels)
        }
    }

    private static func analyze(samples: [Float], sampleRate: Double, bucketCount: Int) -> AudioMeterFrame {
        guard !samples.isEmpty else {
            return AudioMeterFrame(peak: 0, bands: Array(repeating: 0, count: bucketCount))
        }

        var peak: Float = 0
        for sample in samples {
            peak = max(peak, abs(sample))
        }

        let fftSize = 2048
        guard samples.count >= 32 else {
            let clampedPeak = min(peak, 1)
            return AudioMeterFrame(peak: clampedPeak, bands: Array(repeating: clampedPeak, count: bucketCount))
        }

        let truncated = Array(samples.suffix(fftSize))
        let paddedSamples = truncated + Array(repeating: 0, count: max(0, fftSize - truncated.count))

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        let windowed = zip(paddedSamples, window).map(*)

        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fft = vDSP.FFT(log2n: log2n, radix: .radix2, ofType: DSPSplitComplex.self) else {
            return AudioMeterFrame(peak: min(peak, 1), bands: Array(repeating: 0, count: bucketCount))
        }

        var inReal = windowed
        var inImag = [Float](repeating: 0, count: fftSize)
        var outReal = [Float](repeating: 0, count: fftSize)
        var outImag = [Float](repeating: 0, count: fftSize)

        inReal.withUnsafeMutableBufferPointer { inRealPtr in
            inImag.withUnsafeMutableBufferPointer { inImagPtr in
                outReal.withUnsafeMutableBufferPointer { outRealPtr in
                    outImag.withUnsafeMutableBufferPointer { outImagPtr in
                        let input = DSPSplitComplex(realp: inRealPtr.baseAddress!, imagp: inImagPtr.baseAddress!)
                        var output = DSPSplitComplex(realp: outRealPtr.baseAddress!, imagp: outImagPtr.baseAddress!)
                        fft.forward(input: input, output: &output)
                    }
                }
            }
        }

        let halfCount = fftSize / 2
        let nyquist = sampleRate / 2
        let minFrequency = max(90.0, sampleRate / Double(fftSize))
        // This view is a compact "player-style" spectrum, not a lab-grade
        // analyzer. Cap the displayed range so typical music / speech spreads
        // across the whole width instead of leaving the right edge empty.
        let maxFrequency = max(min(nyquist, 8_000), minFrequency * 2)
        let minLogFrequency = log(minFrequency)
        let maxLogFrequency = log(maxFrequency)

        var bandMagnitudes = [Float](repeating: 0, count: bucketCount)

        for bucketIndex in 0..<bucketCount {
            let startT = Double(bucketIndex) / Double(bucketCount)
            let endT = Double(bucketIndex + 1) / Double(bucketCount)
            let lower = exp(minLogFrequency + ((maxLogFrequency - minLogFrequency) * startT))
            let upper = exp(minLogFrequency + ((maxLogFrequency - minLogFrequency) * endT))
            let center = sqrt(lower * upper)

            var strongest: Float = 0
            var energySum: Float = 0
            var count: Int = 0

            for bin in 1..<halfCount {
                let frequency = (Double(bin) * sampleRate) / Double(fftSize)
                guard frequency >= lower, frequency < upper else { continue }
                let magnitude = hypot(outReal[bin], outImag[bin])
                strongest = max(strongest, magnitude)
                energySum += magnitude * magnitude
                count += 1
            }

            let rms = count > 0 ? sqrt(energySum / Float(count)) : 0
            let bucketEnergy = (rms * 0.78) + (strongest * 0.22)
            // Counterbalance the natural low-frequency bias of music / voice
            // so the compact visualizer behaves more like a traditional player.
            let spectralTiltCompensation = Float(pow(max(center, 140) / 140, 0.42))
            bandMagnitudes[bucketIndex] = bucketEnergy * spectralTiltCompensation
        }

        let smoothedBands = bandMagnitudes.indices.map { index -> Float in
            let previous = bandMagnitudes[max(index - 1, 0)]
            let current = bandMagnitudes[index]
            let next = bandMagnitudes[min(index + 1, bandMagnitudes.count - 1)]
            return (previous * 0.2) + (current * 0.6) + (next * 0.2)
        }

        let maxBand = max(smoothedBands.max() ?? 0, 0.0001)
        let amplitudeScale = min(1, sqrt(min(peak, 1)) * 1.55)
        let normalizedBands = smoothedBands.enumerated().map { index, magnitude in
            let t = Float(index) / Float(max(bucketCount - 1, 1))
            let floorRatio: Float = 0.005   // ~ -46 dB floor
            let clamped = max(magnitude, maxBand * floorRatio)
            let decibels = 20 * log10(clamped / maxBand)
            let dbNormalized = max(0, min(1, (decibels + 46) / 46))
            let equalized = pow(dbNormalized, 0.88) * (0.78 + (0.92 * pow(t, 0.9)))
            return min(1, equalized * amplitudeScale)
        }

        return AudioMeterFrame(peak: min(peak, 1), bands: normalizedBands)
    }
}

// MARK: - System audio receiver

final class SystemAudioOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let writer: SegmentedAudioWriter

    /// Called on the capture queue for each buffer with a peak + spectrum
    /// snapshot. AudioRecorder hops this to the main actor + throttles to
    /// ~30 Hz for the waveform view.
    var onMeterFrame: ((AudioMeterFrame) -> Void)?

    init(writer: SegmentedAudioWriter) {
        self.writer = writer
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid else { return }
        writer.append(sampleBuffer)
        onMeterFrame?(AudioLevelExtractor.meterFrame(sampleBuffer, bucketCount: AudioSpectrumConfiguration.bucketCount))
    }

    func finishWriting() async throws -> URL? {
        try await writer.finishWriting()
    }
}

// MARK: - Microphone receiver

final class MicAudioOutput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let writer: SegmentedAudioWriter

    var onMeterFrame: ((AudioMeterFrame) -> Void)?

    init(writer: SegmentedAudioWriter) {
        self.writer = writer
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard sampleBuffer.isValid else { return }
        writer.append(sampleBuffer)
        onMeterFrame?(AudioLevelExtractor.meterFrame(sampleBuffer, bucketCount: AudioSpectrumConfiguration.bucketCount))
    }

    func finishWriting() async throws -> URL? {
        try await writer.finishWriting()
    }
}

struct CaptureStreamFormat: Equatable {
    let sampleRate: Int
    let channelCount: Int

    init(sampleRate: Int, channelCount: Int) {
        self.sampleRate = max(sampleRate, 1)
        self.channelCount = min(max(channelCount, 1), 2)
    }

    init(sampleBuffer: CMSampleBuffer) throws {
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            throw RecorderError.invalidAudioFormat
        }

        self.init(
            sampleRate: Int(asbd.pointee.mSampleRate.rounded()),
            channelCount: Int(asbd.pointee.mChannelsPerFrame)
        )
    }

    var recommendedBitRate: Int {
        min(max(channelCount, 1) * 64_000, 256_000)
    }
}

private final class UncheckedAssetWriterRef: @unchecked Sendable {
    let writer: AVAssetWriter

    init(_ writer: AVAssetWriter) {
        self.writer = writer
    }
}

final class SegmentedAudioWriter: @unchecked Sendable {
    private let finalURL: URL
    private let processingQueue: DispatchQueue
    private var activeWriter: AVAssetWriter?
    private var activeInput: AVAssetWriterInput?
    private var activeFormat: CaptureStreamFormat?
    private var activeSessionStarted = false
    private var segmentURLs: [URL] = []
    private var segmentIndex = 0
    private var pendingFinalizationCount = 0
    private var pendingError: Error?
    private var finishContinuation: CheckedContinuation<URL?, Error>?

    init(finalURL: URL, processingQueue: DispatchQueue) {
        self.finalURL = finalURL
        self.processingQueue = processingQueue
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard finishContinuation == nil else { return }

        do {
            let streamFormat = try CaptureStreamFormat(sampleBuffer: sampleBuffer)

            if activeFormat != streamFormat || activeWriter == nil || activeInput == nil {
                finishActiveSegment()
                try startSegment(for: sampleBuffer, format: streamFormat)
            }

            guard let writer = activeWriter, let input = activeInput else { return }

            if !activeSessionStarted {
                writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                activeSessionStarted = true
            }

            guard writer.status == .writing else {
                if writer.status == .failed || writer.status == .cancelled {
                    pendingError = pendingError ?? writer.error ?? RecorderError.failedToAppendAudio
                }
                return
            }

            guard input.isReadyForMoreMediaData else { return }

            if !input.append(sampleBuffer) {
                pendingError = pendingError ?? writer.error ?? RecorderError.failedToAppendAudio
            }
        } catch {
            pendingError = pendingError ?? error
        }
    }

    func finishWriting() async throws -> URL? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL?, Error>) in
            processingQueue.async {
                guard self.finishContinuation == nil else {
                    continuation.resume(throwing: RecorderError.finishAlreadyRequested)
                    return
                }

                self.finishContinuation = continuation
                self.finishActiveSegment()
                self.completeFinishIfPossible()
            }
        }
    }

    private func startSegment(for sampleBuffer: CMSampleBuffer, format: CaptureStreamFormat) throws {
        let segmentURL = makeSegmentURL(index: segmentIndex)
        segmentIndex += 1

        let writer = try AVAssetWriter(url: segmentURL, fileType: .m4a)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: format.recommendedBitRate,
        ]
        let input = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: settings,
            sourceFormatHint: sampleBuffer.formatDescription
        )
        input.expectsMediaDataInRealTime = true

        guard writer.canAdd(input) else {
            throw RecorderError.failedToCreateAudioInput
        }

        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? RecorderError.failedToStartWriter
        }

        activeWriter = writer
        activeInput = input
        activeFormat = format
        activeSessionStarted = false
        segmentURLs.append(segmentURL)
    }

    private func finishActiveSegment() {
        guard let writer = activeWriter, let input = activeInput else { return }

        activeWriter = nil
        activeInput = nil
        activeFormat = nil
        activeSessionStarted = false

        input.markAsFinished()
        pendingFinalizationCount += 1

        let writerRef = UncheckedAssetWriterRef(writer)
        writer.finishWriting { [weak self, writerRef] in
            guard let self else { return }
            let status = writerRef.writer.status
            let error = writerRef.writer.error

            self.processingQueue.async {
                if status == .failed || status == .cancelled {
                    self.pendingError = self.pendingError ?? error ?? RecorderError.failedToFinalizeSegment
                }
                self.pendingFinalizationCount -= 1
                self.completeFinishIfPossible()
            }
        }
    }

    private func completeFinishIfPossible() {
        guard pendingFinalizationCount == 0 else { return }
        guard let continuation = finishContinuation else { return }

        finishContinuation = nil

        if let error = pendingError {
            continuation.resume(throwing: error)
            return
        }

        Task {
            do {
                let finalizedURL = try await finalizeSegments()
                continuation.resume(returning: finalizedURL)
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func finalizeSegments() async throws -> URL? {
        guard !segmentURLs.isEmpty else { return nil }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: finalURL.path) {
            try fileManager.removeItem(at: finalURL)
        }

        if segmentURLs.count == 1 {
            try fileManager.moveItem(at: segmentURLs[0], to: finalURL)
            return finalURL
        }

        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw RecorderError.exportFailed
        }

        var cursor = CMTime.zero
        for segmentURL in segmentURLs {
            let asset = AVURLAsset(url: segmentURL)
            let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
            guard let sourceTrack = sourceTracks.first else {
                throw RecorderError.exportFailed
            }

            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            try track.insertTimeRange(range, of: sourceTrack, at: cursor)
            cursor = CMTimeAdd(cursor, duration)
        }

        guard let exporter = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw RecorderError.exportFailed
        }

        try await exporter.export(to: finalURL, as: .m4a)

        for segmentURL in segmentURLs {
            try? fileManager.removeItem(at: segmentURL)
        }

        return finalURL
    }

    private func makeSegmentURL(index: Int) -> URL {
        let baseName = finalURL.deletingPathExtension().lastPathComponent
        let segmentName = "\(baseName)-segment-\(String(format: "%03d", index)).m4a"
        return finalURL.deletingLastPathComponent().appendingPathComponent(segmentName)
    }
}

private struct AudioCaptureDiagnostics: Codable {
    struct FileInfo: Codable {
        let role: String
        let fileName: String
        let exists: Bool
        let sampleRate: Double?
        let channelCount: UInt32?
        let durationSeconds: Double?
        let error: String?

        init(role: String, url: URL) {
            self.role = role
            self.fileName = url.lastPathComponent
            self.exists = FileManager.default.fileExists(atPath: url.path)

            do {
                let file = try AVAudioFile(forReading: url)
                sampleRate = file.fileFormat.sampleRate
                channelCount = file.fileFormat.channelCount
                durationSeconds = file.fileFormat.sampleRate > 0
                    ? Double(file.length) / file.fileFormat.sampleRate
                    : nil
                error = nil
            } catch {
                sampleRate = nil
                channelCount = nil
                durationSeconds = nil
                self.error = error.localizedDescription
            }
        }
    }

    let createdAt: Date
    let sources: [FileInfo]
    let output: FileInfo?

    static func write(sources: [URL], output: URL?, to sessionDir: URL) {
        let diagnostics = AudioCaptureDiagnostics(
            createdAt: Date(),
            sources: sources.map { FileInfo(role: role(for: $0), url: $0) },
            output: output.map { FileInfo(role: "mixed", url: $0) }
        )

        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(diagnostics)
            try data.write(to: sessionDir.appendingPathComponent("audio-capture.json"))
        } catch {
            print("Failed to write audio capture diagnostics: \(error.localizedDescription)")
        }
    }

    private static func role(for url: URL) -> String {
        switch url.deletingPathExtension().lastPathComponent {
        case "system": "system"
        case "mic": "mic"
        default: "source"
        }
    }
}

struct OutputDeviceAudioFormat: Equatable, Sendable {
    let deviceID: AudioDeviceID
    let sampleRate: Int
    let channelCount: Int

    static func currentDefaultOutput() throws -> OutputDeviceAudioFormat {
        let deviceID = try currentDefaultOutputDeviceID()
        return try Self(
            deviceID: deviceID,
            sampleRate: currentSampleRate(for: deviceID),
            channelCount: currentChannelCount(for: deviceID)
        )
    }

    static func currentDefaultOutputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw RecorderError.unavailableOutputDevice
        }

        return deviceID
    }

    private static func currentSampleRate(for deviceID: AudioDeviceID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var sampleRate = Float64(0)
        var dataSize = UInt32(MemoryLayout<Float64>.size)

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &sampleRate)
        guard status == noErr else {
            throw RecorderError.unavailableOutputDevice
        }

        return max(Int(sampleRate.rounded()), 1)
    }

    private static func currentChannelCount(for deviceID: AudioDeviceID) throws -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(0)

        let sizeStatus = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard sizeStatus == noErr, dataSize > 0 else {
            throw RecorderError.unavailableOutputDevice
        }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }

        let valueStatus = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            bufferListPointer
        )
        guard valueStatus == noErr else {
            throw RecorderError.unavailableOutputDevice
        }

        let audioBufferList = bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        let channelCount = UnsafeMutableAudioBufferListPointer(audioBufferList)
            .reduce(0) { $0 + Int($1.mNumberChannels) }

        return max(channelCount, 1)
    }
}

final class DefaultAudioDeviceMonitor {
    enum Change: Sendable {
        case input(AudioDeviceID)
        case output(AudioDeviceID)
    }

    private let queue = DispatchQueue(label: "RecappiMini.OutputDeviceMonitor")
    private let onChange: @Sendable (Change) -> Void
    private var currentOutputDeviceID: AudioDeviceID?
    private var currentInputDeviceID: AudioDeviceID?
    private var lastFormat: OutputDeviceAudioFormat?
    private var defaultInputListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var currentDeviceListener: AudioObjectPropertyListenerBlock?

    init(onChange: @escaping @Sendable (Change) -> Void) throws {
        self.onChange = onChange

        let initialFormat = try OutputDeviceAudioFormat.currentDefaultOutput()
        self.currentOutputDeviceID = initialFormat.deviceID
        self.currentInputDeviceID = try Self.currentDefaultInputDeviceID()
        self.lastFormat = initialFormat

        try addDefaultInputListener()
        try addDefaultDeviceListener()
        try addCurrentDeviceListeners(for: initialFormat.deviceID)
    }

    deinit {
        stop()
    }

    func stop() {
        if let defaultInputListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                defaultInputListener
            )
            self.defaultInputListener = nil
        }

        if let defaultDeviceListener {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                defaultDeviceListener
            )
            self.defaultDeviceListener = nil
        }

        removeCurrentDeviceListeners()
    }

    private func addDefaultInputListener() throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleInputDeviceChange()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )
        guard status == noErr else {
            throw RecorderError.failedToMonitorOutputDevice
        }

        defaultInputListener = listener
    }

    private func addDefaultDeviceListener() throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceOrFormatChange()
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )
        guard status == noErr else {
            throw RecorderError.failedToMonitorOutputDevice
        }

        defaultDeviceListener = listener
    }

    private func addCurrentDeviceListeners(for deviceID: AudioDeviceID) throws {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handleDeviceOrFormatChange()
        }

        var sampleRateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var channelAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        let sampleRateStatus = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &sampleRateAddress,
            queue,
            listener
        )
        guard sampleRateStatus == noErr else {
            throw RecorderError.failedToMonitorOutputDevice
        }

        let channelStatus = AudioObjectAddPropertyListenerBlock(
            deviceID,
            &channelAddress,
            queue,
            listener
        )
        guard channelStatus == noErr else {
            AudioObjectRemovePropertyListenerBlock(deviceID, &sampleRateAddress, queue, listener)
            throw RecorderError.failedToMonitorOutputDevice
        }

        currentDeviceListener = listener
    }

    private func removeCurrentDeviceListeners() {
        guard let deviceID = currentOutputDeviceID, let currentDeviceListener else { return }

        var sampleRateAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var channelAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        AudioObjectRemovePropertyListenerBlock(deviceID, &sampleRateAddress, queue, currentDeviceListener)
        AudioObjectRemovePropertyListenerBlock(deviceID, &channelAddress, queue, currentDeviceListener)
        self.currentDeviceListener = nil
    }

    private func handleInputDeviceChange() {
        guard let deviceID = try? Self.currentDefaultInputDeviceID() else { return }
        guard deviceID != currentInputDeviceID else { return }

        currentInputDeviceID = deviceID
        onChange(.input(deviceID))
    }

    private func handleDeviceOrFormatChange() {
        guard let format = try? OutputDeviceAudioFormat.currentDefaultOutput() else { return }

        if format.deviceID != currentOutputDeviceID {
            removeCurrentDeviceListeners()
            currentOutputDeviceID = format.deviceID
            try? addCurrentDeviceListeners(for: format.deviceID)
        }

        guard format != lastFormat else { return }
        lastFormat = format
        onChange(.output(format.deviceID))
    }

    private static func currentDefaultInputDeviceID() throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            throw RecorderError.unavailableOutputDevice
        }

        return deviceID
    }
}

// MARK: - Errors

enum RecorderError: LocalizedError {
    case noDisplay
    case noMicrophone
    case micDenied
    case screenCaptureDenied
    case micSetupFailed
    case notRecording
    case noSessionDir
    case exportFailed
    case missingUITestFixture
    case unavailableOutputDevice
    case failedToMonitorOutputDevice
    case invalidAudioFormat
    case failedToCreateAudioInput
    case failedToStartWriter
    case failedToAppendAudio
    case failedToFinalizeSegment
    case finishAlreadyRequested

    var errorDescription: String? {
        switch self {
        case .noDisplay: return "No display found for audio capture"
        case .noMicrophone: return "No microphone found"
        case .micDenied: return "Microphone access denied. Enable in System Settings > Privacy & Security > Microphone"
        case .screenCaptureDenied: return "Screen & system audio recording access is required. Enable Recappi Mini in System Settings > Privacy & Security > Screen & System Audio Recording"
        case .micSetupFailed: return "Couldn't set up microphone capture"
        case .notRecording: return "Not currently recording"
        case .noSessionDir: return "No session directory"
        case .exportFailed: return "Failed to merge audio sources"
        case .missingUITestFixture: return "UI test fixture audio is missing"
        case .unavailableOutputDevice: return "Couldn't read the current output device format"
        case .failedToMonitorOutputDevice: return "Couldn't monitor output device changes"
        case .invalidAudioFormat: return "Audio format information is unavailable"
        case .failedToCreateAudioInput: return "Couldn't create the audio writer input"
        case .failedToStartWriter: return "Couldn't start the audio writer"
        case .failedToAppendAudio: return "Couldn't append captured audio"
        case .failedToFinalizeSegment: return "Couldn't finalize the recorded audio segment"
        case .finishAlreadyRequested: return "Audio finishing is already in progress"
        }
    }
}
