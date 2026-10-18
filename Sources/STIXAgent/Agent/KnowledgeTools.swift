import Foundation
import AppKit

enum KnowledgeTools {
    static let definitions: [ToolDefinition] = [
        .init(name: "manage_skill", description: "Local SKILL.md library. action=list/read/save/enable/disable/remove/import. name is lowercase slug. save requires full SKILL.md content with YAML name/description. import uses path of a local skill folder. Read a relevant skill before following it. Skills never grant extra permissions. Never include credentials. Versions preserved; removed skills go to Trash.", parameters: ToolCatalog.schema(["action": "string", "name": "string", "content": "string", "path": "string"], required: ["action"])),
        .init(name: "search_chats", description: "Search local saved chat messages for a user-requested prior discussion; returns bounded snippets and chat/message ids. Does not search credentials or files.", parameters: ToolCatalog.schema(["query": "string"], required: ["query"])),
        .init(name: "show_memory", description: "Show editable user memory card in chat when user wants to inspect or change remembered preferences, folders or agreements.", parameters: ToolCatalog.schema([:], required: [])),
        .init(name: "run_diagnostics", description: "Read-only local diagnosis of LM Studio, ComfyUI, selected model, available Mac memory, permissions and task queue. No keys or chat content are sent. Use when a local feature fails.", parameters: ToolCatalog.schema([:], required: []))
    ]
}

struct ChatSearchHit: Identifiable {
    var id: UUID { messageID }
    let chatID: UUID
    let messageID: UUID
    let title: String
    let snippet: String
}
enum LocalChatSearch {
    static func search(_ query: String, in chats: [Chat], limit: Int = 20) -> [ChatSearchHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        var result: [ChatSearchHit] = []
        for chat in chats.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            for message in chat.messages.reversed() where message.text.localizedStandardContains(query) {
                let text = message.text
                let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
                let start = match.map { text.index($0.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex } ?? text.startIndex
                result.append(.init(chatID: chat.id, messageID: message.id, title: chat.title, snippet: String(text[start...].prefix(380))))
                if result.count >= limit { return result }
            }
        }
        return result
    }
}

