import Foundation
import llama

enum LocalLlamaError: LocalizedError {
    case modelMissing
    case modelLoadFailed
    case contextFailed
    case promptTooLong
    case decodeFailed
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .modelMissing: "Локальная модель не установлена в приложении."
        case .modelLoadFailed: "iPhone не смог загрузить локальную модель."
        case .contextFailed: "Не удалось выделить память для локальной модели."
        case .promptTooLong: "Локальный контекст заполнен. Начните новую тему."
        case .decodeFailed: "Локальная модель прервала генерацию ответа."
        case .emptyResponse: "Локальная модель не вернула ответ. Попробуйте переформулировать запрос."
        }
    }
}

/// Inference is isolated from the main actor; no network or Mac connection is used.
enum LocalLlamaEngine {
    static let modelName = "Qwen3 1.7B · iPhone"
    private static let contextLength: Int32 = 8192
    private static let imagePromptContextLength: Int32 = 2048
    private static let initialized: Bool = { llama_backend_init(); return true }()

    static func start(messages: [RemoteMessage], modelURL: URL,
                      imagePrompt: Bool = false) -> LocalGeneration {
        let (stream, continuation) = AsyncThrowingStream<String, Error>.makeStream()
        let worker = Task.detached(priority: .userInitiated) {
            do {
                try generate(messages: messages, modelURL: modelURL,
                             imagePrompt: imagePrompt) { continuation.yield($0) }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { @Sendable _ in worker.cancel() }
        return LocalGeneration(stream: stream, cancel: { worker.cancel() })
    }

    private static func format(_ messages: [RemoteMessage], characterBudget: Int,
                               model: OpaquePointer, useBuiltInTemplate: Bool,
                               smallContext: Bool) -> String {
        if smallContext {
            let latest = messages.last(where: { $0.role == "user" })?.text ?? ""
            return "Вопрос: \(String(latest.suffix(min(characterBudget, 160))))\nОтвет: "
        }
        let instruction = "Ты STIX, локальный помощник на iPhone. Отвечай на языке пользователя, кратко и по делу. Ты не подключён к Mac и не можешь выполнять команды Mac. Не утверждай, что выполнил действие, если не сделал его. /no_think"
        var selected: [(role: String, text: String)] = []
        var remaining = characterBudget
        for message in messages.reversed().prefix(24) where message.role == "user" || message.role == "assistant" {
            let text = String(message.text.suffix(min(remaining, 2_000)))
            guard !text.isEmpty else { continue }
            selected.append((message.role, text))
            remaining -= text.count
            if remaining <= 0 { break }
        }
        let ordered = selected.reversed()
        if !useBuiltInTemplate, let template = llama_model_chat_template(model, nil) {
            let entries = [(role: "system", text: instruction)] + ordered
            let owned = entries.map { (strdup($0.role), strdup($0.text)) }
            defer { for pair in owned { free(pair.0); free(pair.1) } }
            var chat = owned.map { llama_chat_message(role: UnsafePointer($0.0),
                                                       content: UnsafePointer($0.1)) }
            var output = [CChar](repeating: 0, count: max(4_096, characterBudget * 3))
            var length = chat.withUnsafeMutableBufferPointer { buffer in
                output.withUnsafeMutableBufferPointer { result in
                    llama_chat_apply_template(template, buffer.baseAddress, buffer.count,
                                              true, result.baseAddress, Int32(result.count))
                }
            }
            if length > output.count {
                output = [CChar](repeating: 0, count: Int(length) + 1)
                length = chat.withUnsafeMutableBufferPointer { buffer in
                    output.withUnsafeMutableBufferPointer { result in
                        llama_chat_apply_template(template, buffer.baseAddress, buffer.count,
                                                  true, result.baseAddress, Int32(result.count))
                    }
                }
            }
            if length > 0 && length <= output.count {
                return String(decoding: output.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            }
        }
        return "<|im_start|>system\n\(instruction)<|im_end|>\n"
            + ordered.map { "<|im_start|>\($0.role)\n\($0.text)<|im_end|>\n" }.joined()
            + "<|im_start|>assistant\n"
    }

    private static func generate(messages: [RemoteMessage], modelURL: URL,
                                 imagePrompt: Bool,
                                 onText: (String) -> Void) throws {
        _ = initialized
        try Task.checkCancellation()
        guard FileManager.default.fileExists(atPath: modelURL.path) else { throw LocalLlamaError.modelMissing }
        var parameters = llama_model_default_params()
        parameters.n_gpu_layers = imagePrompt ? 0 : 99
        guard let model = llama_model_load_from_file(modelURL.path, parameters) else {
            throw LocalLlamaError.modelLoadFailed
        }
        defer { llama_model_free(model) }
        var contextParameters = llama_context_default_params()
        let requestedLength = imagePrompt ? imagePromptContextLength : contextLength
        let activeContextLength = max(128, min(requestedLength, llama_model_n_ctx_train(model)))
        contextParameters.n_ctx = UInt32(activeContextLength)
        contextParameters.n_batch = 256
        contextParameters.n_ubatch = 256
        contextParameters.n_threads = 4
        contextParameters.n_threads_batch = 4
        guard let context = llama_init_from_model(model, contextParameters) else {
            throw LocalLlamaError.contextFailed
        }
        defer { llama_free(context) }
        let vocabulary = llama_model_get_vocab(model)
        var tokens = [llama_token](repeating: 0, count: Int(activeContextLength))
        var characterBudget = imagePrompt ? 1_500 : 16_000
        let reserve = min(imagePrompt ? 160 : 1_024, max(32, activeContextLength / 4))
        var count: Int32 = 0
        while characterBudget >= 16 {
            let prompt = format(messages, characterBudget: characterBudget, model: model,
                                useBuiltInTemplate: modelURL.lastPathComponent == "Qwen3-1.7B-Q4_K_M.gguf",
                                smallContext: activeContextLength <= 512)
            count = tokens.withUnsafeMutableBufferPointer { buffer in
                prompt.withCString { pointer in
                    llama_tokenize(vocabulary, pointer, Int32(prompt.utf8.count),
                                   buffer.baseAddress, Int32(buffer.count), true, true)
                }
            }
            if count > 0 && count < activeContextLength - reserve { break }
            characterBudget /= 2
        }
        guard count > 0, count < activeContextLength - reserve else {
            throw LocalLlamaError.promptTooLong
        }
        for offset in stride(from: 0, to: Int(count), by: 256) {
            try Task.checkCancellation()
            let length = min(256, Int(count) - offset)
            let decoded = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress!.advanced(by: offset), Int32(length)))
            }
            guard decoded == 0 else { throw LocalLlamaError.decodeFailed }
        }
        let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params())
        guard let sampler else { throw LocalLlamaError.decodeFailed }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.6))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(42))
        var output = Data()
        let limit = min(imagePrompt ? 160 : 1_024, Int(activeContextLength - count - 1))
        for step in 0..<limit {
            try Task.checkCancellation()
            let token = llama_sampler_sample(sampler, context, -1)
            llama_sampler_accept(sampler, token)
            if llama_vocab_is_eog(vocabulary, token) { break }
            var piece = [CChar](repeating: 0, count: 512)
            var length = piece.withUnsafeMutableBufferPointer {
                llama_token_to_piece(vocabulary, token, $0.baseAddress, Int32($0.count), 0, false)
            }
            if length < 0 {
                piece = [CChar](repeating: 0, count: Int(-length))
                length = piece.withUnsafeMutableBufferPointer {
                    llama_token_to_piece(vocabulary, token, $0.baseAddress, Int32($0.count), 0, false)
                }
            }
            guard length >= 0 else { throw LocalLlamaError.decodeFailed }
            output.append(contentsOf: piece.prefix(Int(length)).map { UInt8(bitPattern: $0) })
            if step % 4 == 0 {
                let text = visibleText(output)
                if !text.isEmpty { onText(text) }
            }
            if step + 1 < limit {
                var next = token
                guard llama_decode(context, llama_batch_get_one(&next, 1)) == 0 else {
                    throw LocalLlamaError.decodeFailed
                }
            }
        }
        let visible = visibleText(output)
        guard !visible.isEmpty else { throw LocalLlamaError.emptyResponse }
        onText(visible)
    }

    private static func visibleText(_ output: Data) -> String {
        let raw = String(decoding: output, as: UTF8.self)
        if raw.contains("<think>") && !raw.contains("</think>") { return "" }
        return raw.components(separatedBy: "</think>").last?
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

struct LocalGeneration {
    let stream: AsyncThrowingStream<String, Error>
    let cancel: () -> Void
}
