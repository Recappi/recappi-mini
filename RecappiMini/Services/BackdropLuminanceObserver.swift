import AppKit
import CoreImage
import Foundation
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// Watches the screen content under a floating panel and decides whether
/// the panel should use a light or dark chrome to stay legible. The
/// shipping HUD's light theme leans on translucent vibrancy materials,
/// which mix with whatever is behind the panel — sitting on a dark
/// surface (a dark app window, dark wallpaper, terminal) bleeds the
/// pill chrome into a muddy grey. This observer samples the backdrop
/// luminance, hysteresis-filters the result, and publishes a single
/// `prefersDarkChrome` flag that the panel chrome bindings can read.
///
/// Sampling uses the legacy `CGWindowListCreateImage` API (still works
/// on macOS 14+) restricted to windows below the panel's own window
/// number. We already hold Screen Recording entitlement for audio
/// capture via ScreenCaptureKit, so no new permission is requested. If
/// sampling fails for any reason (permission revoked, capture returned
/// nothing, image processing error) the observer falls back to dark
/// chrome — the previous "light chrome over dark backdrop" failure mode
/// peng-xiao flagged should never re-emerge.
@MainActor
final class BackdropLuminanceObserver: ObservableObject {
    /// `true` when the sampled backdrop is dark enough that the panel
    /// should switch to a dark chrome. SwiftUI views read this through
    /// the published binding to flip materials with a smooth animation.
    @Published private(set) var prefersDarkChrome: Bool = true

    /// Luminance threshold (rec. 709) below which we consider the
    /// backdrop "dark". 0.55 puts the cutover near a mid-grey so any
    /// noticeably dark surface (saturated colors / dark images / dark
    /// terminals) trips dark chrome; light wallpapers and white app
    /// windows stay in light chrome.
    private let darknessThreshold: Double = 0.55

    /// Hysteresis window — a new luminance verdict only wins after it has
    /// been confirmed by a *second* sample taken at least this long after
    /// the first. Sampling is event-driven (see below), so consecutive
    /// samples can be seconds or minutes apart; the window only guards
    /// against a single transient sample flipping the chrome, while a
    /// genuine backdrop change is confirmed by the next event's sample.
    private let hysteresisInterval: TimeInterval = 2.0

    /// Minimum spacing between ScreenCaptureKit roundtrips. Event triggers
    /// (app switches, space changes) can arrive in quick bursts; this caps
    /// the capture rate so a burst can't reintroduce the render-server
    /// contention the periodic heartbeat used to cause.
    private let minSampleInterval: TimeInterval = 1.5

    /// Pending verdict that hasn't yet survived the hysteresis window.
    private var pendingVerdict: Bool?
    private var pendingVerdictStart: Date?

    private weak var trackedWindow: NSWindow?
    private var samplingInFlight: Bool = false
    private var lastSampleStartedAt: Date?
    private var confirmWorkItem: DispatchWorkItem?

    /// Whether we are attached to a window and listening for re-sample
    /// events. Sampling is now purely event-driven — there is no periodic
    /// timer — because a fixed-interval ScreenCaptureKit poll competed with
    /// the floating panels' CoreAnimation surface allocation on the render
    /// server and produced ≥2s App Hangs while a recording panel sat
    /// visible (Sentry APPLE-MACOS-E/10: done-state, glass surface, active
    /// backdrop sampling, multi-display). The panel is anchored and the
    /// backdrop only changes on a few discrete events, all observed below.
    private var isSampling = false

    /// Event-driven re-sample tokens. These fire a (throttled, coalesced)
    /// sample on the moments the backdrop genuinely changes: the panel
    /// moves, the screen/space changes, or the frontmost app switches
    /// (which is when the window *behind* a stationary panel changes — the
    /// case the old heartbeat existed to catch).
    private var windowMoveToken: NSObjectProtocol?
    private var screenParamsToken: NSObjectProtocol?
    private var spaceChangeToken: NSObjectProtocol?
    private var appActivationToken: NSObjectProtocol?

