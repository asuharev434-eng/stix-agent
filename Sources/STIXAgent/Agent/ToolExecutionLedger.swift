import Foundation

/// Task-local receipts are reconstructed from durable model history, including calls
/// whose process ended before a result was saved. Such calls must never be replayed.
struct ToolExecutionLedger {
    struct Receipt { let output: String; let uncertain: Bool }
    private var receipts: [String: Receipt] = [:]
    private var reads: [String: Int] = [:]
    private static let readsAllowed = Set(["list_files", "read_file", "search_files", "read_document", "web_search", "read_web_page", "list_tasks", "list_model_capabilities", "computer_snapshot", "show_file", "search_chats", "run_diagnostics", "recover_changes", "verify_result"])

    static func isRead(_ call: ToolCall) -> Bool {
        if readsAllowed.contains(call.name) { return true }
        guard let args = try? JSONValue.parse(call.arguments) else { return false }
        if call.name == "manage_memory" { return ["list", "read", "history"].contains(args["action"].string ?? "") }
        if call.name == "browser_action" { return ["tabs", "read"].contains(args["action"].string ?? "") }
        if call.name == "manage_skill" { return ["list", "read"].contains(args["action"].string ?? "") }
        if call.name == "http_request" { return ["GET", "HEAD"].contains((args["method"].string ?? "GET").uppercased()) }
        return false
    }

    static func key(_ call: ToolCall) -> String {
        if call.name == "generate_image", let args = try? JSONValue.parse(call.arguments), let imageKey = ImageActionIdentity.key(args) { return "generate_image:" + imageKey }
        let data = call.arguments.data(using: .utf8) ?? Data()
        let canonical = (try? JSONSerialization.jsonObject(with: data)).flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys, .fragmentsAllowed]) }
        return call.name + ":" + (canonical.flatMap { String(data: $0, encoding: .utf8) } ?? call.arguments)
    }

    init(history: [LMMessage] = []) {
        var calls: [String: ToolCall] = [:]
        for message in history {
            for call in message.toolCalls { calls[call.id] = call }
            if message.role == "tool", let id = message.toolCallID, let call = calls.removeValue(forKey: id) {
                // A correction explicitly prevented execution; it is safe to issue the new step.
                guard message.content?.hasPrefix("Не выполнено:") != true else { continue }
                record(call, output: message.content ?? "", uncertain: message.content?.hasPrefix("Ошибка:") == true || message.content?.hasPrefix("Операция прервана") == true)
            }
        }
        for call in calls.values { record(call, output: "Результат операции не был сохранён до прерывания.", uncertain: true) }
    }

    mutating func repeated(_ call: ToolCall) -> Receipt? {
        let key = Self.key(call)
        if Self.isRead(call) {
            reads[key, default: 0] += 1
            // Allow a verification read; break an unchanged read loop after that.
            guard reads[key, default: 0] > 2 else { return nil }
            return Receipt(output: "Одинаковое чтение уже повторялось. Используй полученные данные или уточни недостающее.", uncertain: false)
        }
        return receipts[key]
    }

    mutating func record(_ call: ToolCall, output: String, uncertain: Bool = false) {
        guard !Self.isRead(call) else { return }
        if !uncertain { reads = [:] }
        receipts[Self.key(call)] = Receipt(output: String(output.prefix(6000)), uncertain: uncertain)
    }
}
