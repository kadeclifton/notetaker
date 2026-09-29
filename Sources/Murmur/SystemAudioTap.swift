#if os(macOS)
import AVFoundation
import CoreAudio
import MurmurCore

/// Where a meeting's "Others" audio comes from: a Core Audio tap on macOS 14.2 and later, and
/// ScreenCaptureKit before that.
protocol CallAudioSource: AnyObject, Sendable {
    func start() async throws
    func stop() async
    /// Everything captured since the last call.
    func takeRecorded() -> [Float]
    /// Called on a background queue if capture stops by itself.
    var onStop: (@Sendable (Error) -> Void)? { get set }
}

extension SystemAudioCapture: CallAudioSource {}

enum SystemAudioTapError: Error, CustomStringConvertible {
    case failed(String, OSStatus)

    var description: String {
        switch self {
        case let .failed(step, status):
            return "Call audio could not start (\(step), error \(status)). Allow Murmur in System Settings → Privacy & "
                + "Security → Screen & System Audio Recording, then restart it."
        }
    }
}

/// Records everything this Mac plays, except Murmur's own sounds, through a Core Audio process tap,
/// as 16 kHz mono. Unlike ScreenCaptureKit, a tap hears calls whose audio comes from a system
/// service rather than an app window: FaceTime (avconferenced) and iPhone calls taken on the Mac.
/// macOS asks once for System Audio Recording; if it is refused, the tap delivers silence, which the
/// meeting notes then point out.
@available(macOS 14.2, *)
final class SystemAudioTap: CallAudioSource, @unchecked Sendable {
    /// Start and stop run here; the audio callback runs on `ioQueue`, so stopping never waits on itself.
    private let queue = DispatchQueue(label: "Murmur.SystemAudioTap")
    private let ioQueue = DispatchQueue(label: "Murmur.SystemAudioTap.io", qos: .userInitiated)
    private let resampler = Resampler()
    private let buffer = SampleBuffer()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    var onStop: (@Sendable (Error) -> Void)?

    func start() async throws {
        try queue.sync { try startOnQueue() }
    }

    func stop() async {
        queue.sync { tearDown() }
    }

    func takeRecorded() -> [Float] { buffer.drain() }

    private func startOnQueue() throws {
        guard procID == nil else { return }
        do {
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [NSNumber(value: $0)] } ?? [])
            description.uuid = UUID()
            description.name = "Murmur call audio"
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tapID), "tap")

            var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                           mScope: kAudioObjectPropertyScopeGlobal,
                                                           mElement: kAudioObjectPropertyElementMain)
            var streamDescription = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &size, &streamDescription), "tap format")
            guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
                throw SystemAudioTapError.failed("tap format", -1)
            }

            // A private aggregate device clocked by the current output, with the tap as its input.
            var device: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Murmur Call Audio",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceTapListKey: [[
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: description.uuid.uuidString,
                ]],
            ]
            if let output = Self.defaultOutputUID() {
                device[kAudioAggregateDeviceMainSubDeviceKey] = output
                device[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
            }
            try check(AudioHardwareCreateAggregateDevice(device as CFDictionary, &aggregateID), "aggregate device")

            let resampler = self.resampler
            let sink = buffer
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) { _, input, _, _, _ in
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
                let samples = resampler.convert(pcm)
                samples.withUnsafeBufferPointer { sink.append($0) }
            }, "audio callback")
            try check(AudioDeviceStart(aggregateID, procID), "start")
        } catch {
            tearDown()
            throw error
        }
    }

    private func tearDown() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func check(_ status: OSStatus, _ step: String) throws {
        if status != noErr { throw SystemAudioTapError.failed(step, status) }
    }

    /// Murmur's own Core Audio process object, so its sounds stay out of the recording.
    private static func ownProcessObject() -> AudioObjectID? {
        var pid = ProcessInfo.processInfo.processIdentifier
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
#endif
