import Foundation
import CryptoKit

public enum RemoteChatError: LocalizedError {
    case invalidCode, expiredCode, invalidFrame, authentication, oversized, staleRequest

    public var errorDescription: String? {
        switch self {
        case .invalidCode: "Неверный QR-код STIX Agent"
        case .expiredCode: "QR-код истёк. Запросите новый на Mac"
        case .invalidFrame: "Повреждённый ответ Mac"
        case .authentication: "Не удалось подтвердить подключение к Mac"
        case .oversized: "Сообщение слишком велико"
        case .staleRequest: "Запрос устарел. Повторите действие"
        }
    }
}

public struct RemotePairingCode: Codable, Equatable, Sendable {
    public let version: Int
    public let serviceName: String
    public let host: String
    public let port: UInt16
    public let pairingID: UUID
    public let key: Data
    public let expiresAt: Date

    public init(serviceName: String, host: String, port: UInt16, pairingID: UUID = UUID(),
                key: Data, expiresAt: Date) {
        self.version = 1
        self.serviceName = serviceName
        self.host = host
        self.port = port
        self.pairingID = pairingID
        self.key = key
        self.expiresAt = expiresAt
    }

    public func encoded() throws -> String {
        guard key.count == 32, port != 0 else { throw RemoteChatError.invalidCode }
        return "stixagent://pair/" + (try JSONEncoder().encode(self)).base64URLEncodedString()
    }

    public static func parse(_ value: String, now: Date = .now) throws -> Self {
        guard value.hasPrefix("stixagent://pair/"),
              let data = Data(base64URLEncoded: String(value.dropFirst("stixagent://pair/".count))),
              let code = try? JSONDecoder().decode(Self.self, from: data),
              code.version == 1, code.key.count == 32, code.port != 0,
              !code.serviceName.isEmpty, !code.host.isEmpty else { throw RemoteChatError.invalidCode }
        guard code.expiresAt > now else { throw RemoteChatError.expiredCode }
        return code
    }
}

public struct RemoteRequest: Codable, Sendable {
    public var operation: String
    public var text: String?
    public var interactionID: UUID?
    public var answer: String?
    public var messageID: UUID?
    public var attachmentID: UUID?
    public var deviceName: String?
    public var uploadName: String?
    public var uploadData: Data?

    public init(operation: String, text: String? = nil, interactionID: UUID? = nil,
                answer: String? = nil, messageID: UUID? = nil, attachmentID: UUID? = nil,
                deviceName: String? = nil, uploadName: String? = nil, uploadData: Data? = nil) {
        self.operation = operation; self.text = text; self.interactionID = interactionID
        self.answer = answer; self.messageID = messageID; self.attachmentID = attachmentID
        self.deviceName = deviceName
        self.uploadName = uploadName; self.uploadData = uploadData
    }
}

public struct RemoteAttachment: Codable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let kind: String
    public init(id: UUID, name: String, kind: String) { self.id = id; self.name = name; self.kind = kind }
}

public struct RemoteMessage: Codable, Identifiable, Sendable {
    public let id: UUID
    public let role: String
    public let text: String
    public let status: String?
    public let createdAt: Date
    public let attachments: [RemoteAttachment]
    public init(id: UUID, role: String, text: String, status: String?, createdAt: Date, attachments: [RemoteAttachment]) {
        self.id = id; self.role = role; self.text = text; self.status = status
        self.createdAt = createdAt; self.attachments = attachments
    }
}

public struct RemoteJob: Codable, Identifiable, Sendable {
    public let id: UUID
    public let prompt: String
    public let status: String
    public let phase: String?
    public let progress: Double?
    public init(id: UUID, prompt: String, status: String, phase: String?, progress: Double?) {
        self.id = id; self.prompt = prompt; self.status = status; self.phase = phase; self.progress = progress
    }
}

public struct RemoteInteraction: Codable, Identifiable, Sendable {
    public let id: UUID
    public let kind: String
    public let title: String
    public let detail: String
    public let choices: [String]
    public init(id: UUID, kind: String, title: String, detail: String, choices: [String]) {
        self.id = id; self.kind = kind; self.title = title; self.detail = detail; self.choices = choices
    }
}

