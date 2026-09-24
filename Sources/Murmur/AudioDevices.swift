#if os(macOS)
import CoreAudio
import Foundation

/// A microphone Core Audio knows about.
struct InputDevice: Equatable {
    var id: AudioDeviceID
    /// Stable across restarts and replugging; what the choice is saved as.
    var uid: String
    var name: String
}

/// The Mac's microphones, and which one Murmur should use. "System default" follows the Sound
/// setting; a specific pick sticks even when the default changes (a webcam in clamshell mode, a
/// headset that grabs the default when it connects).
enum AudioDevices {
    static let preferenceKey = "microphoneUID"

    /// The picked microphone's UID, or nil for the system default.
    static var preferredUID: String? {
        get { UserDefaults.standard.string(forKey: preferenceKey) }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }

    /// Every device with input channels, in Core Audio's order.
    static func inputs() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(of: id) > 0,
                  let uid = string(kAudioDevicePropertyDeviceUID, of: id),
                  let name = string(kAudioObjectPropertyName, of: id) else { return nil }
            return InputDevice(id: id, uid: uid, name: name)
        }
    }

    /// The Sound setting's input device.
    static func systemDefault() -> InputDevice? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return inputs().first { $0.id == id }
    }

    /// The device to record from: the picked one if it is plugged in, else the system default.
    static func current() -> InputDevice? {
        if let uid = preferredUID, let picked = inputs().first(where: { $0.uid == uid }) { return picked }
        return systemDefault()
    }

    private static func inputChannels(of id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ selector: AudioObjectPropertySelector, of id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
#endif
