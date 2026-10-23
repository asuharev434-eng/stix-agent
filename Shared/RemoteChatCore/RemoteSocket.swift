import Foundation
import Network

public enum RemoteSocket {
    private final class CompletionGate: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        private let continuation: CheckedContinuation<Void, Error>
        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
        @discardableResult func finish(_ result: Result<Void, Error>) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return false }
            finished = true
            continuation.resume(with: result)
            return true
        }
    }
    public static func receive(_ connection: NWConnection) async throws -> Data {
        let header = try await readExactly(4, from: connection)
        let length = try RemoteFraming.payloadLength(header)
        return try await readExactly(length, from: connection)
    }

    public static func send(_ data: Data, through connection: NWConnection) async throws {
        let framed = try RemoteFraming.encode(data)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    public static func connect(to code: RemotePairingCode) async throws -> NWConnection {
        let endpoint = NWEndpoint.service(name: code.serviceName, type: "_stixagent._tcp", domain: "local.", interface: nil)
        let connection = NWConnection(to: endpoint, using: .tcp)
        try await start(connection)
        return connection
    }

    public static func connect(host: String, port: UInt16) async throws -> NWConnection {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw RemoteChatError.invalidCode }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        try await start(connection)
        return connection
    }

    private static func start(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = CompletionGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(.success(()))
                case .failed(let error): gate.finish(.failure(error))
                case .cancelled: gate.finish(.failure(CancellationError()))
                default: break
                }
            }
            connection.start(queue: DispatchQueue(label: "studio.stix.remote.connection"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                if gate.finish(.failure(URLError(.timedOut))) { connection.cancel() }
            }
        }
    }

    private static func readExactly(_ count: Int, from connection: NWConnection) async throws -> Data {
        var result = Data()
        while result.count < count {
            let remaining = count - result.count
            let next = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: min(remaining, 64 * 1024)) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if complete { continuation.resume(throwing: RemoteChatError.invalidFrame) }
                    else { continuation.resume(throwing: RemoteChatError.invalidFrame) }
                }
            }
            result.append(next)
        }
        return result
    }
}