public struct RemoteSnapshot: Codable, Sendable {
    public let title: String
    public let messages: [RemoteMessage]
    public let jobs: [RemoteJob]
    public let interaction: RemoteInteraction?
    public let commands: [RemoteCommand]
    public let models: [RemoteModel]
    public let imageModels: [RemoteModel]
    public let imagePromptModelID: String?
    public init(title: String, messages: [RemoteMessage], jobs: [RemoteJob], interaction: RemoteInteraction?,
                commands: [RemoteCommand], models: [RemoteModel], imageModels: [RemoteModel],
                imagePromptModelID: String?) {
        self.title = title; self.messages = messages; self.jobs = jobs
        self.interaction = interaction; self.commands = commands
        self.models = models; self.imageModels = imageModels
        self.imagePromptModelID = imagePromptModelID
    }
}

public struct RemoteModel: Codable, Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let selected: Bool
    public let supportsImagePrompt: Bool?
    public init(id: String, name: String, selected: Bool, supportsImagePrompt: Bool? = nil) {
        self.id = id; self.name = name; self.selected = selected
        self.supportsImagePrompt = supportsImagePrompt
    }
}

public struct RemoteCommand: Codable, Identifiable, Sendable {
    public let command: String
    public let title: String
    public let detail: String
    public var id: String { command }
    public init(command: String, title: String, detail: String) {
        self.command = command; self.title = title; self.detail = detail
    }
}

public struct RemoteResponse: Codable, Sendable {
    public let snapshot: RemoteSnapshot?
    public let fileData: Data?
    public let error: String?
    public init(snapshot: RemoteSnapshot? = nil, fileData: Data? = nil, error: String? = nil) {
        self.snapshot = snapshot; self.fileData = fileData; self.error = error
    }
}

public struct RemoteEnvelope: Codable, Sendable {
    public let peerID: UUID
    public let requestID: UUID
    public let sentAt: Date
    public let payload: Data

    public static func seal<T: Encodable>(_ value: T, peerID: UUID, requestID: UUID = UUID(),
                                          key: Data, now: Date = .now) throws -> Self {
        guard key.count == 32 else { throw RemoteChatError.authentication }
        let plain = try JSONEncoder().encode(value)
        let aad = associatedData(peerID: peerID, requestID: requestID, sentAt: now)
        let sealed = try AES.GCM.seal(plain, using: SymmetricKey(data: key), authenticating: aad)
        guard let combined = sealed.combined else { throw RemoteChatError.authentication }
        return .init(peerID: peerID, requestID: requestID, sentAt: now, payload: combined)
    }

    public func open<T: Decodable>(_ type: T.Type, key: Data, now: Date = .now) throws -> T {
        guard abs(now.timeIntervalSince(sentAt)) <= 120 else { throw RemoteChatError.staleRequest }
        guard key.count == 32, let box = try? AES.GCM.SealedBox(combined: payload) else { throw RemoteChatError.authentication }
        let aad = Self.associatedData(peerID: peerID, requestID: requestID, sentAt: sentAt)
        let plain = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
        return try JSONDecoder().decode(type, from: plain)
    }

    private static func associatedData(peerID: UUID, requestID: UUID, sentAt: Date) -> Data {
        Data("stix-remote-v1|\(peerID.uuidString)|\(requestID.uuidString)|\(sentAt.timeIntervalSince1970.bitPattern)".utf8)
    }

    private init(peerID: UUID, requestID: UUID, sentAt: Date, payload: Data) {
        self.peerID = peerID; self.requestID = requestID; self.sentAt = sentAt; self.payload = payload
    }
}

public enum RemoteFraming {
    public static let maxFrame = 24 * 1024 * 1024
    public static func encode(_ data: Data) throws -> Data {
        guard data.count <= maxFrame else { throw RemoteChatError.oversized }
        var size = UInt32(data.count).bigEndian
        var result = withUnsafeBytes(of: &size) { Data($0) }
        result.append(data)
        return result
    }
    public static func payloadLength(_ header: Data) throws -> Int {
        guard header.count == 4 else { throw RemoteChatError.invalidFrame }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= maxFrame else { throw RemoteChatError.oversized }
        return Int(length)
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    init?(base64URLEncoded value: String) {
        let normalized = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        self.init(base64Encoded: normalized + String(repeating: "=", count: (4 - normalized.count % 4) % 4))
    }
}
