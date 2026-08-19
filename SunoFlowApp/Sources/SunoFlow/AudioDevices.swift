import CoreAudio
import Foundation

/// A selectable microphone input device.
struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    /// Recording from a Bluetooth mic forces the headset into low-quality call
    /// (HFP) mode, degrading audio output in every app — so we flag it.
    let isBluetooth: Bool
}

/// Thin Core Audio wrapper to list input devices and resolve a saved device UID
/// back to a live `AudioDeviceID` at record time (IDs are not stable across
/// reboots / re-plugs, UIDs are).
enum AudioDevices {
    static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr, dataSize > 0 else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &ids
        ) == noErr else {
            return []
        }

        return ids.compactMap { id in
            guard inputChannelCount(id) > 0,
                  let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName)
            else { return nil }
            let transport = transportType(id)
            let isBluetooth = transport == kAudioDeviceTransportTypeBluetooth
                || transport == kAudioDeviceTransportTypeBluetoothLE
            return AudioInputDevice(id: id, uid: uid, name: name, isBluetooth: isBluetooth)
        }
    }

    /// Resolve a saved device UID to its current `AudioDeviceID`, if still present.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return inputDevices().first { $0.uid == uid }?.id
    }

    /// UID of the system default input device, if resolvable.
    static func defaultInputUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else {
            return nil
        }
        return stringProperty(deviceID, kAudioDevicePropertyDeviceUID)
    }

    /// UID of the built-in (MacBook) microphone, if present — the safe choice
    /// that never pulls a Bluetooth headset into call mode.
    static func builtInInputUID() -> String? {
        inputDevices().first { transportType($0.id) == kAudioDeviceTransportTypeBuiltIn }?.uid
    }

    /// The system default input device id, or nil.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else {
            return nil
        }
        return deviceID
    }

    /// Set the system default input device. AVAudioEngine records from the default
    /// input, so this is the reliable way to steer capture to a specific mic —
    /// unlike overriding the input node's audio unit, which fails to re-bind away
    /// from a Bluetooth default. Returns true on success.
    @discardableResult
    static func setDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = deviceID
        return AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &device
        ) == noErr
    }

    /// Would the mic actually used for recording be Bluetooth? Resolves an empty
    /// saved UID ("system default") to the real default device, so this also
    /// catches the case where the system default silently *is* the earbuds.
    static func effectiveInputIsBluetooth(savedUID: String) -> Bool {
        let devices = inputDevices()
        let targetUID = savedUID.isEmpty ? (defaultInputUID() ?? "") : savedUID
        return devices.first { $0.uid == targetUID }?.isBluetooth ?? false
    }

    // MARK: - Property helpers

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // These selectors hand back a +1-retained CFString, so take ownership
        // with takeRetainedValue to balance the retain.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let value else {
            return nil
        }
        return value.takeRetainedValue() as String
    }

    private static func transportType(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else {
            return 0
        }
        return transport
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let bufferList = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufferList) == noErr else {
            return 0
        }
        let list = UnsafeMutableAudioBufferListPointer(
            bufferList.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
