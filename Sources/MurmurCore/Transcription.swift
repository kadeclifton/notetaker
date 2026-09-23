import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol Transcriber: Sendable {
    /// Human-readable name for the menu, e.g. "whisper.cpp (ggml-small.en)".
    var name: String { get }
    func transcribe(wav: Data, language: String?, prompt: String?) async throws -> String
}

public enum TranscriptionError: Error, CustomStringConvertible, Equatable {
    case whisperNotFound
    case modelNotFound(String)
    case whisperFailed(status: Int32, output: String)
    case badResponse(String)

    public var description: String {
        switch self {
        case .whisperNotFound:
            return "whisper-cli not found. Install it with `brew install whisper-cpp`, or set transcription.whisperCpp.binary."
        case let .modelNotFound(path):
            return "Whisper model not found at \(path). Run scripts/download-model.sh small.en"
        case let .whisperFailed(status, output):
            return "whisper-cli exited with status \(status): \(output)"
        case let .badResponse(detail):
            return "Unexpected transcription response: \(detail)"
        }
    }
}

// MARK: - Whisper API (Groq, OpenAI)

/// OpenAI's `/audio/transcriptions` endpoint, which Groq also implements.
public struct WhisperAPITranscriber: Transcriber {
    public var service: String
    public var baseURL: URL
    public var apiKey: String
    public var model: String
    public var timeout: TimeInterval
    public var client: HTTPClient

    public init(service: String, baseURL: URL, apiKey: String, model: String,
                timeout: TimeInterval = 60, client: HTTPClient = URLSessionHTTPClient()) {
        self.service = service
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.timeout = timeout
        self.client = client
    }

    public var name: String { "\(service) \(model)" }

    public func transcribe(wav: Data, language: String?, prompt: String?) async throws -> String {
        var form = MultipartForm()
        form.addField("model", model)
        form.addField("response_format", "json")
        form.addField("temperature", "0")
        if let language { form.addField("language", language) }
        if let prompt, !prompt.isEmpty { form.addField("prompt", prompt) }
        form.addFile("file", filename: "audio.wav", mimeType: "audio/wav", data: wav)

        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()

        let data = try await HTTP.send(request, client: client, service: service)
        struct Response: Decodable { let text: String }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw TranscriptionError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return response.text
    }
}

// MARK: - whisper.cpp

/// Runs the whisper.cpp command-line tool on a temporary WAV file. Nothing leaves the machine.
public struct WhisperCppTranscriber: Transcriber {
    public var binary: String
    public var model: String
    public var threads: Int

    public init(binary: String, model: String, threads: Int = 0) {
        self.binary = binary
        self.model = model
        self.threads = threads > 0 ? threads : WhisperCppTranscriber.defaultThreads
    }

    public var name: String {
        let file = (model as NSString).lastPathComponent
        return "whisper.cpp (\((file as NSString).deletingPathExtension))"
    }

    static var defaultThreads: Int {
        max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
    }

    /// Where Homebrew and manual builds usually put the CLI. GUI apps do not get your shell's PATH.
    public static let searchPaths = [
        "/opt/homebrew/bin/whisper-cli",
        "/usr/local/bin/whisper-cli",
        "/opt/local/bin/whisper-cli",
        "~/.local/bin/whisper-cli",
        "~/whisper.cpp/build/bin/whisper-cli",
        // Older whisper.cpp releases called the binary whisper-cpp or main.
        "/opt/homebrew/bin/whisper-cpp",
        "/usr/local/bin/whisper-cpp",
    ]

    /// Resolves the configured binary, or searches the usual places and PATH.
    public static func locateBinary(configured: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let fm = FileManager.default
        if !configured.isEmpty {
            let path = AppPaths.expandTilde(configured)
            return fm.isExecutableFile(atPath: path) ? path : nil
        }
        var candidates = searchPaths.map(AppPaths.expandTilde)
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(dir)/whisper-cli")
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    func arguments(audioPath: String, language: String?, prompt: String?) -> [String] {
        var args = ["-m", model, "-f", audioPath, "-t", String(threads), "--no-timestamps", "--no-prints"]
        args += ["-l", language ?? "auto"]
        if let prompt, !prompt.isEmpty { args += ["--prompt", prompt] }
        return args
    }

    public func transcribe(wav: Data, language: String?, prompt: String?) async throws -> String {
        guard FileManager.default.fileExists(atPath: model) else {
            throw TranscriptionError.modelNotFound(model)
        }
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-\(UUID().uuidString).wav")
        try wav.write(to: audioURL)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let result = try await ProcessRunner.run(binary, arguments: arguments(audioPath: audioURL.path, language: language, prompt: prompt))
        guard result.status == 0 else {
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TranscriptionError.whisperFailed(status: result.status, output: String(detail.suffix(400)))
        }
        return result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Runs a process and collects its output. Cancelling the Swift task terminates the process,
/// which is how Esc kills a local transcription.
public enum ProcessRunner {
    public struct Result: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    public static func run(_ executable: String, arguments: [String]) async throws -> Result {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let result: Result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                // Drain both pipes on background threads so a chatty process cannot block on a full pipe.
                let group = DispatchGroup()
                let collected = OutputBox()
                group.enter()
                DispatchQueue.global().async {
                    collected.stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global().async {
                    collected.stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                process.terminationHandler = { finished in
                    group.notify(queue: .global()) {
                        continuation.resume(returning: Result(
                            status: finished.terminationStatus,
                            stdout: String(decoding: collected.stdout, as: UTF8.self),
                            stderr: String(decoding: collected.stderr, as: UTF8.self)
                        ))
                    }
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                    group.notify(queue: .global()) { continuation.resume(throwing: error) }
                    return
                }
                // The child has its own copies; close ours so reads see EOF when it exits.
                try? outPipe.fileHandleForWriting.close()
                try? errPipe.fileHandleForWriting.close()
                // Cancelled while launching: onCancel saw no running process.
                if Task.isCancelled { stop(process) }
            }
        } onCancel: {
            stop(process)
        }
        try Task.checkCancellation()
        return result
    }

    /// SIGTERM, then SIGKILL if the process is still around a moment later
    /// (a child can inherit a blocked SIGTERM from its parent).
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private final class OutputBox: @unchecked Sendable {
        var stdout = Data()
        var stderr = Data()
    }
}

// MARK: - Transcript hygiene

public enum TranscriptFilter {
    /// Phrases Whisper produces from silence or noise. Dropped only when they are the whole transcript.
    static let hallucinations: Set<String> = [
        "thank you for watching", "thank you for watching.",
        "thanks for watching", "thanks for watching!", "thanks for watching.", "you", "you.",
        "please subscribe", "subtitles by the amara.org community", ".", "...",
    ]

    /// Removes whisper.cpp's non-speech markers like [BLANK_AUDIO] or [Music], collapses whitespace,
    /// and drops the whole thing if it is a known silence hallucination.
    public static func clean(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\[[^\]]*\]"#, with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if hallucinations.contains(result.lowercased()) { return "" }
        return result
    }
}
