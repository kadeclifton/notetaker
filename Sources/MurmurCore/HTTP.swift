import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol HTTPClient: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        final class TaskBox: @unchecked Sendable {
            var task: URLSessionDataTask?
        }
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = URLSession.shared.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let http = response as? HTTPURLResponse {
                        continuation.resume(returning: (data ?? Data(), http))
                    } else {
                        continuation.resume(throwing: URLError(.badServerResponse))
                    }
                }
                box.task = task
                task.resume()
                // Cancelled before the task existed: onCancel had nothing to cancel.
                if Task.isCancelled { task.cancel() }
            }
        } onCancel: {
            box.task?.cancel()
        }
    }
}

public struct APIError: Error, CustomStringConvertible, Equatable {
    public var service: String
    public var status: Int
    public var message: String

    public var description: String {
        let hint: String
        switch status {
        case 401, 403: hint = " (check the API key in .env)"
        case 429: hint = " (rate limited)"
        default: hint = ""
        }
        return "\(service) returned HTTP \(status)\(hint): \(message)"
    }
}

enum HTTP {
    /// Sends the request and returns the body, throwing `APIError` for non-2xx responses.
    static func send(_ request: URLRequest, client: HTTPClient, service: String) async throws -> Data {
        let (data, response) = try await client.send(request)
        guard (200..<300).contains(response.statusCode) else {
            throw APIError(service: service, status: response.statusCode, message: errorMessage(from: data))
        }
        return data
    }

    /// Pulls `error.message` (OpenAI, Groq, Anthropic) out of an error body, or falls back to the raw text.
    static func errorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? [String: Any], let message = error["message"] as? String {
                return message
            }
            if let message = object["error"] as? String { return message }
            if let message = object["message"] as? String { return message }
        }
        let text = String(decoding: data.prefix(300), as: UTF8.self)
        return text.isEmpty ? "no details" : text
    }
}

/// multipart/form-data body builder.
struct MultipartForm {
    let boundary = "murmur-\(UUID().uuidString)"
    private(set) var body = Data()

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data("\(value)\r\n".utf8))
    }

    mutating func addFile(_ name: String, filename: String, mimeType: String, data: Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n".utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    func finalized() -> Data {
        var data = body
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }
}