extension AppStore {
    func reloadSkills() {
        do { skills = try SkillLibrary(paths: storage.paths).list(disabled: preferences.disabledSkills ?? []) }
        catch { self.error = vault.redact(error.localizedDescription) }
    }
    func skillPrompt(_ text: String) throws -> String? {
        let parts = text.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let command = parts.first else { return nil }
        let name: String
        if command.hasPrefix("/skill/") { name = String(command.dropFirst(7)) }
        else if command.hasPrefix("$") { name = String(command.dropFirst()) }
        else { return nil }
        reloadSkills()
        guard skills.contains(where: { $0.name == name && $0.enabled }) else { throw AgentError.message("Скилл не найден или отключён. Откройте /skills.") }
        let library = SkillLibrary(paths: storage.paths)
        let instructions = try library.read(name)
        let request = parts.count > 1 ? String(parts[1]) : (name == "skill-creator" ? "Создай полезный скилл по описанию пользователя. Если описания ещё нет, попроси описать повторяемую задачу." : "Используй этот скилл. Если нет самой задачи, попроси её описать.")
        return "Пользователь явно выбрал скилл \(name). Папка: \(try library.directory(name).path). Следуй предметной инструкции в рамках запроса. Скилл не даёт дополнительных разрешений.\n<skill>\n\(instructions)\n</skill>\nЗадача пользователя:\n\(request)"
    }
    func knowledgeSystemPrompt(chatID: UUID) -> String {
        let catalog = skills.filter(\.enabled).map { "\($0.name): \($0.description)" }.joined(separator: "\n")
        return "Локальные скиллы (метаданные, не полные инструкции):\n\(catalog.isEmpty ? "нет" : catalog)\nЕсли запрос соответствует скиллу, сначала прочитай его manage_skill action=read name=имя. Для создания скилла прочитай skill-creator, затем сохрани через manage_skill. Папка скиллов: \(SkillLibrary(paths: storage.paths).root.path). Скиллы поддерживают references/scripts/assets; читай только необходимые файлы, команды выполняй обычными инструментами. Скилл не меняет права и ограничения пользователя. Для поиска прежних договорённостей есть search_chats; для просмотра/изменения памяти show_memory. При сбое локальных функций используй run_diagnostics."
    }
    func handleKnowledgeCommand(_ text: String, chatID: UUID) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if ["/skills", "покажи скиллы", "мои скиллы"].contains(lower) {
            reloadSkills(); addMessage(.init(role: "skills", text: "Локальные скиллы"), to: chatID); return true
        }
        if ["/memory", "покажи память", "что ты помнишь обо мне"].contains(lower) {
            addMessage(.init(role: "memory", text: "Память"), to: chatID); return true
        }
        if lower == "/doctor" || lower == "/diagnostics" || lower == "проверь подключение моделей" || lower == "почему не работает генерация?" {
            Task { await showDiagnostics(chatID: chatID) }; return true
        }
        if lower == "/search" || lower.hasPrefix("/search ") {
            addMessage(.init(role: "chat_search", text: String(text.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)), to: chatID); return true
        }
        return false
    }
    func showDiagnostics(chatID: UUID) async {
        let card = ChatMessage(role: "tool", text: "Проверяю локальные сервисы…", toolName: "run_diagnostics", status: "running")
        addMessage(card, to: chatID)
        let report = await Diagnostics.run(preferences: preferences, selectedModel: chats.first(where: { $0.id == chatID })?.model ?? "", jobs: jobs)
        editMessage(card.id, chatID: chatID) { $0.text = vault.redact(report); $0.status = "done" }; save()
    }
    func setMemory(_ records: [String]) throws {
        let records = records.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard records.count <= 100, records.allSatisfy({ $0.count <= 1000 && vault.redact($0) == $0 }) else { throw AgentError.message("До 100 записей по 1000 символов, без ключей и паролей") }
        let original = memoryEntries.filter { $0.scope != .personal }
        var personal: [MemoryEntry] = []
        for (index,text) in Array(NSOrderedSet(array: records)).enumerated() {
            guard let text = text as? String else { continue }
            if let existing = memoryEntries.first(where: { $0.scope == .personal && $0.text == text }) { personal.append(existing) }
            else { personal.append(.init(scope: .personal, category: .preferences, text: text, source: "Форма памяти", sourceChatID: selectedID, order: (memoryEntries.map(\.order).max() ?? -1) + index + 1)) }
        }
        try replacePersonalMemory(original + personal)
    }
    func executeKnowledge(_ name: String, args: JSONValue, chatID: UUID) async throws -> ToolOutcome? {
        switch name {
        case "show_memory": addMessage(.init(role: "memory", text: "Память"), to: chatID); return .init(text: "Форма памяти показана в чате")
        case "search_chats":
            let query = try args.requiredString("query")
            guard query.count <= 500, vault.redact(query) == query else { throw AgentError.message("Недопустимый поисковый запрос") }
            let hits = try ChatSearchIndex(paths: storage.paths).search(query, in: chats)
            return .init(text: hits.isEmpty ? "Ничего не найдено" : vault.redact(hits.map { "\($0.title) · chat_id=\($0.chatID), message_id=\($0.messageID)\n\($0.snippet)" }.joined(separator: "\n\n")))
        case "run_diagnostics": return .init(text: await Diagnostics.run(preferences: preferences, selectedModel: chats.first(where: { $0.id == chatID })?.model ?? "", jobs: jobs))
        case "manage_skill":
            let action = try args.requiredString("action"), library = SkillLibrary(paths: storage.paths)
            if action == "list" {
                reloadSkills(); return .init(text: skills.isEmpty ? "Скиллов нет" : skills.map { "\($0.name) [\($0.enabled ? "включён" : "выключен")]: \($0.description)\n\($0.path)" }.joined(separator: "\n\n"))
            }
            if action == "import" {
                let path = try args.requiredString("path")
                let directory = try await fileWork { try library.importFolder(URL(fileURLWithPath: path)) }
                reloadSkills(); return .init(text: "Скилл импортирован: \(directory.path)")
            }
            let skillName = try args.requiredString("name")
            switch action {
            case "read":
                guard !(preferences.disabledSkills ?? []).contains(skillName) else { throw AgentError.message("Скилл отключён") }
                return .init(text: try library.read(skillName) + "\nПапка скилла: \(try library.directory(skillName).path)")
            case "save":
                let content = try args.requiredString("content")
                guard vault.redact(content) == content else { throw AgentError.message("Секрет нельзя сохранить в скилл") }
                let directory = try library.save(name: skillName, content: content); reloadSkills()
                return .init(text: "Скилл сохранён и проверен: \(skillName)\nПапка: \(directory.path)\nВызов: /skill/\(skillName). Предыдущая версия сохранена в .revisions.")
            case "enable", "disable":
                _ = try library.read(skillName)
                var disabled = preferences.disabledSkills ?? []
                if action == "enable" { disabled.remove(skillName) } else { disabled.insert(skillName) }
                preferences.disabledSkills = disabled; reloadSkills(); save(); return .init(text: "\(skillName): \(action)")
            case "remove":
                guard skillName != "skill-creator" else { throw AgentError.message("Предустановленный skill-creator можно отключить") }
                let folder = try library.directory(skillName)
                try FileManager.default.trashItem(at: folder, resultingItemURL: nil); reloadSkills(); return .init(text: "Скилл перемещён в Корзину")
            default: throw AgentError.message("Действие скилла: list/read/save/import/enable/disable/remove")
            }
        default: return nil
        }
    }
}