    /// Mirrors `FloatingPanel.applyAdaptiveAppearance`: in a dark system
    /// appearance the panel inherits the host appearance and the backdrop
    /// verdict is discarded, so sampling is pure wasted work.
    private var systemUsesDarkAppearance: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    var diagnosticsSamplingState: String {
        if UITestModeConfiguration.shared.forceAdaptiveDarkChromeForTesting {
            return "forced"
        }
        guard trackedWindow != nil, isSampling else {
            return "inactive"
        }
        return systemUsesDarkAppearance ? "inactive:system_dark" : "active"
    }

    var diagnosticsChromeMode: String {
        if systemUsesDarkAppearance {
            return "system_dark"
        }
        return prefersDarkChrome ? "dark" : "light"
    }

    /// Start sampling the backdrop beneath the given window. Idempotent;
    /// calling again with the same window is a no-op.
    ///
    /// In UI test mode with `RECAPPI_TEST_FORCE_ADAPTIVE_DARK_CHROME=1`
    /// we skip the sampling timer entirely and pin `prefersDarkChrome`
    /// so screenshot fixtures can capture dark-chrome rendering without
    /// physically dragging the panel over a dark window.
    func attach(to window: NSWindow) {
        if UITestModeConfiguration.shared.forceAdaptiveDarkChromeForTesting {
            trackedWindow = window
            removeEventObservers()
            isSampling = false
            prefersDarkChrome = true
            return
        }
        if trackedWindow === window, isSampling { return }
        trackedWindow = window
        startSampling()
    }

    func detach() {
        removeEventObservers()
        isSampling = false
        confirmWorkItem?.cancel()
        confirmWorkItem = nil
        trackedWindow = nil
        pendingVerdict = nil
        pendingVerdictStart = nil
    }

    private func startSampling() {
        installEventObservers()
        isSampling = true
        // Sample once immediately so the chrome reflects the current
        // backdrop instead of flashing the default; subsequent samples are
        // driven only by the events installed above.
        sampleNow()
    }

