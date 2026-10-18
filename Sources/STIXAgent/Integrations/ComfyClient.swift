import Foundation

struct ComfyClient: Sendable {
    let endpoint: String
    init(endpoint: String) { self.endpoint = endpoint }

    func checkpoints() async throws -> [String] {
        let info = try await request("object_info/CheckpointLoaderSimple")
        guard let names = info["CheckpointLoaderSimple"]["input"]["required"]["ckpt_name"].array?.first?.array else {
            throw AgentError.message("ComfyUI не предоставил список checkpoint-моделей")
        }
        return names.compactMap(\.string)
    }

    static func workflow(prompt: String, checkpoint: String, seed: Int = Int.random(in: 0...Int(Int32.max))) -> JSONValue {
        func link(_ id: String, _ slot: Int = 0) -> JSONValue { .array([.string(id), .number(Double(slot))]) }
        func node(_ type: String, _ inputs: [String: JSONValue]) -> JSONValue {
            .object(["class_type": .string(type), "inputs": .object(inputs)])
        }
        return .object([
            "1": node("CheckpointLoaderSimple", ["ckpt_name": .string(checkpoint)]),
            "2": node("CLIPTextEncode", ["text": .string(prompt), "clip": link("1", 1)]),
            "3": node("CLIPTextEncode", ["text": .string("low quality, blurry, distorted, watermark"), "clip": link("1", 1)]),
            "4": node("EmptyLatentImage", ["width": .number(1024), "height": .number(1024), "batch_size": .number(1)]),
            "5": node("KSampler", ["model": link("1"), "positive": link("2"), "negative": link("3"), "latent_image": link("4"), "seed": .number(Double(seed)), "steps": .number(20), "cfg": .number(7), "sampler_name": .string("euler"), "scheduler": .string("normal"), "denoise": .number(1)]),
            "6": node("VAEDecode", ["samples": link("5"), "vae": link("1", 2)]),
            "7": node("SaveImage", ["images": link("6"), "filename_prefix": .string("STIXAgent")])
        ])
    }

    static func bindWorkflow(_ template: JSONValue, prompt: String, checkpoint: String, seed: UInt64) throws -> JSONValue {
        guard let nodes = template.object, !nodes.isEmpty, nodes.count <= 500 else {
            throw AgentError.message("API workflow должен содержать от 1 до 500 узлов")
        }
        var foundPrompt = false
        var foundSaveImage = false
        func bind(_ value: JSONValue, depth: Int = 0) throws -> JSONValue {
            guard depth <= 100 else { throw AgentError.message("Workflow содержит слишком глубокую структуру") }
            switch value {
            case .string("{{prompt}}"): foundPrompt = true; return .string(prompt)
            case .string("{{checkpoint}}"): return .string(checkpoint)
            case .string("{{seed}}"): return .number(Double(seed))
            case .array(let values): return .array(try values.map { try bind($0, depth: depth + 1) })
            case .object(let values): return .object(try values.mapValues { try bind($0, depth: depth + 1) })
            default: return value
            }
        }
        var result: [String: JSONValue] = [:]
        for (id, value) in nodes {
            guard !id.isEmpty, let node = value.object,
                  let type = node["class_type"]?.string, !type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  node["inputs"]?.object != nil else {
                throw AgentError.message("Узел \(id) должен содержать class_type и inputs")
            }
            var boundNode = try node.mapValues { try bind($0) }
            if type == "SaveImage" {
                foundSaveImage = true
                var inputs = boundNode["inputs"]?.object ?? [:]
                inputs["filename_prefix"] = .string("STIXAgent")
                boundNode["inputs"] = .object(inputs)
            }
            result[id] = .object(boundNode)
        }
        guard foundPrompt else { throw AgentError.message("В API workflow требуется точное значение {{prompt}}") }
        guard foundSaveImage else { throw AgentError.message("API workflow должен содержать узел SaveImage") }
        return .object(result)
    }

