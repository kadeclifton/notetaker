#if os(macOS)
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

/// Captures the default input device as 16 kHz mono Float samples.
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

    /// Everything recorded since the last call, without stopping. Meeting notes read the mic this way.
    func takeRecorded() -> [Float] { buffer.drain() }

    func start(completion: @escaping @MainActor (Error?) -> Void) {
        queue.async { [self] in
            // Reset on the queue, after any earlier stop() has drained its samples.
            buffer.reset()
            let error: Error?
            do {
                try startOnQueue()
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
            if let engine {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
                self.engine = nil
            }
            let samples = buffer.drain()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(samples) } }
        }
    }

    private func startOnQueue() throws {
        guard engine == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecorderError.microphoneDenied
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
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

    var level: Float { lock.withLock { _level } }

    func reset() {
        lock.withLock {
            samples = []
            samples.reserveCapacity(Audio.sampleRate * 60)
            _level = 0
        }
    }

    func append(_ chunk: UnsafeBufferPointer<Float>) {
        let rms = Audio.rms(chunk)
        // Speech RMS sits around 0.02-0.2; map it onto 0...1 on a log-ish curve.
        let normalized = min(1, max(0, (20 * log10(max(rms, 1e-6)) + 50) / 40))
        lock.withLock {
            samples.append(contentsOf: chunk)
            _level = max(normalized, _level * 0.6)
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
