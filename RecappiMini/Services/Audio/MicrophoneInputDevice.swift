import AVFoundation

struct MicrophoneInputDevice: Identifiable, Hashable, Sendable {
    static let systemDefaultID = ""
    static let systemDefaultPlaceholder = MicrophoneInputDevice(
        id: Self.systemDefaultID,
        title: "System Default",
        isUnavailable: false
    )

    let id: String
    let title: String
    let isUnavailable: Bool

    static func pickerOptions(selectedID: String) -> [MicrophoneInputDevice] {
        let selectedID = selectedID.trimmingCharacters(in: .whitespacesAndNewlines)
        let devices = availableDevices()
            .sorted { lhs, rhs in
                lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
            }

        var options = [systemDefaultOption(defaultDevice: AVCaptureDevice.default(for: .audio))]
        var seenIDs = Set([Self.systemDefaultID])

        for device in devices where seenIDs.insert(device.uniqueID).inserted {
            options.append(
                MicrophoneInputDevice(
                    id: device.uniqueID,
                    title: device.localizedName,
                    isUnavailable: false
                )
            )
        }

        if !selectedID.isEmpty, !seenIDs.contains(selectedID) {
            options.insert(
                MicrophoneInputDevice(
                    id: selectedID,
                    title: "Unavailable microphone",
                    isUnavailable: true
                ),
                at: min(1, options.count)
            )
        }

        return options
    }

    static func pickerOptionsAsync(selectedID: String) async -> [MicrophoneInputDevice] {
        await Task.detached(priority: .utility) {
            pickerOptions(selectedID: selectedID)
        }.value
    }

    static func warmDeviceCache() {
        _ = AVCaptureDevice.default(for: .audio)
        _ = availableDevices().count
    }

    static func captureDevice(preferredUniqueID: String) -> AVCaptureDevice? {
        let preferredUniqueID = preferredUniqueID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preferredUniqueID.isEmpty,
           let preferred = availableDevices().first(where: { $0.uniqueID == preferredUniqueID }) {
            return preferred
        }

        return AVCaptureDevice.default(for: .audio)
    }

    static func deviceIsAvailable(uniqueID: String) -> Bool {
        let uniqueID = uniqueID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uniqueID.isEmpty else { return AVCaptureDevice.default(for: .audio) != nil }
        return availableDevices().contains(where: { $0.uniqueID == uniqueID })
    }

    private static func systemDefaultOption(defaultDevice: AVCaptureDevice?) -> MicrophoneInputDevice {
        let suffix = defaultDevice.map { " (\($0.localizedName))" } ?? ""
        return MicrophoneInputDevice(
            id: Self.systemDefaultID,
            title: "\(Self.systemDefaultPlaceholder.title)\(suffix)",
            isUnavailable: false
        )
    }

    private static func availableDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }
}
