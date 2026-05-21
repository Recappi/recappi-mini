import AVFoundation
import AppKit
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation

enum SystemAudioCaptureBackend: String {
    case screenCaptureKit
    case coreAudioProcessTap

    static var current: SystemAudioCaptureBackend {
        switch ProcessInfo.processInfo.environment["RECAPPI_SYSTEM_AUDIO_CAPTURE"] {
        case "screen-capture-kit":
            return .screenCaptureKit
        default:
            return .coreAudioProcessTap
        }
    }
}

private struct CoreAudioStatusError: LocalizedError {
    let operation: String
    let status: OSStatus

    var errorDescription: String? {
        "\(operation) failed with OSStatus \(status) (\(fourCC(status)))"
    }

    private func fourCC(_ status: OSStatus) -> String {
        let value = UInt32(bitPattern: status.bigEndian)
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        guard bytes.allSatisfy({ $0 >= 32 && $0 < 127 }) else {
            return "0x\(String(UInt32(bitPattern: status), radix: 16))"
        }
        return "'" + String(bytes: bytes, encoding: .ascii).orElse("?") + "'"
    }
}

private extension Optional where Wrapped == String {
    func orElse(_ fallback: String) -> String {
        self ?? fallback
    }
}

private enum CoreAudioProcessResolver {
    static func processObjectID(pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var mutablePID = pid
        var processObjectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let qualifierSize = UInt32(MemoryLayout<pid_t>.size)

        let status = withUnsafePointer(to: &mutablePID) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                qualifierSize,
                pidPtr,
                &size,
                &processObjectID
            )
        }
        guard status == noErr, processObjectID != kAudioObjectUnknown else {
            return nil
        }
        return processObjectID
    }

}

final class CoreAudioProcessTapCapture: @unchecked Sendable {
    private let selectedBundleID: String?
    private let selfBundleID: String
    private let output: SystemAudioOutput
    private let captureQueue: DispatchQueue
    private let stateQueue = DispatchQueue(label: "RecappiMini.CoreAudioProcessTap.state")
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var sampleFactory: CoreAudioTapSampleBufferFactory?
    private var isStarted = false

    init(
        selectedBundleID: String?,
        selfBundleID: String,
        output: SystemAudioOutput,
        captureQueue: DispatchQueue
    ) {
        self.selectedBundleID = selectedBundleID
        self.selfBundleID = selfBundleID
        self.output = output
        self.captureQueue = captureQueue
    }

    deinit {
        stop()
    }

    func start() throws {
        guard !isStarted else { return }

        let tapDescription = makeTapDescription()
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        try check(
            AudioHardwareCreateProcessTap(tapDescription, &newTapID),
            operation: "AudioHardwareCreateProcessTap"
        )
        tapID = newTapID

        let tapUID = try readTapUID(tapID)
        let tapFormat = try readTapFormat(tapID)
        sampleFactory = try CoreAudioTapSampleBufferFactory(sourceFormat: tapFormat)

        var newAggregateDeviceID = AudioObjectID(kAudioObjectUnknown)
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Recappi System Audio Tap",
            kAudioAggregateDeviceUIDKey: "com.recappi.mini.system-audio-tap.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapDriftCompensationQualityKey: kAudioAggregateDriftCompensationLowQuality,
                ] as [String: Any],
            ],
        ]
        try check(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateDeviceID),
            operation: "AudioHardwareCreateAggregateDevice"
        )
        aggregateDeviceID = newAggregateDeviceID

        var newIOProcID: AudioDeviceIOProcID?
        try check(
            AudioDeviceCreateIOProcIDWithBlock(
                &newIOProcID,
                aggregateDeviceID,
                captureQueue,
                { [weak self] _, inputData, inputTime, _, _ in
                    self?.handleInput(inputData, inputTime: inputTime)
                }
            ),
            operation: "AudioDeviceCreateIOProcIDWithBlock"
        )
        ioProcID = newIOProcID

        try check(AudioDeviceStart(aggregateDeviceID, newIOProcID), operation: "AudioDeviceStart")
        isStarted = true
        DiagnosticsLog.event(
            "recording",
            "core_audio_tap.started selectedBundle=\(selectedBundleID ?? "all-system-audio") tap=\(tapID) aggregate=\(aggregateDeviceID)"
        )
    }

    func stop() {
        stateQueue.sync {
            guard tapID != kAudioObjectUnknown || aggregateDeviceID != kAudioObjectUnknown else { return }

            if let ioProcID, aggregateDeviceID != kAudioObjectUnknown {
                AudioDeviceStop(aggregateDeviceID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
            }
            ioProcID = nil

            if aggregateDeviceID != kAudioObjectUnknown {
                AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            }
            aggregateDeviceID = AudioObjectID(kAudioObjectUnknown)

            if tapID != kAudioObjectUnknown {
                AudioHardwareDestroyProcessTap(tapID)
            }
            tapID = AudioObjectID(kAudioObjectUnknown)
            sampleFactory = nil
            isStarted = false
        }
    }

    private func makeTapDescription() -> CATapDescription {
        let description = CATapDescription()
        description.name = "Recappi System Audio Tap"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.isMixdown = true
        description.isMono = false

        // Product default: capture the user's system output broadly and
        // exclude Recappi itself. This mirrors ScreenCaptureKit's
        // `excludesCurrentProcessAudio` behavior without depending on the
        // screen-capture pipeline. Process-specific selection is intentionally
        // disabled for now because app helper/process churn can otherwise
        // make the tap silently miss audio mid-call.
        var excluded: [AudioObjectID] = []
        if let selfProcessID = CoreAudioProcessResolver.processObjectID(pid: getpid()) {
            excluded.append(selfProcessID)
        }
        description.processes = excluded
        description.isExclusive = true
        DiagnosticsLog.event(
            "recording",
            "core_audio_tap.target global excludeSelf=\(!excluded.isEmpty) selectedBundle=\(selectedBundleID ?? "none") selfBundle=\(selfBundleID)"
        )
        return description
    }

    private func handleInput(
        _ inputData: UnsafePointer<AudioBufferList>?,
        inputTime: UnsafePointer<AudioTimeStamp>?
    ) {
        guard let inputData else { return }
        do {
            guard let sampleBuffer = try sampleFactory?.makeSampleBuffer(
                from: inputData,
                inputTime: inputTime?.pointee
            ) else {
                return
            }
            output.handleAudioSampleBuffer(sampleBuffer)
        } catch {
            DiagnosticsLog.error("recording", "core_audio_tap.buffer.failed \(DiagnosticsLog.errorSummary(error))")
        }
    }

    private func readTapUID(_ tapID: AudioObjectID) throws -> CFString {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString>.size)
        var tapUID: Unmanaged<CFString>?
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &tapUID),
            operation: "kAudioTapPropertyUID"
        )
        guard let uid = tapUID?.takeRetainedValue() else {
            throw CoreAudioStatusError(operation: "kAudioTapPropertyUID(empty)", status: -1)
        }
        return uid
    }

    private func readTapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format),
            operation: "kAudioTapPropertyFormat"
        )
        return format
    }

    private func check(_ status: OSStatus, operation: String) throws {
        guard status == noErr else {
            throw CoreAudioStatusError(operation: operation, status: status)
        }
    }
}

