import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol WhisperServing: Sendable {
    var baseURL: URL { get }
    /// Starts the server if it is not running and waits until it answers.
    func ensureRunning() async throws
}

public enum WhisperServerError: Error, CustomStringConvertible, Equatable {
    case exited(log: String)
    case timedOut

    public var description: String {
        switch self {
        case let .exited(log):
            return "whisper-server stopped while starting: \(log.isEmpty ? "no output" : log)"
        case .timedOut:
            return "whisper-server did not come up within two minutes."
        }
    }
}

/// Keeps whisper.cpp's `whisper-server` running with the model loaded, so each dictation skips
/// the model load (and, on first use, the Metal kernel compile) that `whisper-cli` pays every time.
public final class WhisperServer: WhisperServing, @unchecked Sendable {
    public struct Settings: Equatable, Sendable {
        public var binary: String
        public var model: String
        public var port: Int
        public var threads: Int
        public var language: String
        /// Holds the pid file and the server log.
        public var stateDirectory: URL

        public init(binary: String, model: String, port: Int, threads: Int, language: String,
                    stateDirectory: URL = AppPaths.directory) {
            self.binary = binary
            self.model = model
            self.port = port
            self.threads = threads
            self.language = language
            self.stateDirectory = stateDirectory
        }
    }

    public let settings: Settings
    private let client: HTTPClient
    private let lock = NSLock()
    private var process: Process?
    private var startTask: Task<Void, Error>?

    public init(_ settings: Settings, client: HTTPClient = URLSessionHTTPClient()) {
        self.settings = settings
        self.client = client
    }

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(settings.port)")! }
    var pidFile: URL { settings.stateDirectory.appendingPathComponent("whisper-server.pid") }
    var logFile: URL { settings.stateDirectory.appendingPathComponent("whisper-server.log") }

    // MARK: One server per app

    private static let registryLock = NSLock()
    private static var current: WhisperServer?

    /// The running server for these settings. A server with different settings (another model,
    /// port, ...) is stopped first, so there is only ever one.
    public static func shared(_ settings: Settings) -> WhisperServer {
        registryLock.withLock {
            if let current, current.settings == settings { return current }
            current?.stop()
            let server = WhisperServer(settings)
            current = server
            return server
        }
    }

    public static func stopShared() {
        registryLock.withLock {
            current?.stop()
            current = nil
        }
    }

    // MARK: Lifecycle

    public func ensureRunning() async throws {
        let task = lock.withLock { () -> Task<Void, Error> in
            // Reuse a start in progress (no process yet) or a server that is up.
            if let startTask, process?.isRunning ?? true { return startTask }
            let task = Task { try await self.launch() }
            startTask = task
            return task
        }
        do {
            try await task.value
        } catch {
            lock.withLock { if startTask == task { startTask = nil } }
            throw error
        }
    }

    public func stop() {
        let running = lock.withLock { () -> Process? in
            startTask?.cancel()
            startTask = nil
            defer { process = nil }
            return process
        }
        if let running, running.isRunning { running.terminate() }
        try? FileManager.default.removeItem(at: pidFile)
    }

    private func launch() async throws {
        guard FileManager.default.fileExists(atPath: settings.model) else {
            throw TranscriptionError.modelNotFound(settings.model)
        }
        try FileManager.default.createDirectory(at: settings.stateDirectory, withIntermediateDirectories: true)
        await killOrphan()

        _ = FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let log = try FileHandle(forWritingTo: logFile)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: settings.binary)
        process.arguments = [
            "-m", settings.model,
            "--host", "127.0.0.1",
            "--port", String(settings.port),
            "-t", String(settings.threads),
            "-l", settings.language,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        try process.run()
        lock.withLock { self.process = process }
        try? Data(String(process.processIdentifier).utf8).write(to: pidFile)

        // Loading a model takes a few seconds; the first run on a Mac also compiles Metal kernels.
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if Task.isCancelled {
                process.terminate()
                throw CancellationError()
            }
            guard process.isRunning else { throw WhisperServerError.exited(log: logTail()) }
            if await isHealthy() { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        process.terminate()
        throw WhisperServerError.timedOut
    }

    private func isHealthy() async -> Bool {
        var request = URLRequest(url: baseURL)
        request.timeoutInterval = 1
        guard let (_, response) = try? await client.send(request) else { return false }
        return response.statusCode == 200
    }

    /// A server left behind by a crash would hold the port. Stop it if the pid file names one.
    private func killOrphan() async {
        guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return }
        try? FileManager.default.removeItem(at: pidFile)
        // Only kill it if that pid is still a whisper-server, not some unrelated process that reused the number.
        guard let result = try? await ProcessRunner.run("/bin/ps", arguments: ["-p", String(pid), "-o", "comm="]),
              result.stdout.contains("whisper-server") else { return }
        kill(pid, SIGTERM)
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    func logTail() -> String {
        guard let text = try? String(contentsOf: logFile, encoding: .utf8) else { return "" }
        let lines = text.split(whereSeparator: \.isNewline).suffix(4)
        return lines.joined(separator: " | ")
    }
}

/// Transcribes through a running `whisper-server` (its `/inference` endpoint).
public struct WhisperServerTranscriber: Transcriber {
    public var server: WhisperServing
    public var modelName: String
    public var timeout: TimeInterval
    public var client: HTTPClient

    public init(server: WhisperServing, modelName: String, timeout: TimeInterval = 120,
                client: HTTPClient = URLSessionHTTPClient()) {
        self.server = server
        self.modelName = modelName
        self.timeout = timeout
        self.client = client
    }

    public var name: String { "whisper.cpp (\(modelName), kept loaded)" }

    public func transcribe(wav: Data, language: String?, prompt: String?) async throws -> String {
        try await request(wav: wav, language: language, prompt: prompt).text
    }

    public func transcribeSegments(wav: Data, language: String?, prompt: String?) async throws -> [TimedText] {
        let response = try await request(wav: wav, language: language, prompt: prompt)
        guard let segments = response.segments, !segments.isEmpty else {
            return [TimedText(start: 0, end: response.duration ?? 0, text: response.text)]
        }
        return segments.map { TimedText(start: $0.start, end: $0.end, text: $0.text) }
    }

    struct Response: Decodable {
        struct Segment: Decodable {
            let start: Double
            let end: Double
            let text: String
        }
        let text: String
        let duration: Double?
        let segments: [Segment]?
    }

    private func request(wav: Data, language: String?, prompt: String?) async throws -> Response {
        try await server.ensureRunning()
        do {
            return try await send(wav: wav, language: language, prompt: prompt)
        } catch let error as URLError where error.code == .cannotConnectToHost || error.code == .networkConnectionLost {
            // The server died between requests; ensureRunning restarts it.
            try await server.ensureRunning()
            return try await send(wav: wav, language: language, prompt: prompt)
        }
    }

    private func send(wav: Data, language: String?, prompt: String?) async throws -> Response {
        var form = MultipartForm()
        form.addField("temperature", "0.0")
        // verbose_json adds per-segment timestamps; plain "text" is still there for dictation.
        form.addField("response_format", "verbose_json")
        if let language { form.addField("language", language) }
        if let prompt, !prompt.isEmpty { form.addField("prompt", prompt) }
        form.addFile("file", filename: "audio.wav", mimeType: "audio/wav", data: wav)

        var request = URLRequest(url: server.baseURL.appendingPathComponent("inference"))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finalized()

        let data = try await HTTP.send(request, client: client, service: "whisper-server")
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw TranscriptionError.badResponse(String(decoding: data.prefix(200), as: UTF8.self))
        }
        return response
    }
}
