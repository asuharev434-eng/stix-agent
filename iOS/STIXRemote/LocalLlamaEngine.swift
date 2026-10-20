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
    private static let modelFile = "Qwen3-1.7B-Q4_K_M"
    private static let contextLength: Int32 = 4096
    private static let initialized: Bool = { llama_backend_init(); return true }()

    static var isInstalled: Bool {
        guard let url = modelURL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return false }
        return size > 500_000_000
    }

    private static var modelURL: URL? {
        Bundle.main.url(forResource: modelFile, withExtension: "gguf", subdirectory: "Models")
    }

    static func respond(to messages: [RemoteMessage]) async throws -> String {
        guard let url = modelURL, isInstalled else { throw LocalLlamaError.modelMissing }
        let prompt = format(messages)
        return try await Task.detached(priority: .userInitiated) {
            try generate(prompt: prompt, modelURL: url)
        }.value
    }

    private static func format(_ messages: [RemoteMessage]) -> String {
        let instruction = "Ты STIX, локальный помощник на iPhone. Отвечай на языке пользователя, кратко и по делу. Ты не подключён к Mac и не можешь выполнять команды Mac. Не утверждай, что выполнил действие, если не сделал его. /no_think"
        var result = "<|im_start|>system\n\(instruction)<|im_end|>\n"
        var remaining = 7_000
        for message in messages.reversed().prefix(10).reversed() where message.role == "user" || message.role == "assistant" {
            let text = String(message.text.prefix(min(remaining, 2_000)))
            guard !text.isEmpty else { continue }
            result += "<|im_start|>\(message.role)\n\(text)<|im_end|>\n"
            remaining -= text.count
            if remaining <= 0 { break }
        }
        return result + "<|im_start|>assistant\n"
    }

    private static func generate(prompt: String, modelURL: URL) throws -> String {
        _ = initialized
        try Task.checkCancellation()
        var parameters = llama_model_default_params()
        parameters.n_gpu_layers = 99
        guard let model = llama_model_load_from_file(modelURL.path, parameters) else {
            throw LocalLlamaError.modelLoadFailed
        }
        defer { llama_model_free(model) }
        var contextParameters = llama_context_default_params()
        contextParameters.n_ctx = UInt32(contextLength)
        contextParameters.n_batch = 256
        contextParameters.n_ubatch = 256
        contextParameters.n_threads = 4
        contextParameters.n_threads_batch = 4
        guard let context = llama_init_from_model(model, contextParameters) else {
            throw LocalLlamaError.contextFailed
        }
        defer { llama_free(context) }
        let vocabulary = llama_model_get_vocab(model)
        var tokens = [llama_token](repeating: 0, count: Int(contextLength))
        let count = tokens.withUnsafeMutableBufferPointer { buffer in
            prompt.withCString { pointer in
                llama_tokenize(vocabulary, pointer, Int32(prompt.utf8.count),
                               buffer.baseAddress, Int32(buffer.count), true, true)
            }
        }
        guard count > 0, count < contextLength - 256 else { throw LocalLlamaError.promptTooLong }
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
        let limit = min(768, Int(contextLength - count - 1))
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
            if step + 1 < limit {
                var next = token
                guard llama_decode(context, llama_batch_get_one(&next, 1)) == 0 else {
                    throw LocalLlamaError.decodeFailed
                }
            }
        }
        let raw = String(decoding: output, as: UTF8.self)
        let visible = raw.components(separatedBy: "</think>").last?
            .replacingOccurrences(of: "<|im_end|>", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !visible.isEmpty else { throw LocalLlamaError.emptyResponse }
        return visible
    }
}
