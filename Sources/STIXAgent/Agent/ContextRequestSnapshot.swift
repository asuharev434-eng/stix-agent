import Foundation

/// The request that was actually handed to the local client, not a reconstruction
/// from today's settings. Kept in RAM to avoid duplicating transcripts on disk.
struct ContextRequestSnapshot {
    let model: String
    let createdAt = Date()
    let instructions: String
    let memory: String
    let summary: String
    let transcript: String
    let tools: String
    let messageCount: Int

    init(model: String, system: String, history: [LMMessage], tools: [ToolDefinition]) {
        self.model = model
        var instructions = system
        if let start = system.range(of: "<stix-memory>"), let end = system.range(of: "</stix-memory>", range: start.upperBound..<system.endIndex) {
            memory = String(system[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            instructions.removeSubrange(start.lowerBound..<end.upperBound)
        } else { memory = "Память не подключена" }
        self.instructions = instructions
        self.tools = tools.map { $0.wire.encoded }.joined(separator: "\n\n")
        func describe(_ message: LMMessage) -> String {
            var text = "[\(message.role)]\n" + (message.content ?? "")
            if !message.toolCalls.isEmpty { text += "\n" + message.toolCalls.map { "\($0.name)(\($0.arguments))" }.joined(separator: "\n") }
            if let id = message.toolCallID { text += "\nresult_of: " + id }
            if let images = message.imageURLs, !images.isEmpty { text += "\n[Изображений: \(images.count); пиксели переданы модели, base64 скрыт в просмотре]" }
            return text
        }
        summary = history.filter { $0.role == "system" }.map(describe).joined(separator: "\n\n")
        transcript = history.filter { $0.role != "system" }.map(describe).joined(separator: "\n\n")
        messageCount = history.count
    }
}


extension AppStore {
    func captureContextRequest(model: String, messages: [LMMessage], tools: [ToolDefinition], chatID: UUID) {
        guard let system = messages.first?.content, messages.first?.role == "system" else { return }
        let history = messages.dropFirst().map { item -> LMMessage in
            var safe = item; safe.content = safe.content.map(vault.redact)
            safe.toolCalls = safe.toolCalls.map { .init(id: $0.id, name: $0.name, arguments: vault.redact($0.arguments)) }
            return safe
        }
        let safeTools = tools.map { ToolDefinition(name: $0.name, description: vault.redact($0.description), parameters: (try? JSONValue.parse(vault.redact($0.parameters.encoded))) ?? .object([:])) }
        requestSnapshots[chatID] = .init(model: model, system: vault.redact(system), history: Array(history), tools: safeTools)
    }
}
