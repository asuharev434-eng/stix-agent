import Foundation

/// Only prompt-scoped sampler events are eligible for display. Queue/status events
/// and binary image previews deliberately do not contribute estimated progress.
struct ComfyStepProgress: Equatable, Sendable {
    let value: Int
    let maximum: Int

    static let maximumTextBytes = 64 * 1024

    static func parse(_ text: String, promptID: String) -> Self? {
        guard !promptID.isEmpty, text.utf8.count <= maximumTextBytes,
              let data = text.data(using: .utf8),
              let event = try? JSONDecoder().decode(JSONValue.self, from: data),
              event["type"].string == "progress",
              event["data"]["prompt_id"].string == promptID,
              let value = event["data"]["value"].int,
              let maximum = event["data"]["max"].int,
              maximum > 0, value >= 0, value <= maximum else { return nil }
        return Self(value: value, maximum: maximum)
    }

    static func socketURL(endpoint: String, clientID: String) -> URL? {
        guard !clientID.isEmpty, let base = URL(string: endpoint),
              let scheme = base.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = base.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil,
              var parts = URLComponents(url: base.appendingPathComponent("ws"), resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = scheme == "https" ? "wss" : "ws"
        parts.queryItems = [URLQueryItem(name: "clientId", value: clientID)]
        return parts.url
    }
}

private final class ComfySocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false

    var isOpen: Bool { lock.withLock { opened } }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        lock.withLock { opened = true }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        lock.withLock { opened = false }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// A dedicated, short-lived connection for this submission, never the global UI
/// connection. History polling remains the source of completion and errors.
final class ComfyProgressStream: @unchecked Sendable {
    private let session: URLSession
    private let socket: URLSessionWebSocketTask
    private let delegate: ComfySocketDelegate

    private init(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 2
        let delegate = ComfySocketDelegate()
        self.delegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        socket = session.webSocketTask(with: URLRequest(url: url, timeoutInterval: 2))
        // Binary preview messages are discarded; oversized messages terminate this
        // optional stream rather than allowing unbounded preview allocation.
        socket.maximumMessageSize = 256 * 1024
    }

    static func connect(endpoint: String, clientID: String) async throws -> ComfyProgressStream? {
        guard let url = ComfyStepProgress.socketURL(endpoint: endpoint, clientID: clientID) else { return nil }
        let stream = ComfyProgressStream(url: url)
        stream.socket.resume()
        do {
            let deadline = Date().addingTimeInterval(2)
            while !stream.delegate.isOpen, Date() < deadline {
                try Task.checkCancellation()
                if stream.socket.state == .completed { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try Task.checkCancellation()
            guard stream.delegate.isOpen else { stream.close(); return nil }
            return stream
        } catch {
            stream.close()
            throw error
        }
    }

    func listen(promptID: String, onStepProgress: @escaping @Sendable (Int, Int) async -> Void) async {
        await withTaskCancellationHandler {
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    try Task.checkCancellation()
                    guard case .string(let text) = message,
                          let progress = ComfyStepProgress.parse(text, promptID: promptID) else { continue }
                    await onStepProgress(progress.value, progress.maximum)
                }
            } catch {
                // Socket availability never prevents history-based generation.
            }
        } onCancel: {
            self.close()
        }
    }

    func close() {
        socket.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
    }
}
