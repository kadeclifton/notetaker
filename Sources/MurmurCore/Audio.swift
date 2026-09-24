import Foundation

public enum Audio {
    /// Whisper wants 16 kHz mono.
    public static let sampleRate = 16_000

    /// Encodes Float samples in -1...1 as a 16-bit PCM mono WAV file.
    public static func wav(samples: [Float], sampleRate: Int = Audio.sampleRate) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16))              // fmt chunk size
        append(UInt16(1))               // PCM
        append(UInt16(1))               // mono
        append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2))  // byte rate
        append(UInt16(2))               // block align
        append(UInt16(16))              // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(dataSize))
        var pcm = [Int16](repeating: 0, count: samples.count)
        for (i, s) in samples.enumerated() {
            let clamped = max(-1, min(1, s.isFinite ? s : 0))
            pcm[i] = Int16((clamped * Float(Int16.max)).rounded())
        }
        pcm.withUnsafeBufferPointer { buffer in
            for sample in buffer { append(sample) }
        }
        return data
    }

    public static func duration(of samples: [Float], sampleRate: Int = Audio.sampleRate) -> TimeInterval {
        Double(samples.count) / Double(sampleRate)
    }

    public static func rms<C: Collection>(_ samples: C) -> Float where C.Element == Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// True when no 50 ms window rises above `threshold` RMS (about -56 dBFS). Whisper invents text
    /// ("Thank you.") for silence, so silent clips are not sent at all. Low enough for a webcam
    /// mic across a desk; a room with nobody talking stays under it.
    public static func isSilent(_ samples: [Float], threshold: Float = 0.0015, sampleRate: Int = Audio.sampleRate) -> Bool {
        let window = max(1, sampleRate / 20)
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + window)
            if rms(samples[start..<end]) > threshold { return false }
            start = end
        }
        return true
    }

    /// Brings quiet speech (a webcam or display mic across the room) up to a level Whisper hears
    /// well: the loudest 50 ms window is raised to about -20 dBFS, at most 20× (+26 dB), without
    /// clipping. Speech that is already loud enough is returned unchanged.
    public static func boosted(_ samples: [Float], sampleRate: Int = Audio.sampleRate) -> [Float] {
        let window = max(1, sampleRate / 20)
        var loudest: Float = 0
        var peak: Float = 0
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + window)
            loudest = max(loudest, rms(samples[start..<end]))
            start = end
        }
        for s in samples { peak = max(peak, abs(s)) }
        let target: Float = 0.1
        guard loudest > 0, loudest < target / 2, peak > 0 else { return samples }
        let gain = min(20, target / loudest, 0.98 / peak)
        guard gain > 1.05 else { return samples }
        return samples.map { $0 * gain }
    }
}
