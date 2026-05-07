import CoreAudio
import Foundation

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
