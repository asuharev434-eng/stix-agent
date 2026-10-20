import CryptoKit
import Foundation

/// A separate llama.cpp multimodal process keeps projector memory out of text-only turns.
struct LocalGGUFVisionEngine: Sendable {
    let executable: URL
    let model: URL
    let projector: URL
    let projectorSHA256: String

    func complete(messages: [LMMessage], tools: [ToolDefinition], maxOutputTokens: Int?, thinking: Bool,
                  onPhase: @escaping @Sendable (String) async -> Void,
                  onRequest: @escaping @Sendable ([LMMessage]) async -> Void,
                  onReasoning: @escaping @Sendable (String) async -> Void,
                  onText: @escaping @Sendable (String) async -> Void) async throws -> LMReply {
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.fileExists(atPath: model.path),
              FileManager.default.fileExists(atPath: projector.path),
              projectorSHA256.count == 64 else {
            throw AgentError.message("Локальная vision-модель или проектор отсутствует")
        }
        let file = try FileHandle(forReadingFrom: projector)
        defer { try? file.close() }
        var hasher = SHA256()
        while let chunk = try file.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        let actual = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual == projectorSHA256 else { throw AgentError.message("Vision-проектор повреждён") }
        guard let latest = messages.last(where: { !($0.imageURLs ?? []).isEmpty }),
              let urls = latest.imageURLs, !urls.isEmpty, urls.count <= 4 else {
            throw AgentError.message("Для анализа изображения нужны 1–4 вложения")
        }
        let working = FileManager.default.temporaryDirectory.appendingPathComponent("stix-vision-" + UUID().uuidString,
                                                                                       isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: working) }
        var images: [String] = []
        for (index, value) in urls.enumerated() {
            guard value.hasPrefix("data:image/"), let comma = value.firstIndex(of: ","),
                  value[..<comma].contains(";base64"),
                  let data = Data(base64Encoded: String(value[value.index(after: comma)...])),
                  (100...10_000_000).contains(data.count) else {
                throw AgentError.message("Некорректное изображение для локальной vision-модели")
            }
            let suffix = value.hasPrefix("data:image/jpeg") ? "jpg" : "png"
            let image = working.appendingPathComponent("image-\(index).\(suffix)")
            try data.write(to: image, options: .atomic)
            images.append(image.path)
        }
        await onRequest(messages)
        await onPhase("Локальная модель анализирует изображение…")
        var prompt = latest.content ?? "Опиши изображение."
        if !tools.isEmpty {
            prompt += "\nДоступные инструменты (JSON Schema):\n" + tools.map { $0.wire.encoded }.joined(separator: "\n") +
                "\nЕсли нужен инструмент, верни только JSON: {\"tool_calls\":[{\"name\":\"имя\",\"arguments\":{...}}]}."
        }
        let system = messages.first(where: { $0.role == "system" })?.content ?? "You are a helpful assistant."
        let arguments = ["-m", model.path, "--mmproj", projector.path, "--image", images.joined(separator: ","),
                         "-p", prompt, "--system-prompt", system, "-c", "4096", "-n",
                         String(min(max(maxOutputTokens ?? 768, 128), 2048)), "--no-warmup", "--jinja"]
        let result = try await ProcessRunner().runExecutable(executable.path, arguments: arguments,
                                                             directory: working.path, timeout: 900,
                                                             maxOutputBytes: 1_000_000)
        guard result.exitCode == 0, !result.timedOut else {
            throw AgentError.message("Vision-модель: " + result.output.suffix(1200))
        }
        let marker = "<channel|>"
        guard let boundary = result.output.range(of: marker, options: .backwards) else {
            throw AgentError.message("Vision-модель не завершила итоговый ответ; повторите с большим лимитом токенов")
        }
        if thinking, let start = result.output.range(of: "<|channel>thought\n") {
            let reasoning = String(result.output[start.upperBound..<boundary.lowerBound])
            if !reasoning.isEmpty { await onReasoning(reasoning) }
        }
        let answer = String(result.output[boundary.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw AgentError.message("Vision-модель вернула пустой ответ") }
        let reply = LlamaTextEngine.parseToolReply(answer, allowed: Set(tools.map(\.name)))
        if reply.toolCalls.isEmpty { await onText(reply.content) }
        return reply
    }
}
