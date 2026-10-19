import CryptoKit
import Darwin
import Foundation

private typealias LlamaPieceCallback = @convention(c) (UnsafePointer<CChar>?, Int, UnsafeMutableRawPointer?) -> Int32
private typealias LlamaLoad = @convention(c) (UnsafePointer<CChar>, UInt32, UnsafeMutablePointer<CChar>, Int) -> UnsafeMutableRawPointer?
private typealias LlamaContextLength = @convention(c) (UnsafeMutableRawPointer?) -> UInt32
private typealias LlamaGenerate = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>, UInt32, LlamaPieceCallback,
                                                  UnsafeMutableRawPointer?, UnsafeMutablePointer<CChar>, Int) -> Int32
private typealias LlamaUnload = @convention(c) (UnsafeMutableRawPointer?) -> Void

private final class LlamaLibrary: @unchecked Sendable {
    let handle: UnsafeMutableRawPointer
    let load: LlamaLoad
    let contextLength: LlamaContextLength
    let generate: LlamaGenerate
    let unload: LlamaUnload

    init(at url: URL) throws {
        guard let handle = dlopen(url.path, RTLD_NOW | RTLD_LOCAL) else {
            let detail = dlerror().map { String(cString: $0) } ?? "unknown dlopen error"
            throw AgentError.message("Не удалось открыть встроенный llama.cpp: \(detail)")
        }
        func symbol<T>(_ name: String, as type: T.Type) throws -> T {
            guard let pointer = dlsym(handle, name) else {
                throw AgentError.message("Встроенный llama.cpp не содержит \(name)")
            }
            return unsafeBitCast(pointer, to: type)
        }
        do {
            load = try symbol("stix_llama_load", as: LlamaLoad.self)
            contextLength = try symbol("stix_llama_context_length", as: LlamaContextLength.self)
            generate = try symbol("stix_llama_generate", as: LlamaGenerate.self)
            unload = try symbol("stix_llama_unload", as: LlamaUnload.self)
            self.handle = handle
        } catch {
            dlclose(handle)
            throw error
        }
    }

    deinit { dlclose(handle) }
}

private final class LlamaCallbackState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var pending = Data()
    let continuation: AsyncThrowingStream<String, Error>.Continuation

    init(_ continuation: AsyncThrowingStream<String, Error>.Continuation) {
        self.continuation = continuation
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func accept(_ bytes: UnsafePointer<CChar>?, count: Int) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return 0 }
        guard let bytes, count > 0 else { return 1 }
        pending.append(contentsOf: UnsafeRawBufferPointer(start: bytes, count: count))
        if let text = String(data: pending, encoding: .utf8) {
            continuation.yield(text)
            pending.removeAll(keepingCapacity: true)
        } else if pending.count > 1024 {
            cancelled = true
            return 0
        }
        return 1
    }
    func finish(_ error: Error? = nil) {
        lock.lock()
        let trailing = pending
        pending.removeAll()
        lock.unlock()
        if let error { continuation.finish(throwing: error) }
        else if !trailing.isEmpty { continuation.finish(throwing: AgentError.message("Модель вернула повреждённый UTF-8")) }
        else { continuation.finish() }
    }
}

private let llamaCallback: LlamaPieceCallback = { bytes, count, user in
    guard let user else { return 0 }
    return Unmanaged<LlamaCallbackState>.fromOpaque(user).takeUnretainedValue().accept(bytes, count: count)
}

