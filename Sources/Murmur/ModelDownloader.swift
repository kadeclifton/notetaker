#if os(macOS)
import Foundation
import MurmurCore

/// Downloads a Whisper model into ~/.config/murmur/models with progress, for the setup window
/// and Settings. One download at a time.
@MainActor
final class ModelDownloader: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(WhisperModelOption, progress: Double)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    /// Called on the main actor when a model has been saved.
    var onFinished: ((WhisperModelOption) -> Void)?

    private var session: URLSession?
    private var task: URLSessionDownloadTask?

    var isDownloading: Bool {
        if case .downloading = state { return true }
        return false
    }

    func download(_ option: WhisperModelOption) {
        guard !isDownloading else { return }
        state = .downloading(option, progress: 0)
        let delegate = DownloadDelegate(option: option, owner: self)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        self.session = session
        task = session.downloadTask(with: option.url)
        task?.resume()
    }

    func cancel() {
        task?.cancel()
        finish(.idle)
    }

    fileprivate func progressed(_ option: WhisperModelOption, fraction: Double) {
        guard case .downloading = state else { return }
        state = .downloading(option, progress: fraction)
    }

    fileprivate func completed(_ option: WhisperModelOption, error: String?) {
        if let error {
            finish(.failed(error))
        } else {
            finish(.idle)
            onFinished?(option)
        }
    }

    private func finish(_ newState: State) {
        state = newState
        session?.finishTasksAndInvalidate()
        session = nil
        task = nil
    }
}

/// URLSession's delegate runs on a background queue; it moves the file into place there
/// (the temporary file is deleted as soon as the callback returns) and reports back on main.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let option: WhisperModelOption
    weak var owner: ModelDownloader?
    private var moveError: String?

    init(option: WhisperModelOption, owner: ModelDownloader) {
        self.option = option
        self.owner = owner
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Int64(option.megabytes) * 1_000_000
        let fraction = min(1, Double(totalBytesWritten) / Double(expected))
        let option = self.option
        let owner = self.owner
        DispatchQueue.main.async {
            MainActor.assumeIsolated { owner?.progressed(option, fraction: fraction) }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let destination = option.localURL()
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw DownloadError("the server answered HTTP \(http.statusCode)")
            }
            // A real model is hundreds of megabytes; anything tiny is an error page.
            let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
            guard size > 20_000_000 else { throw DownloadError("the download was incomplete") }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            moveError = "\(error)"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if (error as? URLError)?.code == .cancelled { return }
        let message = error.map { "Download failed: \($0.localizedDescription)" }
            ?? moveError.map { "Download failed: \($0)" }
        let option = self.option
        let owner = self.owner
        DispatchQueue.main.async {
            MainActor.assumeIsolated { owner?.completed(option, error: message) }
        }
    }
}

private struct DownloadError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
#endif
