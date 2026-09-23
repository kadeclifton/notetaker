#if os(macOS)
import AVFoundation
import CoreMedia
import ScreenCaptureKit
import MurmurCore

enum SystemAudioError: Error, CustomStringConvertible {
    case noDisplay
    case permission(String)

    var description: String {
        switch self {
        case .noDisplay:
            return "No display found to capture audio from."
        case let .permission(detail):
            return "Call audio needs Screen & System Audio Recording permission (\(detail)). Allow Murmur in System Settings, then restart it."
        }
    }
}

/// Records the audio playing on this Mac (the other people on a call) through ScreenCaptureKit,
/// as 16 kHz mono. Murmur's own sounds are excluded.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "Murmur.SystemAudio", qos: .userInitiated)
    private let resampler = Resampler()
    private let buffer = SampleBuffer()
    /// End of the last buffer, to fill gaps with silence so timestamps stay aligned with the mic.
    private var lastEnd: CMTime?

    /// Called on a background queue if the stream stops by itself.
    var onStop: (@Sendable (Error) -> Void)?

    func start() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw SystemAudioError.permission(error.localizedDescription)
        }
        guard let display = content.displays.first else { throw SystemAudioError.noDisplay }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 1
        // The stream always carries video; keep it tiny and at one frame per second, and ignore it.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    /// Everything captured since the last call.
    func takeRecorded() -> [Float] { buffer.drain() }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = Self.pcmBuffer(from: sampleBuffer) else { return }

        // ScreenCaptureKit may skip stretches of silence; pad them so 10 minutes of audio
        // still means 10 minutes of meeting.
        let start = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if let lastEnd, start.isValid, lastEnd.isValid {
            let gap = CMTimeGetSeconds(CMTimeSubtract(start, lastEnd))
            if gap > 0.05 && gap < 3600 {
                let silence = [Float](repeating: 0, count: Int(gap * Double(Audio.sampleRate)))
                silence.withUnsafeBufferPointer { buffer.append($0) }
            }
        }
        if start.isValid {
            lastEnd = CMTimeAdd(start, CMSampleBufferGetDuration(sampleBuffer))
        }

        let samples = resampler.convert(pcm)
        samples.withUnsafeBufferPointer { buffer.append($0) }
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onStop?(error)
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        var asbd = basic.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        pcm.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                 into: pcm.mutableAudioBufferList)
        return status == noErr ? pcm : nil
    }
}
#endif