private struct CoreAudioBufferListView {
    private let buffers: [AudioBuffer]

    init(_ audioBufferList: UnsafePointer<AudioBufferList>) {
        var collected: [AudioBuffer] = []
        withUnsafePointer(to: audioBufferList.pointee.mBuffers) { firstBufferPointer in
            let bufferPointer = UnsafeBufferPointer(
                start: firstBufferPointer,
                count: Int(audioBufferList.pointee.mNumberBuffers)
            )
            collected = Array(bufferPointer)
        }
        buffers = collected
    }

    var isEmpty: Bool { buffers.isEmpty }
    var count: Int { buffers.count }

    subscript(index: Int) -> AudioBuffer {
        buffers[index]
    }

    func forEach(_ body: (AudioBuffer) -> Void) {
        buffers.forEach(body)
    }
}

private final class CoreAudioTapSampleBufferFactory {
    private let sourceFormat: AudioStreamBasicDescription
    private let outputFormat: AudioStreamBasicDescription
    private let formatDescription: CMAudioFormatDescription
    private var nextFramePosition: Int64 = 0

    init(sourceFormat: AudioStreamBasicDescription) throws {
        self.sourceFormat = sourceFormat
        let channelCount = min(max(Int(sourceFormat.mChannelsPerFrame), 1), 2)
        let sampleRate = sourceFormat.mSampleRate.isFinite && sourceFormat.mSampleRate > 0
            ? sourceFormat.mSampleRate
            : 48_000
        var output = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: UInt32(channelCount * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channelCount * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        self.outputFormat = output

        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &output,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw CoreAudioStatusError(operation: "CMAudioFormatDescriptionCreate", status: status)
        }
        formatDescription = description
    }

    func makeSampleBuffer(
        from audioBufferList: UnsafePointer<AudioBufferList>,
        inputTime: AudioTimeStamp?
    ) throws -> CMSampleBuffer? {
        let samples = try interleavedFloat32Samples(from: audioBufferList)
        let channelCount = Int(outputFormat.mChannelsPerFrame)
        guard channelCount > 0, !samples.isEmpty else { return nil }

        let frameCount = samples.count / channelCount
        guard frameCount > 0 else { return nil }

        let ptsFrame: Int64
        if let inputTime,
           inputTime.mFlags.contains(.sampleTimeValid),
           inputTime.mSampleTime.isFinite,
           inputTime.mSampleTime >= 0 {
            ptsFrame = Int64(inputTime.mSampleTime.rounded())
            nextFramePosition = ptsFrame + Int64(frameCount)
        } else {
            ptsFrame = nextFramePosition
            nextFramePosition += Int64(frameCount)
        }

        return try makeCMSampleBuffer(
            samples: samples,
            frameCount: frameCount,
            ptsFrame: ptsFrame
        )
    }