    func generate(prompt: String, checkpoint: String, outputDirectory: URL,
                  workflow template: JSONValue? = nil,
                  onProgress: @escaping @Sendable (String) async -> Void) async throws -> [URL] {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, prompt.utf8.count <= 64_000 else {
            throw AgentError.message("Описание изображения пустое или слишком длинное")
        }
        guard outputDirectory.isFileURL else { throw AgentError.message("Требуется локальная папка изображений") }
        let workflow: JSONValue
        if let template {
            workflow = try Self.bindWorkflow(template, prompt: prompt, checkpoint: checkpoint, seed: UInt64.random(in: 0...UInt64(Int32.max)))
            await onProgress("Подготовлен пользовательский API workflow ComfyUI")
        } else {
            await onProgress("Проверка модели ComfyUI")
            guard try await checkpoints().contains(checkpoint) else { throw AgentError.message("Checkpoint не найден в ComfyUI: \(checkpoint)") }
            workflow = Self.workflow(prompt: prompt, checkpoint: checkpoint)
        }
        try Task.checkCancellation()
        let submitted = try await request("prompt", body: .object(["prompt": workflow, "client_id": .string(UUID().uuidString)]))
        let id = try submitted.requiredString("prompt_id")
        do {
            let deadline = Date().addingTimeInterval(15 * 60)
            await onProgress("Задание принято. Генерирую изображение…")
            while Date() < deadline {
                try Task.checkCancellation()
                let history = try await request("history/\(id)")
                let item = history[id]
                if item["status"]["status_str"].string == "error" || item["status"]["messages"].array?.contains(where: { ["execution_error", "execution_interrupted"].contains($0.array?.first?.string ?? "") }) == true {
                    throw AgentError.message("ComfyUI завершил генерацию с ошибкой: \(String(item["status"].encoded.prefix(2000)))")
                }
                if item["status"]["completed"].bool == true {
                    let images = (item["outputs"].object ?? [:]).sorted { $0.key < $1.key }.flatMap { $0.value["images"].array ?? [] }
                    guard !images.isEmpty, images.count <= 32 else { throw AgentError.message("ComfyUI не вернул изображения или превысил лимит 32 файлов") }
                    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
                    var saved: [URL] = []
                    for image in images {
                        try Task.checkCancellation()
                        let filename = try image.requiredString("filename")
                        guard !filename.contains("/"), !filename.contains("\\"), filename != ".", filename != ".." else { throw AgentError.message("ComfyUI вернул небезопасное имя файла") }
                        let bytes = try await data("view", query: [URLQueryItem(name: "filename", value: filename), URLQueryItem(name: "subfolder", value: image["subfolder"].string ?? ""), URLQueryItem(name: "type", value: image["type"].string ?? "output")], limit: 64 * 1024 * 1024)
                        guard bytes.starts(with: [137,80,78,71,13,10,26,10]) else { throw AgentError.message("ComfyUI вернул файл, который не является PNG") }
                        let destination = outputDirectory.appendingPathComponent("stix-\(UUID().uuidString).png")
                        try bytes.write(to: destination, options: .atomic)
                        saved.append(destination)
                    }
                    await onProgress("Сохранено изображений: \(saved.count)")
                    return saved
                }
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
            throw AgentError.message("ComfyUI превысил время ожидания 15 минут")
        } catch {
            // Cleanup must survive cancellation of the caller, and only target this prompt.
            let cleanupError = await Task.detached { () -> String? in
                do { try await cancelOwnedPrompt(id); return nil }
                catch { return error.localizedDescription }
            }.value
            if let cleanupError { NSLog("ComfyUI cleanup failed for %@: %@", id, cleanupError) }
            throw error
        }
    }

    func releaseModelsIfIdle() async throws {
        let queue = try await request("queue")
        guard queue["queue_running"].array?.isEmpty == true, queue["queue_pending"].array?.isEmpty == true else { return }
        _ = try await request("free", body: .object(["unload_models": .bool(true), "free_memory": .bool(true)]))
    }

    private func cancelOwnedPrompt(_ id: String) async throws {
        _ = try await request("queue", body: .object(["delete": .array([.string(id)])]))
        let queue = try await request("queue")
        if queue["queue_running"].array?.contains(where: { $0.array?.dropFirst().first?.string == id }) == true {
            _ = try await request("interrupt", body: .object([:]))
        }
    }

    private func request(_ path: String, body: JSONValue? = nil) async throws -> JSONValue {
        let bytes = try await data(path, body: body, limit: 8 * 1024 * 1024)
        if bytes.isEmpty { return .object([:]) }
        return try JSONDecoder().decode(JSONValue.self, from: bytes)
    }

    private func data(_ path: String, body: JSONValue? = nil, query: [URLQueryItem] = [], limit: Int) async throws -> Data {
        guard let base = URL(string: endpoint), ["http", "https"].contains(base.scheme?.lowercased() ?? ""), base.host != nil,
              var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw AgentError.message("Некорректный адрес ComfyUI")
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw AgentError.message("Некорректный URL ComfyUI") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let encoded = try JSONEncoder().encode(body)
            guard encoded.count <= 1024 * 1024 else { throw AgentError.message("Слишком большой запрос ComfyUI") }
            request.httpBody = encoded
        }
        let (stream, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentError.message("Некорректный ответ ComfyUI") }
        guard response.expectedContentLength <= Int64(limit) else { throw AgentError.message("Ответ ComfyUI превышает лимит") }
        var result = Data()
        for try await byte in stream {
            guard result.count < limit else { throw AgentError.message("Ответ ComfyUI превышает лимит") }
            result.append(byte)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AgentError.message("ComfyUI HTTP \(http.statusCode): \(String(decoding: result.prefix(2000), as: UTF8.self))")
        }
        return result
    }
}
