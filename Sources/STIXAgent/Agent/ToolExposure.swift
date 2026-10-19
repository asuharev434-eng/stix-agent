import Foundation

/// Keep the first request useful on a small loaded context window. Remaining
/// tools can be exposed on a later round without changing their executor or
/// host-side approval policy.
enum ToolExposure {
    static let discovery = ToolDefinition(
        name: "discover_tools",
        description: "Find additional agent tools by topic or exact name. Matching tools become callable in the next response. Use when the needed tool is not currently offered; do not claim the capability is unavailable before searching.",
        parameters: ToolCatalog.schema(["query": "string"], required: ["query"])
    )

    private static let essentials = [
        "discover_tools", "ask_user", "list_files", "read_file", "search_files",
        "write_file", "move_file", "trash_file", "run_shell", "verify_result"
    ]

    static func matches(query: String, tools: [ToolDefinition]) -> [ToolDefinition] {
        let lower = query.lowercased()
        let words = lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return [] }
        let aliases: [(String, [String])] = [
            ("картин", ["generate_image", "import_image_workflow", "show_file"]),
            ("изображ", ["generate_image", "import_image_workflow", "show_file"]),
            ("фото", ["generate_image", "show_file"]),
            ("брауз", ["browser_action", "computer_snapshot", "computer_action"]),
            ("приложен", ["open_application", "computer_snapshot", "computer_action"]),
            ("сайт", ["web_search", "read_web_page", "browser_action"]),
            ("интернет", ["web_search", "read_web_page"]),
            ("поиск", ["web_search", "search_files", "search_documents"]),
            ("памят", ["show_memory", "manage_memory"]),
            ("схем", ["present_artifact"]),
            ("диаграм", ["present_artifact"]),
            ("задач", ["list_tasks", "manage_task", "queue_task"]),
            ("плагин", ["add_plugin", "manage_plugin"]),
            ("api", ["connect_api", "list_connections", "http_request"]),
            ("mcp", ["add_plugin", "manage_plugin"])
        ]
        let boosted = Set(aliases.filter { lower.contains($0.0) }.flatMap { $0.1 })
        let found = tools.filter { tool in
            let name = tool.name.lowercased()
            let description = tool.description.lowercased()
            return boosted.contains(name) || words.contains { word in
                word.count >= 3 && (name.contains(word) || description.contains(word))
            }
        }
        return found.prefix(12).map { $0 }
    }

    static func selected(from all: [ToolDefinition], limit: Int?, system: String,
                         currentRequest: String, exposed: Set<String> = []) -> [ToolDefinition] {
        let empty = ContextWindow.estimate(limit: limit, knownLimit: limit != nil, system: system, tools: [], history: [])
        // Keep room for the latest user request and at least a short answer.
        let requestTokens = ContextWindow.tokens(currentRequest) + 128
        let historyReserve = max(3072, min(6144, requestTokens + 1024))
        let toolBudget = max(0, empty.limit - empty.systemTokens - empty.reserveTokens - historyReserve)
        let byName = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })
        let topicNames = matches(query: currentRequest, tools: all).map(\.name)
        let names = essentials + exposed.sorted() + topicNames + all.map(\.name)
        var seen = Set<String>(), result: [ToolDefinition] = [], used = 0
        for name in names where seen.insert(name).inserted {
            guard let tool = byName[name] else { continue }
            let cost = ContextWindow.tokens(tool.wire.encoded)
            if used + cost <= toolBudget {
                result.append(tool); used += cost
            }
        }
        return result
    }
}
