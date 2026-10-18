import Foundation

/// A fresh session per operation makes cancellation and resource deadlines independent of other chats.
struct LMStudioClient: Sendable {
    let endpoint: String
    init(endpoint: String) { self.endpoint = endpoint }

    private func url(_ path: String) throws -> URL {
        guard var base = URLComponents(string: endpoint),
              ["http", "https"].contains(base.scheme?.lowercased() ?? ""),
              base.host != nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil else {
            throw AgentError.message("Некорректный адрес LM Studio")
        }
        var root = base.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if root.hasSuffix("v1") { root = String(root.dropLast(2)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        base.path = (root.isEmpty ? "" : "/" + root) + path
        guard let result = base.url else { throw AgentError.message("Некорректный адрес LM Studio") }
        return result
    }

    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 600
        config.httpCookieStorage = nil
        config.urlCache = nil
        // A local endpoint must never forward prompts or images to a redirect target.
        return URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    func models() async throws -> [ModelDescriptor] {
        let session = session()
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: try url("/v1/models"))
        request.timeoutInterval = 30
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 2_000_000 else { throw AgentError.message("Слишком большой список моделей LM Studio") }
            data.append(byte)
        }
        try Self.validate(response, body: data)
        let json = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let entries = json["data"].array else { throw AgentError.message("LM Studio: неверный формат списка моделей") }
        return Array(Set(entries.compactMap { entry -> String? in
            guard let id = entry["id"].string, !id.isEmpty, !id.lowercased().contains("embed") else { return nil }; return id
        })).sorted().map { ModelDescriptor(id: $0) }
    }

    static func requestBody(model: String, messages: [LMMessage], tools: [ToolDefinition], thinking: Bool = false) throws -> Data {
        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentError.message("Выберите модель LM Studio") }
        let wireMessages: [JSONValue] = messages.map { message in
            var content: JSONValue = message.content.map(JSONValue.string) ?? .null
            if let imageURLs = message.imageURLs, !imageURLs.isEmpty {
                var parts: [JSONValue] = []
                if let text = message.content, !text.isEmpty { parts.append(.object(["type": .string("text"), "text": .string(text)])) }
                parts += imageURLs.map { .object(["type": .string("image_url"), "image_url": .object(["url": .string($0)])]) }
                content = .array(parts)
            }
            var object: [String: JSONValue] = ["role": .string(message.role), "content": content]
            if let id = message.toolCallID { object["tool_call_id"] = .string(id) }
            if !message.toolCalls.isEmpty {
                object["tool_calls"] = .array(message.toolCalls.map { call in
                    .object(["id": .string(call.id), "type": .string("function"), "function": .object(["name": .string(call.name), "arguments": .string(call.arguments)])])
                })
            }
            return .object(object)
        }
        var body: [String: JSONValue] = ["model": .string(model), "messages": .array(wireMessages), "stream": .bool(true)]
        if thinking { body["chat_template_kwargs"] = .object(["enable_thinking": .bool(true)]) }
        if !tools.isEmpty { body["tools"] = .array(tools.map(\.wire)); body["tool_choice"] = .string("auto") }
        let data = try JSONEncoder().encode(JSONValue.object(body))
        guard data.count <= 16_000_000 else { throw AgentError.message("Контекст слишком большой для LM Studio") }
        return data
    }

    func complete(model: String, messages: [LMMessage], tools: [ToolDefinition], thinking: Bool = false, onReasoning: @escaping @Sendable (String) async -> Void = { _ in }, onText: @escaping @Sendable (String) async -> Void) async throws -> LMReply {
        var request = URLRequest(url: try url("/v1/chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try Self.requestBody(model: model, messages: messages, tools: tools, thinking: thinking)
        let session = session()
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw AgentError.message("LM Studio: отсутствует HTTP-ответ") }
            if !(200...299).contains(http.statusCode) {
                var body = Data()
                for try await byte in bytes { try Task.checkCancellation(); if body.count >= 8192 { break }; body.append(byte) }
                try Self.validate(response, body: body)
            }
            var parser = LMStreamParser()
            var line = Data()
            var total = 0
            for try await byte in bytes {
                try Task.checkCancellation()
                total += 1
                guard total <= 16_000_000, line.count <= 1_000_000 else { throw AgentError.message("LM Studio: превышен размер ответа") }
                if byte == 10 {
                    guard let string = String(data: line, encoding: .utf8) else { throw AgentError.message("LM Studio: неверная кодировка потока") }
                    line.removeAll(keepingCapacity: true)
                    if let text = try parser.consume(line: string) { await onText(text) }
                    if thinking, !parser.reasoningDelta.isEmpty { await onReasoning(parser.reasoningDelta) }
                    if parser.done { break }
                } else { line.append(byte) }
            }
            if !line.isEmpty {
                guard let string = String(data: line, encoding: .utf8) else { throw AgentError.message("LM Studio: неверная кодировка потока") }
                if let text = try parser.consume(line: string) { await onText(text) }
                if thinking, !parser.reasoningDelta.isEmpty { await onReasoning(parser.reasoningDelta) }
            }
            if let text = try parser.consume(line: "") { await onText(text) }
            if thinking, !parser.reasoningDelta.isEmpty { await onReasoning(parser.reasoningDelta) }
            try Task.checkCancellation()
            return try parser.reply()
        } onCancel: { session.invalidateAndCancel() }
    }

    private static func validate(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AgentError.message("LM Studio: отсутствует HTTP-ответ") }
        guard (200...299).contains(http.statusCode) else {
            let json = try? JSONDecoder().decode(JSONValue.self, from: body)
            let message = json?["error"]["message"].string ?? json?["error"].string ?? "Ошибка сервера"
            throw AgentError.message("LM Studio HTTP \(http.statusCode): \(String(message.prefix(1000)))")
        }
    }
}

