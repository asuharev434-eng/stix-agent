import Foundation

/// Conservative text estimate, not a model-specific tokenizer. Reserve generation,
/// tool schemas, the complete system prompt and vision overhead before history.
enum ContextBudget {
    static func historyCharacters(contextLimit: Int?, system: String, tools: [ToolDefinition]) throws -> Int {
        let limit = min(contextLimit ?? 32768, 131072)
        let schemaBytes = tools.reduce(0) { $0 + $1.wire.encoded.utf8.count }
        let fixedTokens = (system.utf8.count + schemaBytes + 1) / 2 + 512
        let outputReserve = min(4096, max(512, limit / 5))
        let available = limit - fixedTokens - outputReserve
        guard available >= 1024 else { throw AgentError.message("Контекст выбранной модели слишком мал для системных инструкций и инструментов. Увеличьте context length в локальном сервере или выберите другую модель; история сохранена.") }
        return min(24000, available)
    }
}
