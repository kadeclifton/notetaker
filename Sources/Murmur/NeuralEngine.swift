#if os(macOS)
import Foundation
import MurmurCore

/// Downloads and unpacks a model's Core ML encoder next to it, which is all the bundled
/// whisper.cpp needs to run that part on the Neural Engine. Removing it goes back to the GPU.
@MainActor
final class CoreMLInstaller: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(progress: Double)
        case unpacking
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var session: URLSession?
    private var model = ""
    private var done: (@MainActor (Bool) -> Void)?

    var isBusy: Bool {
        switch state {
        case .downloading, .unpacking: return true
        case .idle, .failed: return false
        }
    }

    func install(_ option: WhisperModelOption, forModel model: String, then done: @escaping @MainActor (Bool) -> Void) {
        guard !isBusy else { return }
        self.model = model
        self.done = done
        state = .downloading(progress: 0)
        let delegate = CoreMLDownloadDelegate(expectedBytes: Int64(option.coreMLMegabytes) * 1_000_000, owner: self)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: option.coreMLURL).resume()
    }

    func cancel() {
        session?.invalidateAndCancel()
        session = nil
        done = nil
        if isBusy { state = .idle }
    }

    static func remove(forModel model: String) throws {
        let path = CoreMLEncoder.path(forModel: model)
        if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
    }

    fileprivate func progressed(_ fraction: Double) {
        guard case .downloading = state else { return }
        state = .downloading(progress: fraction)
    }

    fileprivate func downloaded(_ zip: URL?, error: String?) {
        session?.finishTasksAndInvalidate()
        session = nil
        guard let zip, error == nil else {
            finish(ok: false, failure: "Neural Engine download failed: \(error ?? "no file").")
            return
        }
        state = .unpacking
        let model = self.model
        Task { [weak self] in
            do {
                try await Self.unpack(zip, forModel: model)
                self?.finish(ok: true, failure: nil)
            } catch {
                self?.finish(ok: false, failure: "Could not unpack the Core ML encoder: \(error)")
            }
        }
    }

    private func finish(ok: Bool, failure: String?) {
        state = failure.map(State.failed) ?? .idle
        let done = self.done
        self.done = nil
        done?(ok)
    }

    /// Unzips into a scratch folder first, so a half-unpacked encoder is never picked up.
    private static func unpack(_ zip: URL, forModel model: String) async throws {
        defer { try? FileManager.default.removeItem(at: zip) }
        let destination = URL(fileURLWithPath: CoreMLEncoder.path(forModel: model))
        let scratch = destination.deletingLastPathComponent().appendingPathComponent(".coreml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let result = try await ProcessRunner.run("/usr/bin/ditto", arguments: ["-x", "-k", zip.path, scratch.path])
        guard result.status == 0 else { throw InstallError("ditto: \(result.stderr)") }
        guard let unpacked = try FileManager.default.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "mlmodelc" }) else { throw InstallError("the zip has no .mlmodelc") }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: unpacked, to: destination)
    }
}

/// Runs on URLSession's queue; keeps the downloaded file (it is deleted when the callback
/// returns) and reports back on main.
private final class CoreMLDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let expectedBytes: Int64
    weak var owner: CoreMLInstaller?
    private var kept: URL?
    private var failure: String?

    init(expectedBytes: Int64, owner: CoreMLInstaller) {
        self.expectedBytes = expectedBytes
        self.owner = owner
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expectedBytes
        let fraction = min(1, Double(totalBytesWritten) / Double(max(expected, 1)))
        let owner = self.owner
        DispatchQueue.main.async {
            MainActor.assumeIsolated { owner?.progressed(fraction) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw InstallError("the server answered HTTP \(http.statusCode)")
            }
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
            guard size > 1_000_000 else { throw InstallError("the download was incomplete") }
            let kept = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-coreml-\(UUID().uuidString).zip")
            try FileManager.default.moveItem(at: location, to: kept)
            self.kept = kept
        } catch {
            failure = "\(error)"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if (error as? URLError)?.code == .cancelled { return }
        let message = error.map { $0.localizedDescription } ?? failure
        let kept = self.kept
        let owner = self.owner
        DispatchQueue.main.async {
            MainActor.assumeIsolated { owner?.downloaded(kept, error: message) }
        }
    }
}

private struct InstallError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
#endif
