import Accelerate
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
        // `AudioBufferList` is a C struct whose `mBuffers` is a flexible array
        // member: the second and later buffers live in memory *after* the inline
        // first one, not inside it. Reading them requires walking from the real
        // `mBuffers` address. `withUnsafePointer(to: list.pointee.mBuffers)` would
        // instead hand back a pointer to a stack *copy* of just the first buffer,
        // so any `mNumberBuffers > 1` (non-interleaved / multi-buffer taps) would
        // read adjacent stack garbage for the trailing buffers. Use the standard
        // `UnsafeMutableAudioBufferListPointer` walker, which indexes the flexible
        // array correctly. The pointer is only read here; the cast to mutable is
        // safe because the walker never writes through it.
        let mutableList = UnsafeMutablePointer(mutating: audioBufferList)
        let listPointer = UnsafeMutableAudioBufferListPointer(mutableList)
        buffers = Array(listPointer)
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

/// Builds the output PCM `CMSampleBuffer` from raw tap buffers.
///
/// Confinement: every mutating method here is only ever called from the single
/// CoreAudio IOProc block, which runs on one serial `captureQueue` per capture
/// instance (see `CoreAudioProcessTapCapture.handleInput`). `nextFramePosition`
/// and the reused `scratchSamples` buffer therefore have a single producer and
/// need no locking. `internal` (rather than `private`) only so the equivalence
/// tests can exercise the conversion math directly; nothing else references it.
final class CoreAudioTapSampleBufferFactory {
    private let sourceFormat: AudioStreamBasicDescription
    private let outputFormat: AudioStreamBasicDescription
    private let formatDescription: CMAudioFormatDescription
    private var nextFramePosition: Int64 = 0

    /// Reused interleaved-float32 scratch for the conversion/remap paths. Grown
    /// (never shrunk) as buffer sizes demand so the ~100 buffers/s hot path stops
    /// allocating a fresh `[Float]` per callback. Only the leading
    /// `frameCount * outputChannels` elements are meaningful on any given call;
    /// callers must never read past that. Confined to the single IOProc producer.
    private var scratchSamples: [Float] = []

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
        // Fast path (Option A): the source is already a single packed,
        // interleaved float32 buffer whose channel count matches the output
        // (the dominant 48k/2ch case). The bytes are bit-for-bit the layout we
        // emit, so we copy them once straight into the CMBlockBuffer and skip
        // both the intermediate `[Float]` and the scalar element copy.
        if let direct = try directFloat32SampleBuffer(from: audioBufferList, inputTime: inputTime) {
            return direct
        }

        // Conversion / channel-remap path. `fillScratch` writes the interleaved
        // float32 result into the reused `scratchSamples` buffer and returns the
        // count of meaningful leading elements; we never read past that.
        let sampleCount = try fillScratch(from: audioBufferList)
        let channelCount = Int(outputFormat.mChannelsPerFrame)
        guard channelCount > 0, sampleCount > 0 else { return nil }

        let frameCount = sampleCount / channelCount
        guard frameCount > 0 else { return nil }

