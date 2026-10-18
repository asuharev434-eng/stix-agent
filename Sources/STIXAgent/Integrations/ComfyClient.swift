import Foundation
import ImageIO

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
        // The legacy entry point has fixed, valid defaults.
        makeWorkflow(request: ImageRequest(prompt: prompt, seed: UInt64(max(0, seed))), checkpoint: checkpoint)
    }

    static func workflow(request: ImageRequest, checkpoint: String,
                         uploadedImage: String? = nil, uploadedMask: String? = nil) throws -> JSONValue {
        _ = try request.validated()
        guard request.inputImagePath == nil || uploadedImage != nil else { throw AgentError.message("Исходное изображение не загружено в ComfyUI") }
        guard request.maskImagePath == nil || uploadedMask != nil else { throw AgentError.message("Маска не загружена в ComfyUI") }
        return makeWorkflow(request: request, checkpoint: checkpoint, uploadedImage: uploadedImage, uploadedMask: uploadedMask)
    }

    private static func makeWorkflow(request: ImageRequest, checkpoint: String,
                                     uploadedImage: String? = nil, uploadedMask: String? = nil) -> JSONValue {
        func link(_ id: String, _ slot: Int = 0) -> JSONValue { .array([.string(id), .number(Double(slot))]) }
        func node(_ type: String, _ inputs: [String: JSONValue]) -> JSONValue {
            .object(["class_type": .string(type), "inputs": .object(inputs)])
        }
        if request.resizeOnly {
            return .object([
                "8": node("LoadImage", ["image": .string(uploadedImage ?? "")]),
                "9": node("ImageScale", ["image": link("8"), "upscale_method": .string("lanczos"), "width": .number(Double(request.width)), "height": .number(Double(request.height)), "crop": .string("disabled")]),
                "7": node("SaveImage", ["images": link("9"), "filename_prefix": .string("STIXAgent")])
            ])
        }
        var nodes: [String: JSONValue] = [
            "1": node("CheckpointLoaderSimple", ["ckpt_name": .string(checkpoint)]),
            "2": node("CLIPTextEncode", ["text": .string(request.prompt), "clip": link("1", 1)]),
            "3": node("CLIPTextEncode", ["text": .string(request.negativePrompt), "clip": link("1", 1)]),
            "4": node("EmptyLatentImage", ["width": .number(Double(request.width)), "height": .number(Double(request.height)), "batch_size": .number(Double(request.count))]),
            "5": node("KSampler", ["model": link("1"), "positive": link("2"), "negative": link("3"), "latent_image": link("4"), "seed": .number(Double(request.seed)), "steps": .number(Double(request.steps)), "cfg": .number(request.cfg), "sampler_name": .string("euler"), "scheduler": .string("normal"), "denoise": .number(request.denoise)]),
            "6": node("VAEDecode", ["samples": link("5"), "vae": link("1", 2)]),
            "7": node("SaveImage", ["images": link("6"), "filename_prefix": .string("STIXAgent")])
        ]
        if request.inputImagePath != nil {
            let uploadedImage = uploadedImage ?? ""
            nodes["8"] = node("LoadImage", ["image": .string(uploadedImage)])
            nodes["9"] = node("ImageScale", ["image": link("8"), "upscale_method": .string("lanczos"), "width": .number(Double(request.width)), "height": .number(Double(request.height)), "crop": .string("disabled")])
            if request.maskImagePath != nil {
                let uploadedMask = uploadedMask ?? ""
                // Load RGB luminance masks explicitly: white edits, black preserves.
                nodes["10"] = node("LoadImage", ["image": .string(uploadedMask)])
                nodes["11"] = node("ImageScale", ["image": link("10"), "upscale_method": .string("nearest-exact"), "width": .number(Double(request.width)), "height": .number(Double(request.height)), "crop": .string("disabled")])
                nodes["12"] = node("ImageToMask", ["image": link("11"), "channel": .string("red")])
                nodes["4"] = node("VAEEncodeForInpaint", ["pixels": link("9"), "vae": link("1", 2), "mask": link("12"), "grow_mask_by": .number(6)])
                if request.count > 1 {
                    nodes["15"] = node("RepeatImageBatch", ["image": link("9"), "amount": .number(Double(request.count))])
                }
                nodes["14"] = node("ImageCompositeMasked", ["destination": link(request.count > 1 ? "15" : "9"), "source": link("6"), "mask": link("12"), "x": .number(0), "y": .number(0), "resize_source": .bool(false)])
                nodes["7"] = node("SaveImage", ["images": link("14"), "filename_prefix": .string("STIXAgent")])
            } else {
                nodes["4"] = node("VAEEncode", ["pixels": link("9"), "vae": link("1", 2)])
            }
            if request.count > 1 {
                nodes["13"] = node("RepeatLatentBatch", ["samples": link("4"), "amount": .number(Double(request.count))])
                var sampler = nodes["5"]!["inputs"].object!
                sampler["latent_image"] = link("13")
                nodes["5"] = node("KSampler", sampler)
            }
        }
        return .object(nodes)
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

    static func validateTemplateOptions(_ template: JSONValue, request: ImageRequest) throws {
        var placeholders = Set<String>()
        func collect(_ value: JSONValue, depth: Int = 0) throws {
            guard depth <= 100 else { throw AgentError.message("Workflow содержит слишком глубокую структуру") }
            switch value {
            case .string(let text): placeholders.insert(text)
            case .array(let array): try array.forEach { try collect($0, depth: depth + 1) }
            case .object(let object): try object.values.forEach { try collect($0, depth: depth + 1) }
            default: break
            }
        }
        try collect(template)
        var required = request.explicitOptions
        if request.inputImagePath != nil { required.insert("input"); required.insert("denoise") }
        if request.maskImagePath != nil { required.insert("mask") }
        if request.width != 1024 { required.insert("width") }
        if request.height != 1024 { required.insert("height") }
        if request.steps != 20 { required.insert("steps") }
        if request.cfg != 7 { required.insert("cfg") }
        if request.denoise != 1 { required.insert("denoise") }
        if request.negativePrompt != ImageRequest.defaultNegativePrompt { required.insert("negative") }
        if request.count != 1 { required.insert("count") }
        if required.remove("size") != nil { required.formUnion(["width", "height"]) }
        let names = ["input": "input_image", "mask": "mask_image", "negative": "negative_prompt"]
        for option in required.sorted() {
            let placeholder = "{{\(names[option] ?? option)}}"
            guard placeholders.contains(placeholder) else {
                throw AgentError.message("Пользовательский workflow не поддерживает --\(option): требуется точное значение \(placeholder)")
            }
        }
    }

    static func bindWorkflow(_ template: JSONValue, request: ImageRequest, checkpoint: String,
                             uploadedImage: String? = nil, uploadedMask: String? = nil) throws -> JSONValue {
        let request = try request.validated()
        guard !request.resizeOnly else { throw AgentError.message("Изменение размера использует встроенный workflow без модели") }
        try validateTemplateOptions(template, request: request)
        let base = try bindWorkflow(template, prompt: request.prompt, checkpoint: checkpoint, seed: request.seed)
        let replacements: [String: JSONValue] = [
            "{{width}}": .number(Double(request.width)), "{{height}}": .number(Double(request.height)),
            "{{steps}}": .number(Double(request.steps)), "{{cfg}}": .number(request.cfg),
            "{{denoise}}": .number(request.denoise), "{{negative_prompt}}": .string(request.negativePrompt),
            "{{count}}": .number(Double(request.count))]
        func bind(_ value: JSONValue) throws -> JSONValue {
            switch value {
            case .string("{{input_image}}"):
                guard let uploadedImage else { throw AgentError.message("Workflow требует исходное изображение --input") }
                return .string(uploadedImage)
            case .string("{{mask_image}}"):
                guard let uploadedMask else { throw AgentError.message("Workflow требует маску --mask") }
                return .string(uploadedMask)
            case .string(let text): return replacements[text] ?? value
            case .array(let values): return .array(try values.map(bind))
            case .object(let values): return .object(try values.mapValues(bind))
            default: return value
            }
        }
        return try bind(base)
    }

    private func uploadImage(path: String) async throws -> String {
        try Task.checkCancellation()
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, let size = attributes.fileSize, size > 0, size <= 32 * 1024 * 1024 else {
            throw AgentError.message("Изображение должно быть обычным файлом размером до 32 МБ")
        }
        let bytes = try Data(contentsOf: url, options: .mappedIfSafe)
        guard bytes.count <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(bytes as CFData, nil),
              let type = CGImageSourceGetType(source) as String?,
              ["public.png", "public.jpeg", "org.webmproject.webp"].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 64_000_000 else {
            throw AgentError.message("Требуется корректное PNG/JPEG/WebP до 64 мегапикселей")
        }
        let ext = type == "public.png" ? "png" : type == "public.jpeg" ? "jpg" : "webp"
        let boundary = "STIXAgent-\(UUID().uuidString)"
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"type\"\r\n\r\ninput\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"overwrite\"\r\n\r\nfalse\r\n".utf8))
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"stix-\(UUID().uuidString).\(ext)\"\r\nContent-Type: image/\(ext == "jpg" ? "jpeg" : ext)\r\n\r\n".utf8))
        body.append(bytes)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let response = try await data("upload/image", rawBody: body, contentType: "multipart/form-data; boundary=\(boundary)", limit: 1024 * 1024)
        let uploaded = try JSONDecoder().decode(JSONValue.self, from: response)
        let name = try uploaded.requiredString("name")
        let folder = uploaded["subfolder"].string ?? ""
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != "..",
              !folder.hasPrefix("/"), !folder.contains("\\"), !folder.split(separator: "/").contains("..") else {
            throw AgentError.message("ComfyUI вернул небезопасный путь загруженного изображения")
        }
        return folder.isEmpty ? name : "\(folder)/\(name)"
    }

    func generate(prompt: String, checkpoint: String, outputDirectory: URL,
                  workflow template: JSONValue? = nil,
                  onStepProgress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in },
                  onProgress: @escaping @Sendable (String) async -> Void) async throws -> [URL] {
        try await generate(request: ImageRequest(prompt: prompt), checkpoint: checkpoint,
                           outputDirectory: outputDirectory, workflow: template,
                           onStepProgress: onStepProgress, onProgress: onProgress)
    }

    func generate(request imageRequest: ImageRequest, checkpoint: String, outputDirectory: URL,
                  workflow template: JSONValue? = nil,
                  onStepProgress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in },
                  onProgress: @escaping @Sendable (String) async -> Void) async throws -> [URL] {
        let imageRequest = try imageRequest.validated()
        guard outputDirectory.isFileURL else { throw AgentError.message("Требуется локальная папка изображений") }
        // Reject unsupported custom options before reading or uploading user files.
        if let template, !imageRequest.resizeOnly { try Self.validateTemplateOptions(template, request: imageRequest) }
        let uploadedImage: String?
        let uploadedMask: String?
        if let path = imageRequest.inputImagePath {
            await onProgress("Загружаю исходное изображение в локальный ComfyUI")
            uploadedImage = try await uploadImage(path: path)
        } else { uploadedImage = nil }
        if let path = imageRequest.maskImagePath {
            await onProgress("Загружаю маску: белое — изменить, чёрное — сохранить")
            uploadedMask = try await uploadImage(path: path)
        } else { uploadedMask = nil }
        let workflow: JSONValue
        if imageRequest.resizeOnly {
            workflow = try Self.workflow(request: imageRequest, checkpoint: checkpoint, uploadedImage: uploadedImage)
            await onProgress("Изменяю размер изображения без генерации и загрузки модели")
        } else if let template {
            workflow = try Self.bindWorkflow(template, request: imageRequest, checkpoint: checkpoint,
                                             uploadedImage: uploadedImage, uploadedMask: uploadedMask)
            await onProgress("Подготовлен пользовательский API workflow ComfyUI")
        } else {
            await onProgress("Проверка модели ComfyUI")
            guard try await checkpoints().contains(checkpoint) else { throw AgentError.message("Checkpoint не найден в ComfyUI: \(checkpoint)") }
            workflow = try Self.workflow(request: imageRequest, checkpoint: checkpoint, uploadedImage: uploadedImage, uploadedMask: uploadedMask)
        }
        try Task.checkCancellation()
        let clientID = UUID().uuidString
        let progressStream = try await ComfyProgressStream.connect(endpoint: endpoint, clientID: clientID)
        defer { progressStream?.close() }
        try Task.checkCancellation()
        let submitted = try await request("prompt", body: .object(["prompt": workflow, "client_id": .string(clientID)]))
        if let errors = submitted["node_errors"].object, !errors.isEmpty {
            throw AgentError.message("ComfyUI отклонил workflow: \(String(submitted["node_errors"].encoded.prefix(2000)))")
        }
        if submitted["error"] != .null {
            throw AgentError.message("ComfyUI отклонил задание: \(String(submitted["error"].encoded.prefix(2000)))")
        }
        let id = try submitted.requiredString("prompt_id")
        let progressTask = Task {
            await progressStream?.listen(promptID: id, onStepProgress: onStepProgress)
        }
        defer { progressTask.cancel() }
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
            progressTask.cancel()
            progressStream?.close()
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

    private func data(_ path: String, body: JSONValue? = nil, query: [URLQueryItem] = [], rawBody: Data? = nil, contentType: String? = nil, limit: Int) async throws -> Data {
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
        if let rawBody {
            request.httpMethod = "POST"
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = rawBody
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (stream, response) = try await session.bytes(for: request)
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
