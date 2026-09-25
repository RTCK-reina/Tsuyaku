import Foundation
import CoreAudio

/// Enumerates Core Audio input devices and tracks the user's selection.
/// Stateless namespace — only static CoreAudio queries, trivially Sendable.
final class AudioDeviceManager: Sendable {

    struct InputDevice: Identifiable, Hashable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let sampleRate: Double

        var displayName: String { name }
    }

    /// Special marker meaning "follow the system default input".
    static let defaultDeviceUID = "__system_default__"

    /// List all devices that have at least one input channel.
    static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize
        ) == noErr else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { id in
            guard inputChannelCount(for: id) > 0,
                  let uid = stringProperty(device: id, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(device: id, selector: kAudioDevicePropertyDeviceNameCFString)
            else { return nil }
            let rate = nominalSampleRate(for: id) ?? 48000
            return InputDevice(id: id, uid: uid, name: name, sampleRate: rate)
        }
    }

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
        ) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        let devices = inputDevices()
        return devices.first(where: { $0.uid == uid })?.id
    }

    static func deviceUID(forID id: AudioDeviceID) -> String? {
        stringProperty(device: id, selector: kAudioDevicePropertyDeviceUID)
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        ) == noErr, deviceID != 0 else { return nil }
        return deviceID
    }

    // MARK: - Helpers

    private static func stringProperty(device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if selector == kAudioDevicePropertyDeviceNameCFString || selector == kAudioDevicePropertyDeviceUID {
            var value: CFString = "" as CFString
            var size = UInt32(MemoryLayout<CFString>.size)
            let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
            return status == noErr ? value as String : nil
        }
        return nil
    }

    static func inputChannelCount(for device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let bufferList = raw.assumingMemoryBound(to: AudioBufferList.self)
        var channels = 0
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        for buffer in buffers {
            channels += Int(buffer.mNumberChannels)
        }
        return channels
    }

    private static func nominalSampleRate(for device: AudioDeviceID) -> Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }
}
