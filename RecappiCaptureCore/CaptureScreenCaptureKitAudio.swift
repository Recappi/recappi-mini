import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

public struct CaptureScreenCaptureKitStream {
    public let stream: SCStream
    public let matchedBundleID: String?

    public init(stream: SCStream, matchedBundleID: String?) {
        self.stream = stream
        self.matchedBundleID = matchedBundleID
    }
}

public enum CaptureScreenCaptureKitAudio {
    public static func makeAudioConfiguration() -> SCStreamConfiguration {
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

    public static func makeStream(
        display: SCDisplay,
        applications: [SCRunningApplication],
        targetBundleID: String?,
        output: any SCStreamOutput,
        sampleHandlerQueue: DispatchQueue
    ) throws -> CaptureScreenCaptureKitStream {
        let filterResult = makeFilter(
            display: display,
            applications: applications,
            targetBundleID: targetBundleID
        )
        let stream = SCStream(
            filter: filterResult.filter,
            configuration: makeAudioConfiguration(),
            delegate: nil
        )
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleHandlerQueue)
        return CaptureScreenCaptureKitStream(
            stream: stream,
            matchedBundleID: filterResult.matchedBundleID
        )
    }

    public static func makeFilter(
        display: SCDisplay,
        applications: [SCRunningApplication],
        targetBundleID: String?
    ) -> (filter: SCContentFilter, matchedBundleID: String?) {
        guard let targetBundleID else {
            return (
                SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
                nil
            )
        }

        let liveApps = applications.filter {
            CaptureBundleCollapser.matches($0.bundleIdentifier, selected: targetBundleID)
        }
        guard !liveApps.isEmpty else {
            return (
                SCContentFilter(display: display, excludingApplications: [], exceptingWindows: []),
                nil
            )
        }

        return (
            SCContentFilter(display: display, including: liveApps, exceptingWindows: []),
            targetBundleID
        )
    }
}
