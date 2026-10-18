import Foundation

enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> JSONValue { if case .object(let o) = self { return o[key] ?? .null }; return .null }
    var string: String? { if case .string(let s) = self { return s }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    var object: [String: JSONValue]? { if case .object(let a) = self { return a }; return nil }
    var int: Int? { if case .number(let n) = self, n.isFinite, n.rounded(.towardZero) == n, n >= Double(Int.min), n < Double(Int.max) { return Int(n) }; return nil }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var encoded: String { (try? String(data: JSONEncoder().encode(self), encoding: .utf8)) ?? "null" }
    static func parse(_ string: String) throws -> JSONValue { try JSONDecoder().decode(Self.self, from: Data(string.utf8)) }
    func requiredString(_ key: String) throws -> String {
        guard let s = self[key].string, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentError.message("Не заполнено поле \(key)") }
        return s
    }
}

enum AgentError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct ActionDenied: LocalizedError { var errorDescription: String? { "Действие отменено пользователем." } }
struct ModelDescriptor: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String { id.split(separator: "/").last.map(String.init) ?? id }
}
struct ToolCall: Codable, Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var arguments: String
}
struct LMMessage: Codable, Equatable, Sendable {
    var role: String
    var content: String?
    var toolCalls: [ToolCall] = []
    var toolCallID: String? = nil
    var imageURLs: [String]? = nil
    var sourceMessageID: UUID? = nil
}
struct ToolDefinition: Sendable {
    let name: String
    let description: String
    let parameters: JSONValue
    var wire: JSONValue { .object(["type": .string("function"), "function": .object(["name": .string(name), "description": .string(description), "parameters": parameters])]) }
}
struct LMReply: Sendable { var content: String; var toolCalls: [ToolCall] }

struct Attachment: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var path: String
    var kind: String // file, image, folder, html, mermaid
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}
struct ChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: String
    var text: String
    var attachments: [Attachment] = []
    var toolName: String? = nil
    var detail: String? = nil
    var status: String? = nil
    var undoID: UUID? = nil
    var createdAt = Date()
}
struct Chat: Codable, Identifiable {
    var id = UUID()
    var title = "Новый чат"
    var folder: String? = nil
    var model = ""
    var imageModel = "sd_xl_base_1.0.safetensors"
    var imagePromptModel: String? = nil
    var imagePromptLanguage: String? = nil
    var messages: [ChatMessage] = []
    var history: [LMMessage] = []
    var updatedAt = Date()
    var pinned: Bool? = nil
    var questionLevel: Int? = nil
}
struct APIConnection: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var baseURL: String
    var auth: String // bearer, header, basic, none
    var headerName: String
    var documentationPath: String
}
struct PluginConfig: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var transport: String // stdio or http
    var command: String
    var arguments: [String]
    var url: String
    var enabled: Bool
}
struct ImageWorkflowProfile: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var path: String
}
struct SecretReference: Codable, Identifiable { var id: String; var label: String }
struct AppPreferences: Codable {
    var theme = "system"
    var lmEndpoint = "http://127.0.0.1:1234"
    var comfyEndpoint = "http://127.0.0.1:8188"
    var defaultModel = ""
    var onboardingComplete = false
    var alwaysApprovals: Set<String> = []
    var connections: [APIConnection] = []
    var plugins: [PluginConfig] = []
    var maxToolRounds = 40
    var imageProfiles: [ImageWorkflowProfile] = []
    var secrets: [SecretReference] = []
    var thinking: Bool? = nil
    var questionLevel: Int? = nil
    var fontSize: Double? = nil
    var spacing: Double? = nil
    var memory: [String]? = nil
    var modelRoles: [String: String]? = nil
    var pluginEnvironment: [String: [String: String]]? = nil
}
struct PersistedState: Codable { var version = 1; var chats: [Chat]; var preferences: AppPreferences; var undos: [UndoRecord] = []; var jobs: [AgentJob]? = nil }

struct PendingInteraction: Identifiable {
    enum Kind { case question, approval, secret, permissions }
    var id = UUID()
    var kind: Kind
    var title: String
    var detail: String
    var choices: [String] = []
    var scope: String? = nil
}
enum InteractionAnswer { case text(String), once, task, always, deny }
struct UndoRecord: Codable, Identifiable, Sendable {
    var id = UUID()
    var kind: String
    var source: String
    var destination: String?
    var backup: String?
    var expectedDigest: String?
}

enum ModelOutput {
    static func clean(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let markers = ["<|endoftext|>", "<|im_end|>", "<|eot_id|>"]
        while let marker = markers.first(where: { result.hasSuffix($0) }) {
            result = String(result.dropLast(marker.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}