    private func interleavedFloat32Samples(
        from audioBufferList: UnsafePointer<AudioBufferList>
    ) throws -> [Float] {
        let buffers = CoreAudioBufferListView(audioBufferList)
        guard !buffers.isEmpty else { return [] }
        let sourceChannels = max(Int(sourceFormat.mChannelsPerFrame), 1)
        let outputChannels = Int(outputFormat.mChannelsPerFrame)
        let sourceIsFloat = (sourceFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let sourceIsNonInterleaved = (sourceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let bytesPerSample = max(Int(sourceFormat.mBitsPerChannel / 8), 1)

        if sourceIsFloat, sourceFormat.mBitsPerChannel == 32 {
            if sourceIsNonInterleaved || buffers.count > 1 {
                let frameCount = minimumFrameCount(
                    in: buffers,
                    bytesPerSample: MemoryLayout<Float>.size
                )
                guard frameCount > 0 else { return [] }
                var samples = [Float](repeating: 0, count: frameCount * outputChannels)
                for channel in 0..<outputChannels {
                    let bufferIndex = min(channel, buffers.count - 1)
                    guard let data = buffers[bufferIndex].mData else { continue }
                    let ptr = data.assumingMemoryBound(to: Float.self)
                    for frame in 0..<frameCount {
                        samples[frame * outputChannels + channel] = ptr[frame]
                    }
                }
                return samples
            }

            guard let data = buffers[0].mData else { return [] }
            let availableSamples = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            let frames = availableSamples / sourceChannels
            guard frames > 0 else { return [] }
            let ptr = data.assumingMemoryBound(to: Float.self)
            var samples = [Float](repeating: 0, count: frames * outputChannels)
            for frame in 0..<frames {
                for channel in 0..<outputChannels {
                    samples[frame * outputChannels + channel] = ptr[frame * sourceChannels + min(channel, sourceChannels - 1)]
                }
            }
            return samples
        }

        if sourceFormat.mBitsPerChannel == 16 {
            if sourceIsNonInterleaved || buffers.count > 1 {
                let frameCount = minimumFrameCount(
                    in: buffers,
                    bytesPerSample: MemoryLayout<Int16>.size
                )
                guard frameCount > 0 else { return [] }
                var samples = [Float](repeating: 0, count: frameCount * outputChannels)
                for channel in 0..<outputChannels {
                    let bufferIndex = min(channel, buffers.count - 1)
                    guard let data = buffers[bufferIndex].mData else { continue }
                    let ptr = data.assumingMemoryBound(to: Int16.self)
                    for frame in 0..<frameCount {
                        samples[frame * outputChannels + channel] = Float(ptr[frame]) / 32768.0
                    }
                }
                return samples
            }

            guard let data = buffers[0].mData else { return [] }
            let availableSamples = Int(buffers[0].mDataByteSize) / MemoryLayout<Int16>.size
            let frames = availableSamples / sourceChannels
            guard frames > 0 else { return [] }
            let ptr = data.assumingMemoryBound(to: Int16.self)
            var samples = [Float](repeating: 0, count: frames * outputChannels)
            for frame in 0..<frames {
                for channel in 0..<outputChannels {
                    samples[frame * outputChannels + channel] = Float(ptr[frame * sourceChannels + min(channel, sourceChannels - 1)]) / 32768.0
                }
            }
            return samples
        }

        throw CoreAudioStatusError(operation: "Unsupported tap format bytesPerSample=\(bytesPerSample)", status: -1)
    }

    private func minimumFrameCount(
        in buffers: CoreAudioBufferListView,
        bytesPerSample: Int
    ) -> Int {
        var result: Int?
        for index in 0..<buffers.count {
            let buffer = buffers[index]
            let channelCount = max(Int(buffer.mNumberChannels), 1)
            let frames = Int(buffer.mDataByteSize) / bytesPerSample / channelCount
            result = min(result ?? frames, frames)
        }
        return result ?? 0
    }

    private func makeCMSampleBuffer(
        samples: [Float],
        frameCount: Int,
        ptsFrame: Int64
    ) throws -> CMSampleBuffer {
        let byteCount = samples.count * MemoryLayout<Float>.stride
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: byteCount,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else {
            throw CoreAudioStatusError(operation: "CMBlockBufferCreateWithMemoryBlock", status: status)
        }

        try samples.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            status = CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: byteCount
            )
            guard status == kCMBlockBufferNoErr else {
                throw CoreAudioStatusError(operation: "CMBlockBufferReplaceDataBytes", status: status)
            }
        }

        let sampleRate = max(Int32(outputFormat.mSampleRate.rounded()), 1)
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: CMTime(value: ptsFrame, timescale: sampleRate),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw CoreAudioStatusError(operation: "CMSampleBufferCreateReady", status: status)
        }
        return sampleBuffer
    }
}
