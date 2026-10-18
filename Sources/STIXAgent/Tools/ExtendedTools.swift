import Foundation

enum ExtendedToolCatalog {
    static let definitions: [ToolDefinition] = [
        .init(name: "recover_changes", description: "List durable file plans interrupted by application crash and their receipts. Read before replaying an interrupted apply_changes. Does not mutate files.", parameters: ToolCatalog.schema([:], required: [])),
        .init(name: "rollback_changes", description: "Rollback a durable file plan after approval. Resumes interrupted rollback, stops safely at conflicts. plan_id from preview_changes or recover_changes.", parameters: ToolCatalog.schema(["plan_id": "string"], required: ["plan_id"])),
        .init(name: "read_document", description: "Extract local PDF/DOCX/text/image OCR. Images can additionally be analyzed via delegate_model vision with image_paths_json.", parameters: ToolCatalog.schema(["path": "string"], required: ["path"])),
        .init(name: "preview_changes", description: "Preview file diff or batch operations without changing source. operations_json array: {kind:write,path,content}, {kind:move,source,destination}, {kind:trash,path}. Returns plan_id and visual artifact. Use before modifying existing code or sorting many files.", parameters: ToolCatalog.schema(["operations_json": "string"], required: ["operations_json"])),
        .init(name: "apply_changes", description: "Apply a reviewed file plan after host approval. Revalidates unchanged sources/destinations. Changes have undo receipts.", parameters: ToolCatalog.schema(["plan_id": "string"], required: ["plan_id"])),
        .init(name: "manage_memory", description: "list/remember/forget stable user preferences shared across chats. Remember only when user requests it; forget by exact text, or all when explicitly requested. Never store secrets.", parameters: ToolCatalog.schema(["action": "string", "text": "string"], required: ["action"])),
        .init(name: "configure_plugin_environment", description: "Map an environment variable to an existing credential_id from protected input for a stdio MCP plugin. No secret values in args. User approval required, plugin restarted. Empty credential_id removes mapping.", parameters: ToolCatalog.schema(["plugin_id": "string", "variable": "string", "credential_id": "string"], required: ["plugin_id", "variable", "credential_id"])),
        .init(name: "generate_image", description: "Generate or edit local ComfyUI image. For conversational edit of just-generated image set input_image='last' (same chat). Keep original. mask white edits/black preserves. Optional resize_only true resizes without diffusion. prompt required unless resize_only. width/height 256..2048 multiples8, steps1..100, count1..4; denoise0..1. For variants input_image last + count. Image prompt direct to Comfy.", parameters: ToolCatalog.schema(["prompt": "string", "input_image": "string", "mask": "string", "width": "integer", "height": "integer", "steps": "integer", "seed": "integer", "cfg": "number", "denoise": "number", "negative": "string", "count": "integer", "resize_only": "boolean"], required: []))
    ]
}

enum QuestionPolicy {
    static let budgets = [0, 1, 3, 6, 12]
    static func level(_ value: Int?) -> Int { min(4, max(0, value ?? 1)) }
    static func prompt(_ value: Int?) -> String {
        let level = level(value)
        return "Уровень уточнений \(level + 1)/5; не более \(budgets[level]) дополнительных вопросов на задачу. " + (level == 0 ? "Не задавай дополнительных вопросов. Принимай разумные безопасные допущения и выполняй задачу. Если без уточнения нельзя безопасно продолжить, кратко объясни препятствие и остановись." : level == 4 ? "Можно провести подробное интервью, но не повторяй отвеченные вопросы и спрашивай только полезное." : "Предпочитай действие и безопасные допущения. Не спрашивай разрешения на обычные шаги, не спрашивай то, что можно узнать инструментами. Вопросы собирай в один ясный запрос.") + " Подтверждения исполнителя и защищённый ввод не входят в этот лимит."
    }
}