    /// Subscribe to the events that actually change the backdrop so the
    /// heartbeat can run slowly. Each fires a coalesced `sampleNow()`
    /// (which no-ops while a sample is in flight or in dark appearance).
    private func installEventObservers() {
        removeEventObservers()
        let center = NotificationCenter.default
        if let window = trackedWindow {
            windowMoveToken = center.addObserver(
                forName: NSWindow.didMoveNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.sampleNow() }
            }
        }
        screenParamsToken = center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleNow() }
        }
        spaceChangeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleNow() }
        }
        // Frontmost-app switches are the one backdrop change a stationary
        // panel can't observe via its own move/screen events: the window
        // *behind* the panel changes. Re-sampling here replaces the old
        // periodic heartbeat for that case, without the per-tick capture.
        appActivationToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleNow() }
        }
    }

    private func removeEventObservers() {
        if let token = windowMoveToken {
            NotificationCenter.default.removeObserver(token)
            windowMoveToken = nil
        }
        if let token = screenParamsToken {
            NotificationCenter.default.removeObserver(token)
            screenParamsToken = nil
        }
        if let token = spaceChangeToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            spaceChangeToken = nil
        }
        if let token = appActivationToken {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            appActivationToken = nil
        }
    }

    private func sampleNow() {
        guard let window = trackedWindow, window.isVisible else { return }
        // Skip the ScreenCaptureKit roundtrip when the verdict won't be
        // used: in a dark system appearance the panel inherits the host
        // chrome and the verdict is discarded.
        guard !systemUsesDarkAppearance else { return }
        guard !samplingInFlight else { return }
        // Throttle event bursts (e.g. rapid app switching) so they can't
        // reintroduce render-server contention.
        if let last = lastSampleStartedAt, Date().timeIntervalSince(last) < minSampleInterval {
            return
        }
        lastSampleStartedAt = Date()

        let frame = window.frame
        guard frame.width > 4, frame.height > 4 else { return }
        let windowNumber = CGWindowID(window.windowNumber)
        guard let display = window.screen else { return }
        let displayFrame = display.frame
        let threshold = darknessThreshold

        samplingInFlight = true
        Task.detached(priority: .utility) { [weak self] in
            let verdict = await Self.sampleBackdropVerdict(
                windowFrame: frame,
                excludingWindowID: windowNumber,
                displayFrame: displayFrame,
                threshold: threshold
            )
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.samplingInFlight = false
                guard self.trackedWindow?.windowNumber == Int(windowNumber) else { return }
                self.applyVerdict(verdict)
            }
        }
    }

    /// Performs the ScreenCaptureKit roundtrip off the main actor. Always
    /// returns a verdict — falls back to `true` (dark chrome) on any
    /// error, since that's the safe default per peng-xiao's complaint.
    private nonisolated static func sampleBackdropVerdict(
        windowFrame: CGRect,
        excludingWindowID: CGWindowID,
        displayFrame: CGRect,
        threshold: Double
    ) async -> Bool {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first(where: { $0.frame.intersects(windowFrame) }) ?? content.displays.first else {
                return true
            }
            let excludedWindows = content.windows.filter { $0.windowID == excludingWindowID }
            let filter = SCContentFilter(
                display: display,
                excludingWindows: excludedWindows
            )

            let configuration = SCStreamConfiguration()
            // Translate Cocoa screen-space (y from bottom) to SCStream's
            // flipped display-local space (y from top of `display.frame`).
            let displayLocalX = windowFrame.origin.x - displayFrame.origin.x
            let displayLocalY = (displayFrame.maxY - windowFrame.maxY)
            configuration.sourceRect = CGRect(
                x: displayLocalX,
                y: displayLocalY,
                width: windowFrame.width,
                height: windowFrame.height
            )
            configuration.width = max(8, Int(windowFrame.width / 8))
            configuration.height = max(8, Int(windowFrame.height / 8))
            configuration.scalesToFit = true
            configuration.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            let context = CIContext(options: [.useSoftwareRenderer: false])
            let luminance = averageLuminance(of: cgImage, using: context)
            return luminance < threshold
        } catch {
            return true
        }
    }

    private nonisolated static func averageLuminance(of cgImage: CGImage, using context: CIContext) -> Double {
        let ciImage = CIImage(cgImage: cgImage)
        let extent = ciImage.extent
        guard let filter = CIFilter(name: "CIAreaAverage") else { return 0.5 }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: "inputExtent")
        guard let output = filter.outputImage else { return 0.5 }

        var bitmap = [UInt8](repeating: 0, count: 4)
        context.render(
            output,
            toBitmap: &bitmap,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let r = Double(bitmap[0]) / 255.0
        let g = Double(bitmap[1]) / 255.0
        let b = Double(bitmap[2]) / 255.0
        // rec. 709 luma — what the eye reads as "brightness". Pure RGB
        // average overweights blue/red surfaces; this puts the threshold
        // where humans actually see the transition.
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func applyVerdict(_ newVerdict: Bool) {
        if newVerdict == prefersDarkChrome {
            // Already in the right state; drop any pending opposite verdict.
            pendingVerdict = nil
            pendingVerdictStart = nil
            confirmWorkItem?.cancel()
            confirmWorkItem = nil
            return
        }

        let now = Date()
        if pendingVerdict == newVerdict, let start = pendingVerdictStart {
            if now.timeIntervalSince(start) >= hysteresisInterval {
                prefersDarkChrome = newVerdict
                pendingVerdict = nil
                pendingVerdictStart = nil
                confirmWorkItem?.cancel()
                confirmWorkItem = nil
            }
            return
        }

        pendingVerdict = newVerdict
        pendingVerdictStart = now
        // Sampling is event-driven, so a confirming sample is not guaranteed
        // to arrive on its own (a single app switch may be the only event).
        // Schedule exactly one follow-up sample past the hysteresis window so
        // a genuine backdrop change still commits without a periodic timer.
        scheduleConfirmSample()
    }

    /// Schedule a single delayed re-sample to confirm a pending verdict.
    /// Fires just past `hysteresisInterval` so the confirming sample's
    /// timestamp clears the window; cancelled as soon as the verdict commits
    /// or clears. This is one capture per genuine change — not a heartbeat.
    private func scheduleConfirmSample() {
        confirmWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.sampleNow() }
        }
        confirmWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + hysteresisInterval + 0.1, execute: work)
    }
}