/// One actor owns one native context. The app never opens a localhost inference server.
actor LlamaTextEngine: TextInferenceEngine {
    let modelID: String
    let modelURL: URL
    let expectedSHA256: String
    let libraryURL: URL
    let requestedContext: UInt32
    private var validated = false
    private var library: LlamaLibrary?
    private var nativeHandle: Int?
    private var loading: Task<(LlamaLibrary, Int), Error>?
    private var loadingWaiters = 0
    private var busy = false

    init(modelID: String, modelURL: URL, expectedSHA256: String, libraryURL: URL,
         contextLength: UInt32 = 32768) {
        self.modelID = modelID
        self.modelURL = modelURL
        self.expectedSHA256 = expectedSHA256
        self.libraryURL = libraryURL
        requestedContext = contextLength
    }

    static func bundled() -> LlamaTextEngine? {
        guard let resourceURL = Bundle.main.resourceURL,
              let frameworkURL = Bundle.main.privateFrameworksURL else { return nil }
        let modelURL = resourceURL.appendingPathComponent("Models/Qwen3-1.7B-Q4_K_M.gguf")
        guard FileManager.default.fileExists(atPath: modelURL.path) else { return nil }
        return LlamaTextEngine(modelID: "qwen3-1.7b-q4_k_m", modelURL: modelURL,
                               expectedSHA256: "d2387ca2dbfee2ffabce7120d3770dadca0b293052bc2f0e138fdc940d9bc7b5",
                               libraryURL: frameworkURL.appendingPathComponent("libSTIXLlama.dylib"))
    }

    func models() async throws -> [ModelDescriptor] {
        try validateAsset()
        return [ModelDescriptor(id: "builtin-text:" + modelID, kind: "text", contextLimit: Int(requestedContext))]
    }

    func prepare(model: String) async throws -> Int? {
        guard model == modelID else { throw AgentError.message("Встроенная модель не найдена: \(model)") }
        try validateAsset()
        if let nativeHandle, let library {
            return Int(library.contextLength(UnsafeMutableRawPointer(bitPattern: nativeHandle)))
        }
        let task: Task<(LlamaLibrary, Int), Error>
        if let loading { task = loading }
        else {
            let modelURL = self.modelURL
            let libraryURL = self.libraryURL
            let requestedContext = self.requestedContext
            task = Task.detached(priority: .userInitiated) {
                let library = try LlamaLibrary(at: libraryURL)
                var error = [CChar](repeating: 0, count: 1024)
                guard let handle = modelURL.path.withCString({ library.load($0, requestedContext, &error, error.count) }) else {
                    throw AgentError.message(String(cString: error))
                }
                return (library, Int(bitPattern: handle))
            }
            loading = task
        }
        loadingWaiters += 1
        defer {
            loadingWaiters -= 1
            if loadingWaiters == 0 { loading = nil }
        }
        let (library, raw) = try await task.value
        self.library = library
        nativeHandle = raw
        return Int(library.contextLength(UnsafeMutableRawPointer(bitPattern: raw)))
    }

    func complete(model: String, messages: [LMMessage], tools: [ToolDefinition],
                  maxOutputTokens: Int?, preserveContext: Bool, thinking: Bool,
                  onPhase: @escaping @Sendable (String) async -> Void,
                  onRequest: @escaping @Sendable ([LMMessage]) async -> Void,
                  onReasoning: @escaping @Sendable (String) async -> Void,
                  onText: @escaping @Sendable (String) async -> Void) async throws -> LMReply {
        guard !busy else { throw AgentError.message("Встроенная модель уже выполняет запрос") }
        busy = true
        defer { busy = false }
        await onPhase("Загрузка встроенной модели…")
        _ = try await prepare(model: model)
        guard let nativeHandle, let library else { throw AgentError.message("Встроенная модель не загрузилась") }
        try Task.checkCancellation()
        let wire = try Self.wireMessages(messages, tools: tools, thinking: thinking)
        await onRequest(messages)
        await onPhase("Модель формирует ответ…")
        let outputLimit = UInt32(min(max(1, maxOutputTokens ?? 2048), 32768))
        var callbackState: LlamaCallbackState?
        let stream = AsyncThrowingStream<String, Error> { continuation in
            let state = LlamaCallbackState(continuation)
            callbackState = state
            Task.detached(priority: .userInitiated) {
                var error = [CChar](repeating: 0, count: 1024)
                let user = Unmanaged.passRetained(state).toOpaque()
                defer { Unmanaged<LlamaCallbackState>.fromOpaque(user).release() }
                let result = wire.withCString {
                    library.generate(UnsafeMutableRawPointer(bitPattern: nativeHandle), $0,
                                     outputLimit, llamaCallback, user, &error, error.count)
                }
                if result < 0 { state.finish(AgentError.message(String(cString: error))) }
                else { state.finish() }
            }
        }
        guard let callbackState else { throw AgentError.message("Не удалось запустить встроенную модель") }
        var parser = ThinkingStream()
        var answer = ""
        try await withTaskCancellationHandler {
            for try await chunk in stream {
                try Task.checkCancellation()
                let delta = parser.consume(chunk)
                answer += delta.text
                if !delta.text.isEmpty, tools.isEmpty { await onText(delta.text) }
                if thinking, !delta.reasoning.isEmpty { await onReasoning(delta.reasoning) }
            }
        } onCancel: { callbackState.cancel() }
        let final = parser.consume("", finishing: true)
        answer += final.text
        if !final.text.isEmpty, tools.isEmpty { await onText(final.text) }
        if thinking, !final.reasoning.isEmpty { await onReasoning(final.reasoning) }
        let parsed = Self.parseToolReply(answer, allowed: Set(tools.map(\.name)))
        if parsed.toolCalls.isEmpty, !tools.isEmpty { await onText(parsed.content) }
        return parsed
    }

    func release() {
        guard !busy, loadingWaiters == 0, let raw = nativeHandle, let library else { return }
        library.unload(UnsafeMutableRawPointer(bitPattern: raw))
        nativeHandle = nil
        self.library = nil
    }

    private func validateAsset() throws {
        guard !validated else { return }
        guard FileManager.default.fileExists(atPath: modelURL.path),
              FileManager.default.fileExists(atPath: libraryURL.path) else {
            throw AgentError.message("Встроенная модель или её движок отсутствует в сборке")
        }
        guard modelURL.pathExtension.lowercased() == "gguf", expectedSHA256.count == 64 else {
            throw AgentError.message("Некорректный manifest встроенной модели")
        }
        let file = try FileHandle(forReadingFrom: modelURL)
        defer { try? file.close() }
        var digest = SHA256()
        while true {
            let chunk = try file.read(upToCount: 4 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            digest.update(data: chunk)
        }
        let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == expectedSHA256 else {
            throw AgentError.message("Хеш встроенной модели не совпадает с manifest; сборка повреждена")
        }
        validated = true
    }

    private static func wireMessages(_ messages: [LMMessage], tools: [ToolDefinition], thinking: Bool) throws -> String {
        guard !messages.isEmpty, messages.count <= 512 else { throw AgentError.message("Слишком длинная история для встроенной модели") }
        guard messages.allSatisfy({ ($0.imageURLs ?? []).isEmpty }) else {
            throw AgentError.message("Эта встроенная текстовая модель не поддерживает изображения")
        }
        var mapped: [[String: String]] = messages.map { message in
            let role = message.role == "tool" ? "user" : message.role
            var content = message.content ?? ""
            if message.role == "tool" { content = "Результат инструмента \(message.toolCallID ?? ""): \(content)" }
            if !message.toolCalls.isEmpty {
                content += "\nВызовы инструментов: " + message.toolCalls.map {
                    "{\"id\":\"\($0.id)\",\"name\":\"\($0.name)\",\"arguments\":\($0.arguments)}"
                }.joined(separator: ",")
            }
            return ["role": role, "content": content]
        }
        if !tools.isEmpty {
            let toolList = tools.map { $0.wire.encoded }.joined(separator: "\n")
            let instruction = """
            Доступные инструменты (JSON Schema):
            \(toolList)
            Если нужен инструмент, верни только JSON: {"tool_calls":[{"name":"имя", "arguments":{...}}]}. Не утверждай о выполнении до результата инструмента. Если инструмент не нужен, отвечай обычным текстом.
            """
            if mapped.first?["role"] == "system" { mapped[0]["content", default: ""] += "\n\n" + instruction }
            else { mapped.insert(["role": "system", "content": instruction], at: 0) }
        }
        if !thinking, let lastUser = mapped.lastIndex(where: { $0["role"] == "user" }) {
            mapped[lastUser]["content", default: ""] += "\n/no_think"
        }
        return try String(data: JSONEncoder().encode(mapped), encoding: .utf8) ?? "[]"
    }

    static func parseToolReply(_ answer: String, allowed: Set<String>) -> LMReply {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if trimmed.hasPrefix("```"), trimmed.hasSuffix("```"),
           let newline = trimmed.firstIndex(of: "\n") {
            let opener = String(trimmed[..<newline])
            candidate = (opener == "```" || opener == "```json")
                ? String(trimmed[trimmed.index(after: newline)..<trimmed.index(trimmed.endIndex, offsetBy: -3)])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                : trimmed
        } else { candidate = trimmed }
        guard !allowed.isEmpty, let json = try? JSONValue.parse(candidate),
              let calls = json["tool_calls"].array, !calls.isEmpty, calls.count <= 16 else {
            return LMReply(content: trimmed, toolCalls: [])
        }
        var parsed: [ToolCall] = []
        for call in calls {
            guard let name = call["name"].string, allowed.contains(name),
                  let arguments = call["arguments"].object else {
                return LMReply(content: trimmed, toolCalls: [])
            }
            let args = JSONValue.object(arguments).encoded
            parsed.append(ToolCall(id: call["id"].string ?? "call_\(UUID().uuidString)", name: name, arguments: args))
        }
        return LMReply(content: "", toolCalls: parsed)
    }
}
