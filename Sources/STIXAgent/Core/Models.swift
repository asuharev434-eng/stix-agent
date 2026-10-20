import Foundation
import RemoteChatCore

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
    var kind: String? = nil
    var contextLimit: Int? = nil
    var contextLimitIsLoaded: Bool? = nil
    var displayName: String? = nil
    var name: String {
        if let displayName { return STIXModelNaming.displayName(displayName) }
        if id == "builtin-text:qwen3-4b-q4_k_m" { return "Qwen3 4B · встроенная" }
        if id.hasPrefix("builtin-image:") { return "Stable Diffusion 1.5 · встроенная" }
        return STIXModelNaming.displayName(id.split(separator: "/").last.map(String.init) ?? id)
    }
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
enum ChatMode: String, Codable { case agent, clean }

struct Chat: Codable, Identifiable {
    var id = UUID()
    var title = "Новый чат"
    var isMobile: Bool? = nil
    var folder: String? = nil
    var model = ""
    var mode: ChatMode? = nil
    var isClean: Bool { mode == .clean }
    var imageModel = "sd_xl_base_1.0.safetensors"
    var imagePromptModel: String? = nil
    var imagePromptLanguage: String? = nil
    var messages: [ChatMessage] = []
    var history: [LMMessage] = []
    var updatedAt = Date()
    var pinned: Bool? = nil
    var questionLevel: Int? = nil
    var tasksCollapsed: Bool? = nil
    var savedDraft: String? = nil
    var draftAttachments: [Attachment]? = nil
    var contextCheckpoint: ContextCheckpoint? = nil
    var projectID: UUID? = nil
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
    var oauth: OAuthConfiguration? = nil
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
    var defaultImageModel: String? = nil
    var onboardingComplete = false
    var alwaysApprovals: Set<String> = []
    var connections: [APIConnection] = []
    var plugins: [PluginConfig] = []
    var maxToolRounds = 40
    var imageProfiles: [ImageWorkflowProfile] = []
    var secrets: [SecretReference] = []
    var webSearchEnabled: Bool? = nil
    var thinking: Bool? = nil
    var questionLevel: Int? = nil
    var fontSize: Double? = nil
    var spacing: Double? = nil
    var memory: [String]? = nil
    var modelRoles: [String: String]? = nil
    var pluginEnvironment: [String: [String: String]]? = nil
    var disabledSkills: Set<String>? = nil
    var voiceLanguage: String? = nil
}
extension AppPreferences {
    private enum CodingKeys: String, CodingKey {
        case theme, lmEndpoint, comfyEndpoint, defaultModel, defaultImageModel,
             onboardingComplete, alwaysApprovals, connections, plugins, maxToolRounds,
             imageProfiles, secrets, webSearchEnabled, thinking, questionLevel,
             fontSize, spacing, memory, modelRoles, pluginEnvironment, disabledSkills,
             voiceLanguage
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        theme = try values.decodeIfPresent(String.self, forKey: .theme) ?? "system"
        lmEndpoint = try values.decodeIfPresent(String.self, forKey: .lmEndpoint) ?? "http://127.0.0.1:1234"
        comfyEndpoint = try values.decodeIfPresent(String.self, forKey: .comfyEndpoint) ?? "http://127.0.0.1:8188"
        defaultModel = try values.decodeIfPresent(String.self, forKey: .defaultModel) ?? ""
        defaultImageModel = try values.decodeIfPresent(String.self, forKey: .defaultImageModel)
        onboardingComplete = try values.decodeIfPresent(Bool.self, forKey: .onboardingComplete) ?? false
        alwaysApprovals = Set(try values.decodeIfPresent([String].self, forKey: .alwaysApprovals) ?? [])
        connections = try values.decodeIfPresent([APIConnection].self, forKey: .connections) ?? []
        plugins = try values.decodeIfPresent([PluginConfig].self, forKey: .plugins) ?? []
        maxToolRounds = try values.decodeIfPresent(Int.self, forKey: .maxToolRounds) ?? 40
        imageProfiles = try values.decodeIfPresent([ImageWorkflowProfile].self, forKey: .imageProfiles) ?? []
        secrets = try values.decodeIfPresent([SecretReference].self, forKey: .secrets) ?? []
        webSearchEnabled = try values.decodeIfPresent(Bool.self, forKey: .webSearchEnabled)
        thinking = try values.decodeIfPresent(Bool.self, forKey: .thinking)
        questionLevel = try values.decodeIfPresent(Int.self, forKey: .questionLevel)
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize)
        spacing = try values.decodeIfPresent(Double.self, forKey: .spacing)
        memory = try values.decodeIfPresent([String].self, forKey: .memory)
        modelRoles = try values.decodeIfPresent([String: String].self, forKey: .modelRoles)
        pluginEnvironment = try values.decodeIfPresent([String: [String: String]].self, forKey: .pluginEnvironment)
        disabledSkills = try values.decodeIfPresent([String].self, forKey: .disabledSkills).map(Set.init)
        voiceLanguage = try values.decodeIfPresent(String.self, forKey: .voiceLanguage)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(theme, forKey: .theme)
        try values.encode(lmEndpoint, forKey: .lmEndpoint)
        try values.encode(comfyEndpoint, forKey: .comfyEndpoint)
        try values.encode(defaultModel, forKey: .defaultModel)
        try values.encodeIfPresent(defaultImageModel, forKey: .defaultImageModel)
        try values.encode(onboardingComplete, forKey: .onboardingComplete)
        try values.encode(alwaysApprovals.sorted(), forKey: .alwaysApprovals)
        try values.encode(connections, forKey: .connections)
        try values.encode(plugins, forKey: .plugins)
        try values.encode(maxToolRounds, forKey: .maxToolRounds)
        try values.encode(imageProfiles, forKey: .imageProfiles)
        try values.encode(secrets, forKey: .secrets)
        try values.encodeIfPresent(webSearchEnabled, forKey: .webSearchEnabled)
        try values.encodeIfPresent(thinking, forKey: .thinking)
        try values.encodeIfPresent(questionLevel, forKey: .questionLevel)
        try values.encodeIfPresent(fontSize, forKey: .fontSize)
        try values.encodeIfPresent(spacing, forKey: .spacing)
        try values.encodeIfPresent(memory, forKey: .memory)
        try values.encodeIfPresent(modelRoles, forKey: .modelRoles)
        try values.encodeIfPresent(pluginEnvironment, forKey: .pluginEnvironment)
        try values.encodeIfPresent(disabledSkills?.sorted(), forKey: .disabledSkills)
        try values.encodeIfPresent(voiceLanguage, forKey: .voiceLanguage)
    }
}
struct PersistedState: Codable {
    var version = 1
    var chats: [Chat]
    var preferences: AppPreferences
    var undos: [UndoRecord] = []
    var jobs: [AgentJob]? = nil
    var memoryEntries: [MemoryEntry]? = nil
    var projects: [MemoryProject]? = nil
    var memoryRevisions: [MemoryRevision]? = nil
    var features: FeatureConfiguration? = nil
}

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