extension AppStore {
    func lastImagePath(chatID: UUID) -> String? {
        chats.first(where: { $0.id == chatID })?.messages.reversed().flatMap(\.attachments).first(where: { $0.kind == "image" })?.path
    }
    func questionAllowed(chatID: UUID) -> Bool {
        let level = QuestionPolicy.level(chats.first(where: { $0.id == chatID })?.questionLevel ?? preferences.questionLevel)
        let asked = activeJobID.flatMap { id in jobs.first(where: { $0.id == id })?.questionsAsked } ?? 0
        guard asked < QuestionPolicy.budgets[level] else { return false }
        if let id = activeJobID, let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].questionsAsked = asked + 1 }; save(); return true
    }
    func executeExtended(_ name: String, args: JSONValue, chatID: UUID, folder: String) async throws -> ToolOutcome? {
        switch name {
        case "recover_changes":
            let paths = storage.paths
            let records = try await fileWork { try FileChangePlanner(paths: paths).recoveries() }
            return .init(text: records.isEmpty ? "Прерванных файловых планов нет" : records.map { "plan_id: \($0.planID) | \($0.status) | папка: \($0.workingDirectory) | квитанций: \($0.receipts.count)" }.joined(separator: "\n"))
        case "rollback_changes":
            let id = try args.requiredString("plan_id"), paths = storage.paths
            try await approve(tool: name, arguments: args, title: "Откатить файловый план?", detail: "План \(id). Изменённые после плана файлы не будут перезаписаны.", chatID: chatID)
            do {
                let receipts = try await fileWork { try FileChangePlanner(paths: paths).undoReceipts(id: id) }
                let results = try await fileWork { try FileChangePlanner(paths: paths).rollback(id: id) }
                let ids = Set(receipts.map(\.id))
                for receipt in ids { undos.removeValue(forKey: receipt) }
                for i in chats.indices { for j in chats[i].messages.indices { if let undoID = chats[i].messages[j].undoID, ids.contains(undoID) { chats[i].messages[j].undoID = nil; chats[i].messages[j].status = "undone" } } }; save()
                return .init(text: results.joined(separator: "\n"))
            } catch let error as FileChangePlanner.ApplyFailure { error.undoRecords.forEach(registerUndo); throw error }
        case "read_document":
            let path = try FileTools(paths: storage.paths).resolve(args.requiredString("path"), workingDirectory: folder)
            let image = ["png", "jpg", "jpeg", "webp", "heic"].contains(path.pathExtension.lowercased())
            let document = try await DocumentReader.prepare(attachments: [.init(path: path.path, kind: image ? "image" : "file")])
            return .init(text: vault.redact(document.text))
        case "preview_changes":
            let raw = vault.redact(try args.requiredString("operations_json"))
            guard raw.utf8.count <= 2_000_000 else { throw AgentError.message("План превышает 2 МБ") }
            let operations = try JSONValue.parse(raw), paths = storage.paths
            let preview = try await fileWork { try FileChangePlanner(paths: paths).preview(operations: operations, workingDirectory: folder) }
            return .init(text: "plan_id: \(preview.id)\n\(preview.summary)", attachments: [preview.attachment])
        case "apply_changes":
            let id = try args.requiredString("plan_id"), paths = storage.paths
            try await approve(tool: name, arguments: args, title: "Применить план изменений?", detail: "План \(id). Предпросмотр находится выше в чате. Изменения проверяются повторно перед записью.", chatID: chatID)
            do {
                let result = try await fileWork { try FileChangePlanner(paths: paths).apply(id: id, workingDirectory: folder) }
                for item in result.results { if let undo = item.undo { registerUndo(undo) } }
                return .init(text: result.results.map(\.text).joined(separator: "\n"))
            } catch let error as FileChangePlanner.ApplyFailure {
                error.undoRecords.forEach(registerUndo); throw error
            }
        case "manage_memory":
            let action = try args.requiredString("action"), text = vault.redact(args["text"].string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var memory = preferences.memory ?? []
            switch action {
            case "list": return .init(text: memory.isEmpty ? "Память пуста" : memory.joined(separator: "\n"))
            case "remember": guard !text.isEmpty, text.count <= 1000, memory.count < 100 else { throw AgentError.message("Память: до 100 записей по 1000 символов") }; if !memory.contains(text) { memory.append(text) }
            case "forget": if text == "all" { memory = [] } else { memory.removeAll { $0 == text } }
            default: throw AgentError.message("Память: list/remember/forget")
            }
            preferences.memory = memory; save(); return .init(text: "Память обновлена")
        case "list_model_capabilities": return .init(text: ModelOrchestrator.catalog(installed: models, assignments: preferences.modelRoles ?? [:]))
        case "configure_model_role": return try configureModelRole(args)
        case "delegate_model": return try await delegateModel(args, chatID: chatID)
        case "computer_snapshot": return try await computerTools.snapshot(args)
        case "computer_action", "browser_action":
            let readOnly = name == "browser_action" && ["tabs", "read"].contains(args["action"].string ?? "")
            if !readOnly { try await approve(tool: name, arguments: args, title: "Действие в приложении", detail: args.encoded, chatID: chatID) }
            return name == "computer_action" ? try computerTools.action(args) : try computerTools.browserAction(args)
        case "configure_plugin_environment":
            let id = try args.requiredString("plugin_id"), variable = try args.requiredString("variable")
            let credential = args["credential_id"].string ?? ""
            guard let config = preferences.plugins.first(where: { $0.id == id }), config.transport == "stdio" else { throw AgentError.message("Нужен stdio плагин") }
            try CredentialEnvironment.validateName(variable)
            if !credential.isEmpty { guard preferences.secrets.contains(where: { $0.id == credential }) else { throw AgentError.message("Сначала сохраните секрет через защищённый ввод") } }
            try await approve(tool: name, arguments: args, title: "Передать секрет плагину \(config.name)?", detail: "Переменная: \(variable). Плагин получит секрет при запуске. Значение не передаётся модели.", chatID: chatID)
            var mapping = preferences.pluginEnvironment ?? [:], refs = mapping[id] ?? [:]
            refs[variable] = credential.isEmpty ? nil : credential; mapping[id] = refs
            let prior = preferences.pluginEnvironment; preferences.pluginEnvironment = mapping
            do { if config.enabled { try await activatePlugin(config) }; save() }
            catch { preferences.pluginEnvironment = prior; throw error }
            return .init(text: "Ссылки на секреты плагина обновлены")
        case "generate_image":
            func quoted(_ text: String) -> String { JSONValue.string(text).encoded }
            var command = quoted(args["prompt"].string ?? "")
            let flags = ["input_image": "input", "mask": "mask", "width": "width", "height": "height", "steps": "steps", "seed": "seed", "cfg": "cfg", "denoise": "denoise", "negative": "negative", "count": "count"]
            for key in flags.keys.sorted() { if let value = args.object?[key] { command += " --\(flags[key]!) " + (value.string.map(quoted) ?? value.encoded) } }
            if args["resize_only"].bool == true { command += " --resize-only" }
            try await generateImage(prompt: command, chatID: chatID)
            return .init(text: "Новая версия изображения показана отдельной карточкой; исходная сохранена.")
        default: return nil
        }
    }
}