        let ptsFrame = advancePTS(frameCount: frameCount, inputTime: inputTime)
        let byteCount = sampleCount * MemoryLayout<Float>.stride
        return try scratchSamples.withUnsafeBytes { rawBuffer -> CMSampleBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                throw CoreAudioStatusError(operation: "scratchSamples empty base", status: -1)
            }
            return try makeCMSampleBuffer(
                bytes: baseAddress,
                byteCount: byteCount,
                frameCount: frameCount,
                ptsFrame: ptsFrame
            )
        }
    }

    /// Advances `nextFramePosition` and returns the presentation frame for this
    /// buffer. Identical timing logic for every path so PTS stays byte-stable.
    private func advancePTS(frameCount: Int, inputTime: AudioTimeStamp?) -> Int64 {
        if let inputTime,
           inputTime.mFlags.contains(.sampleTimeValid),
           inputTime.mSampleTime.isFinite,
           inputTime.mSampleTime >= 0 {
            let ptsFrame = Int64(inputTime.mSampleTime.rounded())
            nextFramePosition = ptsFrame + Int64(frameCount)
            return ptsFrame
        }
        let ptsFrame = nextFramePosition
        nextFramePosition += Int64(frameCount)
        return ptsFrame
    }

    /// Option A. Returns a finished sample buffer built with a single copy when
    /// the source is one packed interleaved float32 buffer with the output
    /// channel count, otherwise `nil` so the caller takes the conversion path.
    ///
    /// Equivalence with the old code: the legacy fast path copied
    /// `ptr[frame * sourceChannels + min(channel, sourceChannels - 1)]` for
    /// `frames = availableSamples / sourceChannels` frames. When
    /// `sourceChannels == outputChannels` that index reduces to
    /// `ptr[frame * outputChannels + channel]`, i.e. a verbatim copy of the
    /// leading `frames * outputChannels` floats, with any partial-frame
    /// remainder dropped. We reproduce that exactly: same frame count, same
    /// leading bytes.
    private func directFloat32SampleBuffer(
        from audioBufferList: UnsafePointer<AudioBufferList>,
        inputTime: AudioTimeStamp?
    ) throws -> CMSampleBuffer? {
        let sourceChannels = max(Int(sourceFormat.mChannelsPerFrame), 1)
        let outputChannels = Int(outputFormat.mChannelsPerFrame)
        guard outputChannels > 0, sourceChannels == outputChannels else { return nil }

        let sourceIsFloat = (sourceFormat.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let sourceIsNonInterleaved = (sourceFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        guard sourceIsFloat, sourceFormat.mBitsPerChannel == 32, !sourceIsNonInterleaved else { return nil }

        let buffers = CoreAudioBufferListView(audioBufferList)
        guard buffers.count == 1, let data = buffers[0].mData else { return nil }

        let availableSamples = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
        let frameCount = availableSamples / sourceChannels
        guard frameCount > 0 else { return nil }

        let ptsFrame = advancePTS(frameCount: frameCount, inputTime: inputTime)
        let byteCount = frameCount * outputChannels * MemoryLayout<Float>.stride
        return try makeCMSampleBuffer(
            bytes: data,
            byteCount: byteCount,
            frameCount: frameCount,
            ptsFrame: ptsFrame
        )
    }

    /// Fills `scratchSamples` with the interleaved float32 conversion of the
    /// source buffers (non-interleaved / multi-buffer float32, or any int16
    /// source, or float32 with a channel-count mismatch) and returns the count
    /// of valid leading elements. Reuses the scratch storage across calls; only
    /// the returned prefix is meaningful. Behaviour matches the previous
    /// per-call `[Float]` allocation element-for-element.
    private func fillScratch(
        from audioBufferList: UnsafePointer<AudioBufferList>
    ) throws -> Int {
        let buffers = CoreAudioBufferListView(audioBufferList)
        guard !buffers.isEmpty else { return 0 }
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
                guard frameCount > 0 else { return 0 }
                let total = frameCount * outputChannels
                reserveScratch(total)
                return scratchSamples.withUnsafeMutableBufferPointer { samples -> Int in
                    // The old code allocated a zero-filled `[Float]`, so a channel
                    // whose source buffer is nil stayed silent. The reused scratch
                    // may hold stale data, so clear the meaningful prefix first.
                    if let baseAddress = samples.baseAddress {
                        memset(baseAddress, 0, total * MemoryLayout<Float>.size)
                    }
                    for channel in 0..<outputChannels {
                        let bufferIndex = min(channel, buffers.count - 1)
                        guard let data = buffers[bufferIndex].mData else { continue }
                        let ptr = data.assumingMemoryBound(to: Float.self)
                        if outputChannels == 1 {
                            // Contiguous destination: straight copy.
                            memcpy(samples.baseAddress!, ptr, frameCount * MemoryLayout<Float>.size)
                        } else {
                            // Scatter channel `channel` into the interleaved layout.
                            for frame in 0..<frameCount {
                                samples[frame * outputChannels + channel] = ptr[frame]
                            }
                        }
                    }
                    return total
                }
            }

            // Single interleaved buffer that did NOT match the fast path, i.e.
            // sourceChannels != outputChannels: keep the scalar remap.
            guard let data = buffers[0].mData else { return 0 }
            let availableSamples = Int(buffers[0].mDataByteSize) / MemoryLayout<Float>.size
            let frames = availableSamples / sourceChannels
            guard frames > 0 else { return 0 }
            let total = frames * outputChannels
            reserveScratch(total)
            let ptr = data.assumingMemoryBound(to: Float.self)
            return scratchSamples.withUnsafeMutableBufferPointer { samples -> Int in
                for frame in 0..<frames {
                    for channel in 0..<outputChannels {
                        samples[frame * outputChannels + channel] = ptr[frame * sourceChannels + min(channel, sourceChannels - 1)]
                    }
                }
                return total
            }
        }

        if sourceFormat.mBitsPerChannel == 16 {
            if sourceIsNonInterleaved || buffers.count > 1 {
                let frameCount = minimumFrameCount(
                    in: buffers,
                    bytesPerSample: MemoryLayout<Int16>.size
                )
                guard frameCount > 0 else { return 0 }
                let total = frameCount * outputChannels
                reserveScratch(total)
                return scratchSamples.withUnsafeMutableBufferPointer { samples -> Int in
                    // Same stale-scratch guard as the float32 multi-buffer path:
                    // a nil source buffer must read back as silence, not leftovers.
                    if let baseAddress = samples.baseAddress {
                        memset(baseAddress, 0, total * MemoryLayout<Float>.size)
                    }
                    for channel in 0..<outputChannels {
                        let bufferIndex = min(channel, buffers.count - 1)
                        guard let data = buffers[bufferIndex].mData else { continue }
                        let ptr = data.assumingMemoryBound(to: Int16.self)
                        if outputChannels == 1 {
                            // Contiguous destination: vectorised Int16 -> Float / 32768.
                            convertInt16ToFloat(source: ptr, destination: samples.baseAddress!, count: frameCount)
                        } else {
                            for frame in 0..<frameCount {
                                samples[frame * outputChannels + channel] = Float(ptr[frame]) / 32768.0
                            }
                        }
                    }
                    return total
                }
            }

            guard let data = buffers[0].mData else { return 0 }
            let availableSamples = Int(buffers[0].mDataByteSize) / MemoryLayout<Int16>.size
            let frames = availableSamples / sourceChannels
            guard frames > 0 else { return 0 }
            let total = frames * outputChannels
            reserveScratch(total)
            let ptr = data.assumingMemoryBound(to: Int16.self)
            return scratchSamples.withUnsafeMutableBufferPointer { samples -> Int in
                for frame in 0..<frames {
                    for channel in 0..<outputChannels {
                        samples[frame * outputChannels + channel] = Float(ptr[frame * sourceChannels + min(channel, sourceChannels - 1)]) / 32768.0
                    }
                }
                return total
            }
        }

        throw CoreAudioStatusError(operation: "Unsupported tap format bytesPerSample=\(bytesPerSample)", status: -1)
    }

    /// Grows `scratchSamples` to at least `count` elements without shrinking it.
    /// New tail elements are zero, but only the prefix the caller fills + returns
    /// is ever read downstream.
    private func reserveScratch(_ count: Int) {
        if scratchSamples.count < count {
            scratchSamples.append(contentsOf: repeatElement(0, count: count - scratchSamples.count))
        }
    }

    /// Vectorised `Int16 -> Float / 32768.0` matching the scalar `Float(x) / 32768.0`.
    /// `vDSP_vflt16` widens to Float, then `vDSP_vsdiv` divides by 32768. The
    /// result is bit-identical to the scalar form because both operands are
    /// exactly representable and IEEE division is deterministic.
    private func convertInt16ToFloat(
        source: UnsafePointer<Int16>,
        destination: UnsafeMutablePointer<Float>,
        count: Int
    ) {
        guard count > 0 else { return }
        vDSP_vflt16(source, 1, destination, 1, vDSP_Length(count))
        var divisor: Float = 32768.0
        vDSP_vsdiv(destination, 1, &divisor, destination, 1, vDSP_Length(count))
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

    /// Builds the output `CMSampleBuffer` by copying exactly `byteCount` bytes
    /// starting at `bytes` into a fresh CMBlockBuffer. The single copy is the
    /// same `CMBlockBufferReplaceDataBytes` the previous implementation used; the
    /// only change is that the source is now a raw pointer (the source tap buffer
    /// in the fast path, or the reused scratch in the conversion path) instead of
    /// a freshly allocated `[Float]`.
    private func makeCMSampleBuffer(
        bytes: UnsafeRawPointer,
        byteCount: Int,
        frameCount: Int,
        ptsFrame: Int64
    ) throws -> CMSampleBuffer {
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

        status = CMBlockBufferReplaceDataBytes(
            with: bytes,
            blockBuffer: blockBuffer,
            offsetIntoDestination: 0,
            dataLength: byteCount
        )
        guard status == kCMBlockBufferNoErr else {
            throw CoreAudioStatusError(operation: "CMBlockBufferReplaceDataBytes", status: status)
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