/// SSE framing and OpenAI delta assembly, independent of networking for deterministic tests.
struct LMStreamParser {
    private var event: [String] = []
    private var content = ""
    private var thinkingStream = ThinkingStream()
    private(set) var reasoningDelta = ""
    private var calls: [Int: ToolCall] = [:]
    private var finished = false
    private(set) var done = false

    mutating func consume(line raw: String) throws -> String? {
        reasoningDelta = ""
        let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        guard !done else { return nil }
        if line.hasPrefix("data:") {
            var value = String(line.dropFirst(5))
            if value.hasPrefix(" ") { value.removeFirst() }
            event.append(value)
            guard event.reduce(0, { $0 + $1.utf8.count }) <= 1_000_000 else { throw AgentError.message("LM Studio: слишком большое событие") }
            return nil
        }
        guard line.isEmpty, !event.isEmpty else { return nil }
        let payload = event.joined(separator: "\n")
        event.removeAll(keepingCapacity: true)
        if payload == "[DONE]" { done = true; return acceptContent("", finishing: true) }
        let json: JSONValue
        do { json = try JSONValue.parse(payload) } catch { throw AgentError.message("LM Studio: повреждённое событие JSON") }
        if json["error"] != .null {
            throw AgentError.message("LM Studio: \(String((json["error"]["message"].string ?? json["error"].string ?? "Ошибка модели").prefix(1000)))")
        }
        guard let choices = json["choices"].array else { throw AgentError.message("LM Studio: событие не содержит choices") }
        guard let choice = choices.first(where: { $0["index"].int == 0 || $0["index"] == .null }) else { return nil }
        if let reason = choice["finish_reason"].string {
            guard ["stop", "tool_calls", "function_call"].contains(reason) else { throw AgentError.message("LM Studio: ответ прерван (\(reason))") }
            finished = true
        }
        let delta = choice["delta"]
        if let fragments = delta["tool_calls"].array {
            for fragment in fragments {
                guard let index = fragment["index"].int, index >= 0, index < 128 else { throw AgentError.message("LM Studio: неверный индекс вызова инструмента") }
                var call = calls[index] ?? ToolCall(id: "", name: "", arguments: "")
                call.id += fragment["id"].string ?? ""
                call.name += fragment["function"]["name"].string ?? ""
                call.arguments += fragment["function"]["arguments"].string ?? ""
                calls[index] = call
            }
        }
        reasoningDelta = delta["reasoning_content"].string ?? delta["reasoning"].string ?? ""
        return acceptContent(delta["content"].string ?? "", finishing: finished)
    }

    private mutating func acceptContent(_ chunk: String, finishing: Bool) -> String? {
        let output = thinkingStream.consume(chunk, finishing: finishing)
        reasoningDelta += output.reasoning
        content += output.text
        return output.text.isEmpty ? nil : output.text
    }

    func reply() throws -> LMReply {
        guard done || finished else { throw AgentError.message("LM Studio: поток завершился до окончания ответа") }
        let assembled = calls.keys.sorted().compactMap { calls[$0] }
        guard !content.isEmpty || !assembled.isEmpty else { throw AgentError.message("LM Studio: модель вернула пустой ответ") }
        var ids = Set<String>()
        for call in assembled {
            guard !call.id.isEmpty, !call.name.isEmpty, ids.insert(call.id).inserted,
                  let arguments = try? JSONValue.parse(call.arguments), arguments.object != nil else {
                throw AgentError.message("LM Studio: неполный вызов инструмента")
            }
        }
        return LMReply(content: content, toolCalls: assembled)
    }
}
