import CryptoKit
import Foundation

struct ImportedMLXModel: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let directoryName: String
    let modelType: String
    let vision: Bool
    let bytes: Int64
    let files: [String: String]
}

private struct MLXRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
        let imageURLs: [String]?
    }
    let directory: String
    let vision: Bool
    let messages: [Message]
    let tools: [String]
    let maxTokens: Int
}

struct MLXEvent: Decodable {
    let type: String
    let text: String?
    let name: String?
    let arguments: String?
    let id: String?
}

/// App-owned MLX model directories are served by a signed local process, without HTTP.
actor LocalMLXTextEngine: TextInferenceEngine {
    let directory: URL
    let executable: URL
    private var records: [ImportedMLXModel] = []
    private var loaded = false
    private var busy = false

    init(directory: URL, executable: URL) {
        self.directory = directory
        self.executable = executable
    }

    static func bundled(paths: AppStoragePaths) -> LocalMLXTextEngine? {
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("stix-mlx-runner"),
              FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return LocalMLXTextEngine(directory: paths.models.appendingPathComponent("MLX"), executable: executable)
    }

    private var manifest: URL { directory.appendingPathComponent("manifest.json") }

    private func load() throws {
        guard !loaded else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: manifest.path) {
            records = try JSONDecoder().decode([ImportedMLXModel].self, from: Data(contentsOf: manifest))
        }
        loaded = true
    }

    func models() async throws -> [ModelDescriptor] {
        try load()
        return records.map { ModelDescriptor(id: "mlx-text:" + $0.id, kind: "text", contextLimit: 32768,
                                              displayName: $0.name + " · локальная MLX") }
    }

    func importedModels() throws -> [ImportedMLXModel] {
        try load()
        return records
    }

    func importDirectory(_ source: URL) async throws -> ImportedMLXModel {
        try load()
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard source.isFileURL,
              (try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isDirectory == true,
              (try source.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])).isSymbolicLink != true else {
            throw AgentError.message("Выберите обычную локальную папку MLX-модели")
        }
        let metadata = try Self.inspect(source)
        let temp = directory.appendingPathComponent(".import-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        try FileManager.default.copyItem(at: source, to: temp)
        let copied = try Self.inspect(temp)
        guard copied.type == metadata.type, copied.files == metadata.files else {
            throw AgentError.message("MLX-модель изменилась во время копирования")
        }
        let signature = metadata.files.keys.sorted().map { $0 + ":" + metadata.files[$0, default: ""] }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(signature.utf8)).map { String(format: "%02x", $0) }.joined()
        if let existing = records.first(where: { $0.id == String(digest.prefix(16)) }) { return existing }
        let id = String(digest.prefix(16))
        let destinationName = "imported-" + id
        let destination = directory.appendingPathComponent(destinationName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw AgentError.message("Конфликт импортированной MLX-модели")
        }
        let item = ImportedMLXModel(id: id, name: source.lastPathComponent, directoryName: destinationName,
                                    modelType: metadata.type, vision: metadata.vision, bytes: metadata.bytes,
                                    files: metadata.files)
        try FileManager.default.moveItem(at: temp, to: destination)
        do {
            try JSONEncoder().encode(records + [item]).write(to: manifest, options: .atomic)
            records.append(item)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
        return item
    }

    func remove(_ id: String) throws {
        try load()
        guard !busy, let item = records.first(where: { $0.id == id }) else {
            throw AgentError.message("MLX-модель не найдена или используется")
        }
        let next = records.filter { $0.id != id }
        try JSONEncoder().encode(next).write(to: manifest, options: .atomic)
        records = next
        try FileManager.default.removeItem(at: directory.appendingPathComponent(item.directoryName))
    }

    func prepare(model: String) async throws -> Int? {
        try load()
        guard records.contains(where: { $0.id == model }), FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw AgentError.message("Локальная MLX-модель или движок недоступны")
        }
        return 32768
    }

    func complete(model: String, messages: [LMMessage], tools: [ToolDefinition],
                  maxOutputTokens: Int?, preserveContext: Bool, thinking: Bool,
                  onPhase: @escaping @Sendable (String) async -> Void,
                  onRequest: @escaping @Sendable ([LMMessage]) async -> Void,
                  onReasoning: @escaping @Sendable (String) async -> Void,
                  onText: @escaping @Sendable (String) async -> Void) async throws -> LMReply {
        guard !busy else { throw AgentError.message("Локальная MLX-модель уже работает") }
        busy = true
        defer { busy = false }
        try load()
        guard let item = records.first(where: { $0.id == model }) else { throw AgentError.message("MLX-модель не найдена") }
        let modelURL = directory.appendingPathComponent(item.directoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: modelURL.appendingPathComponent("config.json").path) else {
            throw AgentError.message("Файлы MLX-модели отсутствуют")
        }
        guard !messages.isEmpty, messages.count <= 512 else { throw AgentError.message("Слишком длинная история") }
        await onRequest(messages)
        await onPhase("Загружаю локальную MLX-модель…")
        var mapped = try messages.map { message -> MLXRequest.Message in
            guard ["system", "user", "assistant", "tool"].contains(message.role) else {
                throw AgentError.message("Некорректная роль сообщения")
            }
            guard item.vision || (message.imageURLs ?? []).isEmpty else {
                throw AgentError.message("Эта MLX-модель не поддерживает изображения")
            }
            var content = message.content ?? ""
            if message.role == "tool" { content = "Результат инструмента \(message.toolCallID ?? ""): \(content)" }
            if !message.toolCalls.isEmpty {
                let calls = try message.toolCalls.map { call in
                    JSONValue.object(["id": .string(call.id), "name": .string(call.name),
                                      "arguments": try JSONValue.parse(call.arguments)])
                }
                content += "\n" + JSONValue.object(["tool_calls": .array(calls)]).encoded
            }
            return MLXRequest.Message(role: message.role == "tool" ? "user" : message.role,
                                      content: content, imageURLs: message.imageURLs)
        }
        if !tools.isEmpty {
            let instruction = "Доступные инструменты (JSON Schema):\n" + tools.map { $0.wire.encoded }.joined(separator: "\n") +
                "\nЕсли нужен инструмент, верни только JSON: {\"tool_calls\":[{\"name\":\"имя\",\"arguments\":{...}}]}. Не утверждай о выполнении до результата инструмента. Если инструмент не нужен, отвечай обычным текстом."
            if mapped.first?.role == "system" {
                let first = mapped.removeFirst()
                mapped.insert(.init(role: "system", content: first.content + "\n\n" + instruction, imageURLs: nil), at: 0)
            } else { mapped.insert(.init(role: "system", content: instruction, imageURLs: nil), at: 0) }
        }
        // GPT-OSS may spend hundreds of tokens in an internal analysis channel before
        // yielding a visible answer or tool call. A small visible-answer budget is not
        // enough to cap that hidden work safely.
        let requested = maxOutputTokens ?? 2048
        let budget = item.modelType == "gpt_oss" ? max(requested, 3072) : requested
        let request = MLXRequest(directory: modelURL.path, vision: item.vision, messages: mapped,
                                 tools: tools.map { $0.wire.encoded },
                                 maxTokens: min(max(1, budget), 8192))
        let temporary = directory.appendingPathComponent(".request-" + UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try JSONEncoder().encode(request).write(to: temporary, options: .atomic)
        let result = try await ProcessRunner().runExecutable(executable.path, arguments: [temporary.path],
                                                             directory: directory.path, timeout: 900,
                                                             maxOutputBytes: 2_000_000)
        if result.timedOut { throw AgentError.message("Локальная MLX-модель не ответила за отведённое время") }
        guard result.exitCode == 0 else { throw AgentError.message("MLX: " + result.output.suffix(1200)) }
        let reply = try Self.parseEvents(result.output, allowed: Set(tools.map(\.name)))
        if reply.toolCalls.isEmpty { await onText(reply.content) }
        return reply
    }

    static func parseEvents(_ raw: String, allowed: Set<String>) throws -> LMReply {
        var output = ""
        var calls: [ToolCall] = []
        var completed = false
        for line in raw.split(separator: "\n") where line.hasPrefix("STIX_EVENT:") {
            guard let data = String(line.dropFirst("STIX_EVENT:".count)).data(using: .utf8),
                  let event = try? JSONDecoder().decode(MLXEvent.self, from: data) else { continue }
            switch event.type {
            case "text": output += event.text ?? ""
            case "tool":
                guard let name = event.name, allowed.contains(name),
                      let arguments = event.arguments,
                      let object = try? JSONValue.parse(arguments).object,
                      calls.count < 16 else {
                    throw AgentError.message("MLX вернула недопустимый вызов инструмента")
                }
                calls.append(ToolCall(id: event.id ?? "call_\(UUID().uuidString)", name: name,
                                      arguments: JSONValue.object(object).encoded))
            case "error": throw AgentError.message("MLX: " + (event.text ?? "неизвестная ошибка"))
            case "done": completed = true
            default: break
            }
        }
        guard completed else { throw AgentError.message("MLX не завершила ответ") }
        if !calls.isEmpty { return LMReply(content: "", toolCalls: calls) }
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.message("MLX вернула пустой ответ; увеличьте лимит токенов или выберите другую модель")
        }
        return LlamaTextEngine.parseToolReply(output, allowed: allowed)
    }

    private static func inspect(_ source: URL) throws -> (type: String, vision: Bool, bytes: Int64, files: [String: String]) {
        let configURL = source.appendingPathComponent("config.json")
        guard let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any],
              let type = config["model_type"] as? String,
              ["qwen3_5", "gpt_oss"].contains(type) else {
            throw AgentError.message("Поддерживаются локальные MLX-модели Qwen3.5 и GPT-OSS")
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: source.path)
        guard names.contains("tokenizer_config.json"), names.contains(where: { $0.hasSuffix(".safetensors") }),
              names.count <= 100 else { throw AgentError.message("В MLX-папке нет токенизатора или весов") }
        var hashes: [String: String] = [:]
        var total: Int64 = 0
        for name in names {
            guard !name.hasPrefix("."), name != "..", !name.contains("/") else {
                throw AgentError.message("Некорректное имя файла MLX-модели")
            }
            let url = source.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw AgentError.message("MLX-модель должна содержать только обычные файлы")
            }
            let size = Int64(values.fileSize ?? 0)
            total += size
            guard total <= 24_000_000_000 else { throw AgentError.message("MLX-модель превышает бюджет памяти") }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var digest = SHA256()
            while let chunk = try file.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                digest.update(data: chunk)
            }
            hashes[name] = digest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        return (type, type == "qwen3_5" && config["vision_config"] != nil, total, hashes)
    }
}
