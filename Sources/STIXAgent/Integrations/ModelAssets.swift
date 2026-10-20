import CryptoKit
import Foundation

struct ImportedGGUF: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let fileName: String
    let sha256: String
    let bytes: Int64
    let architecture: String
    let tokenizer: String
    let contextLength: Int
    let projectorFileName: String?
    let projectorSHA256: String?

    init(id: String, name: String, fileName: String, sha256: String, bytes: Int64,
         architecture: String, tokenizer: String, contextLength: Int,
         projectorFileName: String? = nil, projectorSHA256: String? = nil) {
        self.id = id; self.name = name; self.fileName = fileName; self.sha256 = sha256; self.bytes = bytes
        self.architecture = architecture; self.tokenizer = tokenizer; self.contextLength = contextLength
        self.projectorFileName = projectorFileName; self.projectorSHA256 = projectorSHA256
    }
}

/// Reads the GGUF metadata table without allocating tensor or tokenizer data.
enum GGUFInspector {
    struct Metadata {
        let architecture: String
        let tokenizer: String
        let contextLength: Int
        let name: String
    }

    static func inspect(_ url: URL) throws -> Metadata {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = Int64((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0)
        guard size >= 1024 else { throw AgentError.message("Файл GGUF слишком мал") }
        var offset: UInt64 = 0
        func bytes(_ count: Int) throws -> Data {
            guard count >= 0, UInt64(count) <= UInt64(size) - offset else { throw AgentError.message("Повреждена таблица GGUF") }
            let result = try file.read(upToCount: count) ?? Data()
            guard result.count == count else { throw AgentError.message("Файл GGUF обрезан") }
            offset += UInt64(count)
            return result
        }
        func number<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
            let data = try bytes(MemoryLayout<T>.size)
            return T(littleEndian: data.withUnsafeBytes { $0.loadUnaligned(as: T.self) })
        }
        func skip(_ count: UInt64) throws {
            guard count <= UInt64(size) - offset else { throw AgentError.message("Повреждена таблица GGUF") }
            offset += count
            try file.seek(toOffset: offset)
        }
        func string(collect: Bool) throws -> String {
            let count: UInt64 = try number(UInt64.self)
            guard count <= 16_777_216 else { throw AgentError.message("Некорректная строка GGUF") }
            if !collect { try skip(count); return "" }
            guard let value = String(data: try bytes(Int(count)), encoding: .utf8) else {
                throw AgentError.message("Некорректный текст метаданных GGUF")
            }
            return value
        }
        func value(_ type: UInt32, collect: Bool, depth: Int = 0) throws -> String {
            guard depth <= 2 else { throw AgentError.message("Некорректный массив GGUF") }
            switch type {
            case 0, 1, 7: let n: UInt8 = try number(UInt8.self); return collect ? String(n) : ""
            case 2, 3: let n: UInt16 = try number(UInt16.self); return collect ? String(n) : ""
            case 4, 5, 6: let n: UInt32 = try number(UInt32.self); return collect ? String(n) : ""
            case 8: return try string(collect: collect)
            case 9:
                let element: UInt32 = try number(UInt32.self)
                let count: UInt64 = try number(UInt64.self)
                guard count <= 10_000_000 else { throw AgentError.message("Массив GGUF слишком велик") }
                for _ in 0..<count { _ = try value(element, collect: false, depth: depth + 1) }
                return ""
            case 10, 11, 12: let n: UInt64 = try number(UInt64.self); return collect ? String(n) : ""
            default: throw AgentError.message("Неподдерживаемый тип метаданных GGUF: \(type)")
            }
        }
        guard try bytes(4) == Data("GGUF".utf8) else { throw AgentError.message("Это не файл GGUF") }
        let version: UInt32 = try number(UInt32.self)
        guard version == 3 else { throw AgentError.message("Поддерживается GGUF версии 3; версия файла: \(version)") }
        let tensors: UInt64 = try number(UInt64.self)
        let entries: UInt64 = try number(UInt64.self)
        guard tensors > 0, entries > 0, entries < 1_000_000 else { throw AgentError.message("Некорректный заголовок GGUF") }
        var found: [String: String] = [:]
        for _ in 0..<entries {
            let key = try string(collect: true)
            let type: UInt32 = try number(UInt32.self)
            let wanted = key == "general.architecture" || key == "general.name" || key == "tokenizer.ggml.model" || key.hasSuffix(".context_length")
            let val = try value(type, collect: wanted)
            if wanted { found[key] = val }
        }
        guard let architecture = found["general.architecture"],
              ["gpt2", "qwen3", "qwen3moe", "qwen35", "qwen35moe", "qwen2", "llama", "gemma", "gemma3", "gemma4", "gpt-oss", "gpt_oss", "mistral", "phi3", "phi4"].contains(architecture),
              let tokenizer = found["tokenizer.ggml.model"], !tokenizer.isEmpty else {
            throw AgentError.message("Архитектура или токенизатор GGUF не поддерживаются встроенным текстовым движком")
        }
        let context = Int(found["\(architecture).context_length"] ?? "") ?? 0
        let minimumContext = architecture == "gpt2" ? 128 : 2048
        guard (minimumContext...262_144).contains(context) else { throw AgentError.message("Некорректное контекстное окно GGUF") }
        return Metadata(architecture: architecture, tokenizer: tokenizer, contextLength: context,
                        name: found["general.name"] ?? url.deletingPathExtension().lastPathComponent)
    }
}

