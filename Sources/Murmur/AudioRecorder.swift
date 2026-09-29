#if os(macOS)
import AudioToolbox
import AVFoundation
import MurmurCore

enum RecorderError: Error, CustomStringConvertible {
    case microphoneDenied
    case noInputDevice
    case converterUnavailable

    var description: String {
        switch self {
        case .microphoneDenied: return "Microphone access is off. Allow Murmur in System Settings → Privacy & Security → Microphone."
        case .noInputDevice: return "No microphone found."
        case .converterUnavailable: return "Could not convert microphone audio to 16 kHz."
        }
    }
}

/// Captures the microphone picked in the menu (or the system default) as 16 kHz mono Float samples.
/// A fresh AVAudioEngine per recording picks up whatever mic is current (AirPods, USB, built-in).
///
/// Starting an engine can take hundreds of milliseconds on Bluetooth or USB mics, so start and
/// stop run on a private serial queue (in the order they were called) and report back on main.
final class AudioRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Murmur.AudioRecorder", qos: .userInitiated)
    private var engine: AVAudioEngine? // only touched on `queue`
    private let buffer = SampleBuffer()

    /// Recent loudness, roughly 0...1, for the pill's level meter.
    var level: Float { buffer.level }

    private let nameLock = NSLock()
    private var _deviceName: String?
    /// The microphone the last recording used, for messages like "No sound from …".
    var deviceName: String? { nameLock.withLock { _deviceName } }

    /// Everything recorded since the last call, without stopping. Meeting notes read the mic this way.
    func takeRecorded() -> [Float] { buffer.drain() }

    /// For a whole meeting. When a call app switches the mic to voice processing (FaceTime does),
    /// macOS reconfigures it and this engine stops delivering audio without any error. With this on,
    /// the recorder starts again when that happens, or when no audio has come for a few seconds, and
    /// fills the gap with silence so the transcript's times stay right. Set before `start`.
    var keepsRunning = false
    private var wantsRunning = false // only touched on `queue`
    private var configObserver: NSObjectProtocol? // only touched on `queue`
    private var watchdog: DispatchSourceTimer? // only touched on `queue`

    func start(completion: @escaping @MainActor (Error?) -> Void) {
        queue.async { [self] in
            // Reset on the queue, after any earlier stop() has drained its samples.
            buffer.reset()
            let error: Error?
            do {
                try startOnQueue()
                wantsRunning = keepsRunning
                if keepsRunning { startWatchdog() }
                error = nil
            } catch let failure {
                error = failure
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(error) } }
        }
    }

    /// Stops the microphone and hands back everything recorded since `start`.
    func stop(completion: @escaping @MainActor ([Float]) -> Void) {
        queue.async { [self] in
            wantsRunning = false
            watchdog?.cancel()
            watchdog = nil
            stopEngine()
            let samples = buffer.drain()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(samples) } }
        }
    }

    private func stopEngine() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            self.engine = nil
        }
    }

    /// Starts a fresh engine after the mic went quiet or was reconfigured, padding the gap.
    private func restartOnQueue() {
        guard wantsRunning else { return }
        stopEngine()
        buffer.padGap()
        // If the mic cannot start yet (the call app still holds it), the watchdog tries again.
        try? startOnQueue()
    }

    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.wantsRunning else { return }
            if self.engine == nil || self.buffer.secondsSinceAppend > 3 { self.restartOnQueue() }
        }
        timer.resume()
        watchdog = timer
    }

    private func startOnQueue() throws {
        guard engine == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecorderError.microphoneDenied
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Point the engine at the chosen mic before reading its format. With nothing picked it
        // follows the system default, as it always did.
        let device = AudioDevices.current()
        if AudioDevices.preferredUID != nil, let device, let unit = input.audioUnit {
            var id = device.id
            AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                 &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        }
        nameLock.withLock { _deviceName = device?.name }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.noInputDevice
        }
        let resampler = Resampler()
        let sink = buffer
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { pcm, _ in
            // Audio thread. Convert this chunk and append it.
            let samples = resampler.convert(pcm)
            samples.withUnsafeBufferPointer { sink.append($0) }
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        if keepsRunning {
            configObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
                guard let self else { return }
                self.queue.async { self.restartOnQueue() }
            }
        }
    }
}

/// Converts whatever the device delivers (48 kHz stereo, 44.1 kHz, ...) to 16 kHz mono Float.
/// Keeps its converter between calls so the resampling stays continuous.
final class Resampler: @unchecked Sendable {
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Audio.sampleRate),
                                       channels: 1, interleaved: false)!
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?

    func convert(_ pcm: AVAudioPCMBuffer) -> [Float] {
        if inputFormat != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: target)
            converter?.downmix = true
            inputFormat = pcm.format
        }
        guard let converter, pcm.frameLength > 0 else { return [] }
        let ratio = target.sampleRate / pcm.format.sampleRate
        let capacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return pcm
        }
        guard status != .error, let channel = out.floatChannelData?[0], out.frameLength > 0 else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}

/// Thread-safe sample accumulator shared with the audio thread.
final class SampleBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private var _level: Float = 0
    private var lastAppend = DispatchTime.now()

    var level: Float { lock.withLock { _level } }

    /// Seconds since audio last arrived (or since `reset`).
    var secondsSinceAppend: Double {
        lock.withLock { Double(DispatchTime.now().uptimeNanoseconds - lastAppend.uptimeNanoseconds) / 1e9 }
    }

    func reset() {
        lock.withLock {
            samples = []
            samples.reserveCapacity(Audio.sampleRate * 60)
            _level = 0
            lastAppend = .now()
        }
    }

    /// Fills the time since audio last arrived with silence, so what follows lands at the right time.
    func padGap() {
        lock.withLock {
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - lastAppend.uptimeNanoseconds) / 1e9
            if seconds > 0.1, seconds < 3600 {
                samples.append(contentsOf: repeatElement(0, count: Int(seconds * Double(Audio.sampleRate))))
            }
            lastAppend = .now()
        }
    }

    func append(_ chunk: UnsafeBufferPointer<Float>) {
        let rms = Audio.rms(chunk)
        // Speech RMS sits around 0.02-0.2; map it onto 0...1 on a log-ish curve.
        let normalized = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 40))
        lock.withLock {
            samples.append(contentsOf: chunk)
            _level = max(normalized, _level * 0.6)
            lastAppend = .now()
        }
    }

    func drain() -> [Float] {
        lock.withLock {
            let out = samples
            samples = []
            _level = 0
            return out
        }
    }
}
#endif
