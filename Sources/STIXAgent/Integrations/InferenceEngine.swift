import Foundation

/// Stable provider identity. Legacy model names have no prefix and resolve to
/// the existing local services without rewriting saved chats or role settings.
enum ModelProvider: String, Codable, Sendable {
    case builtInText
    case builtInImage
    case lmStudio
    case comfyUI
}

struct ModelRef: Codable, Hashable, Sendable {
    let provider: ModelProvider
    let id: String

    init(provider: ModelProvider, id: String) throws {
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !id.contains("\0"), id.utf8.count <= 4096 else {
            throw AgentError.message("Некорректный идентификатор модели")
        }
        self.provider = provider
        self.id = id
    }

    var storedID: String {
        switch provider {
        case .builtInText: "builtin-text:" + id
        case .builtInImage: "builtin-image:" + id
        case .lmStudio, .comfyUI: id
        }
    }

    static func resolveText(_ storedID: String) throws -> ModelRef {
        if storedID.hasPrefix("builtin-text:") {
            return try .init(provider: .builtInText, id: String(storedID.dropFirst("builtin-text:".count)))
        }
        guard !storedID.hasPrefix("builtin-image:") else {
            throw AgentError.message("Выбрана модель изображений вместо текстовой")
        }
        guard !storedID.hasPrefix("builtin-") else {
            throw AgentError.message("Неизвестный встроенный провайдер модели")
        }
        return try .init(provider: .lmStudio, id: storedID)
    }

    static func resolveImage(_ storedID: String) throws -> ModelRef {
        if storedID.hasPrefix("builtin-image:") {
            return try .init(provider: .builtInImage, id: String(storedID.dropFirst("builtin-image:".count)))
        }
        guard !storedID.hasPrefix("builtin-text:") else {
            throw AgentError.message("Выбрана текстовая модель вместо модели изображений")
        }
        guard !storedID.hasPrefix("builtin-") else {
            throw AgentError.message("Неизвестный встроенный провайдер модели")
        }
        return try .init(provider: .comfyUI, id: storedID)
    }
}

protocol TextInferenceEngine: Sendable {
    func models() async throws -> [ModelDescriptor]
    func prepare(model: String) async throws -> Int?
    func complete(model: String, messages: [LMMessage], tools: [ToolDefinition],
                  maxOutputTokens: Int?, preserveContext: Bool, thinking: Bool,
                  onPhase: @escaping @Sendable (String) async -> Void,
                  onRequest: @escaping @Sendable ([LMMessage]) async -> Void,
                  onReasoning: @escaping @Sendable (String) async -> Void,
                  onText: @escaping @Sendable (String) async -> Void) async throws -> LMReply
}

protocol ImageInferenceEngine: Sendable {
    func models() async throws -> [ModelDescriptor]
    func releaseIfIdle() async throws
    func generate(request: ImageRequest, model: String, outputDirectory: URL,
                  workflow: JSONValue?,
                  onStepProgress: @escaping @Sendable (Int, Int) async -> Void,
                  onProgress: @escaping @Sendable (String) async -> Void) async throws -> [URL]
}

struct LMStudioTextEngine: TextInferenceEngine {
    let client: LMStudioClient

    func models() async throws -> [ModelDescriptor] { try await client.models() }
    func prepare(model: String) async throws -> Int? {
        try await ModelResidency.shared.prepare(client: client, model: model)
    }
    func complete(model: String, messages: [LMMessage], tools: [ToolDefinition],
                  maxOutputTokens: Int? = nil, preserveContext: Bool = false, thinking: Bool = false,
                  onPhase: @escaping @Sendable (String) async -> Void = { _ in },
                  onRequest: @escaping @Sendable ([LMMessage]) async -> Void = { _ in },
                  onReasoning: @escaping @Sendable (String) async -> Void = { _ in },
                  onText: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> LMReply {
        try await client.complete(model: model, messages: messages, tools: tools,
                                  maxOutputTokens: maxOutputTokens, preserveContext: preserveContext,
                                  thinking: thinking, onPhase: onPhase, onRequest: onRequest,
                                  onReasoning: onReasoning, onText: onText)
    }
}

struct ComfyImageEngine: ImageInferenceEngine {
    let client: ComfyClient

    func models() async throws -> [ModelDescriptor] {
        try await client.checkpoints().map { ModelDescriptor(id: $0, kind: "image") }
    }
    func releaseIfIdle() async throws { try await client.releaseModelsIfIdle() }
    func generate(request: ImageRequest, model: String, outputDirectory: URL,
                  workflow: JSONValue? = nil,
                  onStepProgress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in },
                  onProgress: @escaping @Sendable (String) async -> Void = { _ in }) async throws -> [URL] {
        try await client.generate(request: request, checkpoint: model, outputDirectory: outputDirectory,
                                  workflow: workflow, onStepProgress: onStepProgress,
                                  onProgress: onProgress)
    }
}

/// Provider selection is the only place where saved model IDs are interpreted.
/// The built-in engines are injected when their resources pass validation.
struct InferenceRegistry: Sendable {
    let externalText: any TextInferenceEngine
    let externalImage: any ImageInferenceEngine
    let builtInText: (any TextInferenceEngine)?
    let builtInImage: (any ImageInferenceEngine)?

    init(lmEndpoint: String, comfyEndpoint: String,
         builtInText: (any TextInferenceEngine)? = nil,
         builtInImage: (any ImageInferenceEngine)? = nil) {
        externalText = LMStudioTextEngine(client: LMStudioClient(endpoint: lmEndpoint))
        externalImage = ComfyImageEngine(client: ComfyClient(endpoint: comfyEndpoint))
        self.builtInText = builtInText
        self.builtInImage = builtInImage
    }

    init(externalText: any TextInferenceEngine, externalImage: any ImageInferenceEngine,
         builtInText: (any TextInferenceEngine)? = nil,
         builtInImage: (any ImageInferenceEngine)? = nil) {
        self.externalText = externalText
        self.externalImage = externalImage
        self.builtInText = builtInText
        self.builtInImage = builtInImage
    }

    func text(for storedID: String) throws -> (ModelRef, any TextInferenceEngine) {
        let ref = try ModelRef.resolveText(storedID)
        switch ref.provider {
        case .lmStudio: return (ref, externalText)
        case .builtInText:
            guard let builtInText else { throw AgentError.message("Встроенная текстовая модель не установлена в этой сборке") }
            return (ref, builtInText)
        default: throw AgentError.message("Выбранная модель не поддерживает текст")
        }
    }

    func image(for storedID: String) throws -> (ModelRef, any ImageInferenceEngine) {
        let ref = try ModelRef.resolveImage(storedID)
        switch ref.provider {
        case .comfyUI: return (ref, externalImage)
        case .builtInImage:
            guard let builtInImage else { throw AgentError.message("Встроенная модель изображений не установлена в этой сборке") }
            return (ref, builtInImage)
        default: throw AgentError.message("Выбранная модель не поддерживает изображения")
        }
    }
}