/// Imported files are app-owned copies. A failed import never changes the manifest or selection.
actor LocalModelLibrary: TextInferenceEngine {
    let bundled: LlamaTextEngine?
    let directory: URL
    let libraryURL: URL?
    let visionExecutable: URL?
    private var imported: [ImportedGGUF] = []
    private var engines: [String: LlamaTextEngine] = [:]
    private var initialized = false

    init(bundled: LlamaTextEngine?, directory: URL, libraryURL: URL?, visionExecutable: URL? = nil) {
        self.bundled = bundled
        self.directory = directory
        self.libraryURL = libraryURL
        self.visionExecutable = visionExecutable
    }

    static func live(paths: AppStoragePaths) -> LocalModelLibrary {
        LocalModelLibrary(bundled: LlamaTextEngine.bundled(), directory: paths.models,
                          libraryURL: Bundle.main.privateFrameworksURL?.appendingPathComponent("libSTIXLlama.dylib"),
                          visionExecutable: Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("stix-mtmd-cli"))
    }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    private func initialize() throws {
        guard !initialized else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            imported = try JSONDecoder().decode([ImportedGGUF].self, from: Data(contentsOf: manifestURL))
        }
        initialized = true
    }

    func models() async throws -> [ModelDescriptor] {
        try initialize()
        let defaults = try await bundled?.models() ?? []
        return defaults + imported.map {
            ModelDescriptor(id: "builtin-text:" + $0.id, kind: "text",
                            contextLimit: min($0.contextLength, $0.bytes > 12 * 1024 * 1024 * 1024 ? 4096 : 32768),
                            displayName: $0.name + " · импортирована")
        }
    }

    func importedModels() throws -> [ImportedGGUF] {
        try initialize()
        return imported
    }

    func importFile(_ source: URL) async throws -> ImportedGGUF {
        try initialize()
        guard let libraryURL, FileManager.default.fileExists(atPath: libraryURL.path) else {
            throw AgentError.message("Встроенный движок GGUF отсутствует в сборке")
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard source.isFileURL, source.pathExtension.lowercased() == "gguf" else {
            throw AgentError.message("Выберите локальный файл .gguf")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw AgentError.message("Выберите обычный файл модели, а не ссылку")
        }
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let limit = min(Int64(ProcessInfo.processInfo.physicalMemory * 78 / 100), 24 * 1024 * 1024 * 1024)
        guard size > 0, size <= limit else { throw AgentError.message("Размер модели превышает безопасный бюджет памяти этого Mac") }
        let temporary = directory.appendingPathComponent(".import-" + UUID().uuidString + ".gguf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        guard (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value == size else {
            throw AgentError.message("Файл изменился во время импорта")
        }
        let info = try GGUFInspector.inspect(temporary)
        let file = try FileHandle(forReadingFrom: temporary)
        defer { try? file.close() }
        var hash = SHA256()
        while let chunk = try file.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
        }
        let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
        if let old = imported.first(where: { $0.sha256 == digest }) { return old }
        let id = "imported-" + String(digest.prefix(16))
        let fileName = id + ".gguf"
        let target = directory.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw AgentError.message("Конфликт файла импортированной модели") }
        let companions = try FileManager.default.contentsOfDirectory(at: source.deletingLastPathComponent(),
                                                                      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            .filter { $0.lastPathComponent.hasPrefix("mmproj-") && $0.pathExtension.lowercased() == "gguf" }
        guard companions.count <= 1 else { throw AgentError.message("Найдено несколько vision-проекторов рядом с моделью") }
        var stagedProjector: URL?
        var projectorName: String?
        var projectorHash: String?
        if let companion = companions.first {
            let values = try companion.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  let size = values.fileSize, (1024...2_000_000_000).contains(size) else {
                throw AgentError.message("Некорректный vision-проектор GGUF")
            }
            let staged = directory.appendingPathComponent(".import-" + UUID().uuidString + "-mmproj.gguf")
            stagedProjector = staged
            try FileManager.default.copyItem(at: companion, to: staged)
            guard (try FileManager.default.attributesOfItem(atPath: staged.path)[.size] as? NSNumber)?.intValue == size else {
                throw AgentError.message("Vision-проектор изменился во время импорта")
            }
            let projectorFile = try FileHandle(forReadingFrom: staged)
            defer { try? projectorFile.close() }
            guard try projectorFile.read(upToCount: 4) == Data("GGUF".utf8) else {
                throw AgentError.message("Vision-проектор не является GGUF")
            }
            try projectorFile.seek(toOffset: 0)
            var projectorDigest = SHA256()
            while let chunk = try projectorFile.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
                try Task.checkCancellation()
                projectorDigest.update(data: chunk)
            }
            projectorName = id + "-mmproj.gguf"
            projectorHash = projectorDigest.finalize().map { String(format: "%02x", $0) }.joined()
        }
        defer { if let stagedProjector { try? FileManager.default.removeItem(at: stagedProjector) } }
        let record = ImportedGGUF(id: id, name: info.name, fileName: fileName, sha256: digest,
                                  bytes: size, architecture: info.architecture, tokenizer: info.tokenizer,
                                  contextLength: info.contextLength, projectorFileName: projectorName,
                                  projectorSHA256: projectorHash)
        try FileManager.default.moveItem(at: temporary, to: target)
        if let stagedProjector, let projectorName {
            do { try FileManager.default.moveItem(at: stagedProjector, to: directory.appendingPathComponent(projectorName)) }
            catch { try? FileManager.default.removeItem(at: target); throw error }
        }
        do {
            try JSONEncoder().encode(imported + [record]).write(to: manifestURL, options: .atomic)
            imported.append(record)
        } catch {
            try? FileManager.default.removeItem(at: target)
            if let projectorName { try? FileManager.default.removeItem(at: directory.appendingPathComponent(projectorName)) }
            throw error
        }
        return record
    }

    func remove(_ id: String) async throws {
        try initialize()
        guard let record = imported.first(where: { $0.id == id }) else { throw AgentError.message("Модель не найдена") }
        if let engine = engines[id] { await engine.release() }
        let target = directory.appendingPathComponent(record.fileName)
        let next = imported.filter { $0.id != id }
        try JSONEncoder().encode(next).write(to: manifestURL, options: .atomic)
        imported = next
        engines[id] = nil
        try FileManager.default.removeItem(at: target)
        if let projectorName = record.projectorFileName {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(projectorName))
        }
    }

    func releaseAll() async {
        await bundled?.release()
        for engine in engines.values { await engine.release() }
    }

    private func engine(_ model: String) throws -> LlamaTextEngine {
        try initialize()
        if model == bundled?.modelID, let bundled { return bundled }
        if let existing = engines[model] { return existing }
        guard let record = imported.first(where: { $0.id == model }), let libraryURL else {
            throw AgentError.message("Локальная модель недоступна: \(model)")
        }
        let item = LlamaTextEngine(modelID: model, modelURL: directory.appendingPathComponent(record.fileName),
                                   expectedSHA256: record.sha256, libraryURL: libraryURL,
                                   contextLength: UInt32(min(record.bytes > 12 * 1024 * 1024 * 1024 ? 4096 : 32768,
                                                             record.contextLength)))
        engines[model] = item
        return item
    }

    func prepare(model: String) async throws -> Int? {
        if model != bundled?.modelID { await bundled?.release() }
        for (id, other) in engines where id != model { await other.release() }
        try initialize()
        if let record = imported.first(where: { $0.id == model }), record.projectorFileName != nil {
            return min(record.contextLength, 32768)
        }
        return try await engine(model).prepare(model: model)
    }
    func complete(model: String, messages: [LMMessage], tools: [ToolDefinition],
                  maxOutputTokens: Int?, preserveContext: Bool, thinking: Bool,
                  onPhase: @escaping @Sendable (String) async -> Void,
                  onRequest: @escaping @Sendable ([LMMessage]) async -> Void,
                  onReasoning: @escaping @Sendable (String) async -> Void,
                  onText: @escaping @Sendable (String) async -> Void) async throws -> LMReply {
        try initialize()
        if messages.contains(where: { !($0.imageURLs ?? []).isEmpty }) {
            guard let record = imported.first(where: { $0.id == model }),
                  let projectorName = record.projectorFileName,
                  let projectorSHA256 = record.projectorSHA256,
                  let visionExecutable else {
                throw AgentError.message("Эта локальная GGUF-модель не поддерживает изображения")
            }
            await bundled?.release()
            for other in engines.values { await other.release() }
            return try await LocalGGUFVisionEngine(executable: visionExecutable,
                                                   model: directory.appendingPathComponent(record.fileName),
                                                   projector: directory.appendingPathComponent(projectorName),
                                                   projectorSHA256: projectorSHA256)
                .complete(messages: messages, tools: tools, maxOutputTokens: maxOutputTokens,
                          thinking: thinking, onPhase: onPhase, onRequest: onRequest,
                          onReasoning: onReasoning, onText: onText)
        }
        if model != bundled?.modelID { await bundled?.release() }
        for (id, other) in engines where id != model { await other.release() }
        return try await engine(model).complete(model: model, messages: messages, tools: tools,
                                                 maxOutputTokens: maxOutputTokens, preserveContext: preserveContext,
                                                 thinking: thinking, onPhase: onPhase, onRequest: onRequest,
                                                 onReasoning: onReasoning, onText: onText)
    }
}
