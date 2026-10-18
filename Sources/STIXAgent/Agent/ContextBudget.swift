import Foundation

/// Conservative estimates, visibly approximate: not a model-specific tokenizer.
struct ContextWindow: Equatable {
    let limit: Int
    let knownLimit: Bool
    let systemTokens: Int
    let toolTokens: Int
    let historyTokens: Int
    let reserveTokens: Int
    var inputTokens: Int { systemTokens + toolTokens + historyTokens }
    var remainingTokens: Int { max(0, limit - inputTokens - reserveTokens) }
    var fraction: Double { min(1, Double(inputTokens + reserveTokens) / Double(limit)) }
    var percentage: Int { Int((fraction * 100).rounded()) }
    var shouldCompact: Bool { fraction >= 0.75 }
    static func tokens(_ text: String) -> Int { (text.utf8.count + 1) / 2 }
    static func messageTokens(_ message: LMMessage) -> Int {
        tokens(message.content ?? "") + message.toolCalls.reduce(0) { $0 + tokens($1.arguments) + tokens($1.name) + tokens($1.id) + 16 } + (message.imageURLs?.count ?? 0) * 2048 + 16
    }
    static func estimate(limit: Int?, knownLimit: Bool, system: String, tools: [ToolDefinition], history: [LMMessage]) -> Self {
        let capacity = max(1024, min(limit ?? 32768, 1_048_576))
        return .init(limit: capacity, knownLimit: knownLimit && limit != nil,
                     systemTokens: tokens(system) + 256,
                     toolTokens: tools.reduce(0) { $0 + tokens($1.wire.encoded) },
                     historyTokens: history.reduce(0) { $0 + messageTokens($1) },
                     reserveTokens: min(4096, max(512, capacity / 5)))
    }
}

enum ContextBudget {
    static func historyCharacters(contextLimit: Int?, system: String, tools: [ToolDefinition]) throws -> Int {
        let window = ContextWindow.estimate(limit: contextLimit, knownLimit: contextLimit != nil, system: system, tools: tools, history: [])
        let available = window.remainingTokens - 256
        guard available >= 1024 else { throw AgentError.message("Контекст выбранной модели слишком мал для системных инструкций и инструментов. Увеличьте context length в локальном сервере или выберите другую модель; история сохранена.") }
        return min(500_000, available)
    }
    /// Final network guard for model switches, unicode and unexpectedly large tool output.
    static func fitted(_ history: [LMMessage], limit: Int?, system: String, tools: [ToolDefinition]) throws -> [LMMessage] {
        var budget = try historyCharacters(contextLimit: limit, system: system, tools: tools)
        let paired = ContextSummary.paired(history)
        if ContextWindow.estimate(limit: limit, knownLimit: limit != nil, system: system, tools: tools, history: paired).remainingTokens >= 256 { return paired }
        while budget >= 1024 {
            let candidate = ContextSummary.bounded(paired, maxCharacters: budget)
            if ContextWindow.estimate(limit: limit, knownLimit: limit != nil, system: system, tools: tools, history: candidate).remainingTokens >= 256 {
                guard candidate.last(where: { $0.role == "user" }) == paired.last(where: { $0.role == "user" }) else {
                    throw AgentError.message("Последний запрос не помещается в контекст целиком. Уменьшите его или выберите модель с большим окном; переписка сохранена.")
                }
                return candidate
            }
            budget = budget * 3 / 4
        }
        throw AgentError.message("Последний запрос или вложения не помещаются в контекст модели. Уменьшите вложение или выберите модель с большим окном; история сохранена.")
    }
}
