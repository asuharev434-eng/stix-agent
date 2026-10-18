import Foundation

struct ToolOutcome { var text: String; var attachments: [Attachment] = []; var undo: UndoRecord? = nil }

extension AppStore {
    func allTools() -> [ToolDefinition] {
        var list = ToolCatalog.builtins + ExtendedToolCatalog.definitions + ModelOrchestrator.definitions + ComputerTools.definitions + TaskControlTools.definitions + KnowledgeTools.definitions
        if preferences.webSearchEnabled != false { list += WebSearchClient.definitions }
        for (id, tools) in pluginTools {
            for tool in tools {
                list.append(.init(name: ApprovalPolicy.pluginToolName(pluginID: id, name: tool.name), description: "MCP \(tool.name): \(tool.description)", parameters: tool.parameters))
            }
        }
        return list
    }
    func execute(_ call: ToolCall, chatID: UUID) async throws -> ToolOutcome {
        try Task.checkCancellation()
        guard canPersist else { throw AgentError.message("Хранилище недоступно; действия остановлены до восстановления записи") }
        guard let i = index(chatID) else { throw CancellationError() }
        let args = try JSONValue.parse(call.arguments)
        guard let object = args.object else { throw AgentError.message("Аргументы инструмента должны быть объектом") }
        if let definition = allTools().first(where: { $0.name == call.name }) {
            for field in definition.parameters["required"].array ?? [] {
                if let key = field.string, object[key] == nil || object[key] == .null { throw AgentError.message("Отсутствует аргумент \(key)") }
            }
            for (key, value) in object {
                guard value != .null, let type = definition.parameters["properties"][key]["type"].string else { continue }
                let valid: Bool
                switch type {
                case "string": valid = value.string != nil
                case "integer": valid = value.int != nil
                case "number": if case .number = value { valid = true } else { valid = false }
                case "boolean": valid = value.bool != nil
                case "object": valid = value.object != nil
                case "array": valid = value.array != nil
                default: valid = true
                }
                guard valid else { throw AgentError.message("Аргумент \(key): ожидается \(type)") }
            }
            if definition.parameters["additionalProperties"].bool == false {
                let properties = definition.parameters["properties"].object ?? [:]
                guard Set(object.keys).isSubset(of: Set(properties.keys)) else { throw AgentError.message("Неизвестные аргументы инструмента") }
            }
        } else { throw AgentError.message("Неизвестный инструмент \(call.name)") }
        let folder = chats[i].folder ?? FileManager.default.homeDirectoryForCurrentUser.path
        let files = FileTools(paths: storage.paths)
        if let result = try await executeKnowledge(call.name, args: args, chatID: chatID) { return result }
        switch call.name {
        case "list_files": return .init(text: try await fileWork { try files.list(path: args.requiredString("path"), workingDirectory: folder) })
        case "read_file": return .init(text: try await fileWork { try files.read(path: args.requiredString("path"), workingDirectory: folder, offset: args["offset"].int ?? 0, limit: args["limit"].int ?? 30000) })
        case "search_files": return .init(text: try await fileWork { try files.search(path: args.requiredString("path"), query: args.requiredString("query"), workingDirectory: folder) })
        case "write_file":
            guard let content = args["content"].string, content.utf8.count <= 2_000_000 else { throw AgentError.message("Недопустимое содержимое файла (максимум 2 МБ)") }
            let safeContent = vault.redact(content)
            let record = try await fileWork { try files.write(path: args.requiredString("path"), content: safeContent, workingDirectory: folder) }
            registerUndo(record)
            return .init(text: "Файл сохранён: \(record.source)", attachments: [.init(path: record.source, kind: "file")], undo: record)
        case "move_file":
            let record = try await fileWork { try files.move(source: args.requiredString("source"), destination: args.requiredString("destination"), workingDirectory: folder) }
            registerUndo(record); return .init(text: "Перемещено: \(record.source) → \(record.destination ?? "")", undo: record)
        case "trash_file":
            let record = try await fileWork { try files.trash(path: args.requiredString("path"), workingDirectory: folder) }
            registerUndo(record); return .init(text: "Перемещено в Корзину: \(record.source)", undo: record)
        case "run_shell":
            let command = try args.requiredString("command")
            guard command.utf8.count <= 30000 else { throw AgentError.message("Команда слишком длинная") }
            let canonicalFolder = try files.resolve(folder, workingDirectory: nil).path
            var permissionArguments = object
            permissionArguments["working_directory"] = .string(canonicalFolder)
            let taskScope = ApprovalPolicy.scope(tool: "run_shell_task", arguments: .object(["directory": .string(canonicalFolder)]))
            try await approve(tool: call.name, arguments: .object(permissionArguments), title: "Выполнить команду?", detail: "Папка: " + canonicalFolder + "\n" + command + "\n\n«Для этой задачи» разрешает последующие команды терминала в этой рабочей папке до завершения задачи. «Всегда» относится только к этой точной команде.", chatID: chatID, taskScope: taskScope)
            let refs = try JSONDecoder().decode([String: String].self, from: Data((args["environment_json"].string ?? "{}").utf8))
            guard refs.values.allSatisfy({ id in preferences.secrets.contains(where: { $0.id == id }) }) else { throw AgentError.message("Неизвестная ссылка на секрет") }
            let environment = try CredentialEnvironment.resolve(refs, vault: vault)
            let result = try await processRunner.run(command: command, directory: folder, timeout: TimeInterval(min(max(args["timeout"].int ?? 120, 1), 600)), environment: environment)
            return .init(text: "Exit \(result.exitCode)\(result.timedOut ? " · timeout" : "")\n\(vault.redact(result.output))")
        case "ask_user":
            guard questionAllowed(chatID: chatID) else { return .init(text: "Лимит дополнительных вопросов исчерпан. Выполняй задачу с безопасными допущениями. Не задавай вопрос в обычном тексте вместо инструмента. Если безопасное действие невозможно — объясни причину и остановись.") }
            let question = try args.requiredString("question")
            let options = args["options"].string?.split(separator: "|").map(String.init) ?? []
            let response = await interact(.init(kind: .question, title: question, detail: "", choices: Array(options.prefix(8))), chatID: chatID)
            try Task.checkCancellation()
            guard case .text(let text) = response else { throw ActionDenied() }
            addMessage(.init(role: "user", text: text), to: chatID)
            return .init(text: vault.redact(text))
        case "set_preference":
            return .init(text: try applyPreference(key: args.requiredString("key"), value: args.requiredString("value"), chatID: chatID))
        case "request_secret":
            let id = UUID().uuidString
            let label = try args.requiredString("label")
            try await collectSecret(id: id, label: label, detail: "Секрет будет сохранён в Связке ключей. Он не попадёт в историю и контекст модели.", chatID: chatID)
            preferences.secrets.append(.init(id: id, label: label)); save()
            return .init(text: "Сохранено в Keychain. credential_id: \(id). Значение модели недоступно.")
        case "connect_api": return try await connectAPI(args, chatID: chatID)
        case "list_connections":
            return .init(text: preferences.connections.map { "\($0.id) | \($0.name) | \($0.baseURL) | auth=\($0.auth) | docs=\($0.documentationPath)" }.joined(separator: "\n"))
        case "manage_connection":
            let id = try args.requiredString("connection_id"), action = try args.requiredString("action")
            guard let connection = preferences.connections.first(where: { $0.id == id }) else { throw AgentError.message("Подключение не найдено") }
            if action == "replace_secret" {
                guard connection.auth != "none" else { throw AgentError.message("Подключение не использует ключ") }
                if connection.auth == "oauth" {
                    let config = try OAuthConfiguration.load(directory: connection.documentationPath)
                    try await approve(tool: "oauth_reauthorize", arguments: args, title: "Повторно войти в \(connection.name)?", detail: config.authorizationEndpoint, chatID: chatID)
                    try await OAuthClient.shared.authorize(configuration: config, credentialID: id, vault: vault)
                } else { try await collectSecret(id: id, label: "Новый ключ для \(connection.name)", detail: "Старый ключ будет заменён в Keychain. Значение не попадёт в чат.", chatID: chatID) }
            } else if action == "remove" {
                try vault.remove(id); preferences.connections.removeAll { $0.id == id }; save()
            } else { throw AgentError.message("Действие: remove или replace_secret") }
            return .init(text: "Подключение \(connection.name): \(action)")
        case "http_request":
            let connectionID = try args.requiredString("connection_id")
            guard let connection = preferences.connections.first(where: { $0.id == connectionID }) else { throw AgentError.message("Подключение не найдено") }
            let method = try args.requiredString("method").uppercased()
            let path = try args.requiredString("path")
            let url = try APIClient.requestURL(baseURL: connection.baseURL, path: path)
            // First exact request grants the user a reviewable destination; writes always follow exact request scope.
            try await approve(tool: call.name, arguments: args, title: "Запрос к \(connection.name)", detail: "\(method) \(url.absoluteString)\n\(args["body"].string ?? "")", chatID: chatID)
            return .init(text: try await APIClient(vault: vault).request(connection: connection, path: path, method: method, body: args["body"].string))
        case "add_plugin": return try await addPlugin(args, chatID: chatID)
        case "manage_plugin": return try await managePlugin(args, chatID: chatID)
        case "present_artifact": return try presentArtifact(args, chatID: chatID)
        case "import_image_workflow":
            let name = try args.requiredString("name"), raw = try args.requiredString("workflow_json")
            guard raw.utf8.count <= 2_000_000 else { throw AgentError.message("Workflow превышает 2 МБ") }
            let template = try JSONValue.parse(raw)
            _ = try ComfyClient.bindWorkflow(template, prompt: "validation", checkpoint: "", seed: 1)
            try await approve(tool: call.name, arguments: args, title: "Добавить workflow \(name)?", detail: "ComfyUI выполнит узлы этого workflow. Импортируйте только доверенные схемы.\n" + String(raw.prefix(4000)), chatID: chatID)
            let id = UUID().uuidString.lowercased()
            let url = storage.paths.workflows.appendingPathComponent(id + ".json")
            try Data(raw.utf8).write(to: url, options: .atomic)
            preferences.imageProfiles.append(.init(id: id, name: name, path: url.path)); save()
            return .init(text: "Профиль добавлен: \(name). Выберите его в режиме /image.")
        case "show_file":
            let url = try files.resolve(args.requiredString("path"), workingDirectory: folder)
            guard FileManager.default.fileExists(atPath: url.path) else { throw AgentError.message("Файл не найден") }
            return .init(text: "Файл: \(url.lastPathComponent)", attachments: [.init(path: url.path, kind: ["png", "jpg", "jpeg", "webp", "gif", "heic"].contains(url.pathExtension.lowercased()) ? "image" : "file")])
        case "list_permissions": return .init(text: preferences.alwaysApprovals.sorted().joined(separator: "\n"))
        case "revoke_permissions":
            let scope = try args.requiredString("scope")
            if scope == "all" { preferences.alwaysApprovals = []; taskApprovals = [] }
            else { preferences.alwaysApprovals.remove(scope); taskApprovals.remove(scope) }
            save(); return .init(text: "Разрешения отозваны")
        default:
            if let result = try await executeExtended(call.name, args: args, chatID: chatID, folder: folder) { return result }
            for (id, definitions) in pluginTools {
                if let definition = definitions.first(where: { ApprovalPolicy.pluginToolName(pluginID: id, name: $0.name) == call.name }), let client = plugins[id] {
                    try await approve(tool: call.name, arguments: args, title: "Действие плагина", detail: "\(definition.name)\n\(args.encoded)", chatID: chatID)
                    return .init(text: vault.redact(try await client.call(name: definition.name, arguments: args).encoded))
                }
            }
            throw AgentError.message("Инструмент плагина недоступен")
        }
    }
    func applyPreference(key: String, value: String, chatID: UUID) throws -> String {
        switch key {
        case "theme":
            guard ["dark", "light", "system"].contains(value) else { throw AgentError.message("Тема: dark, light, system") }
            preferences.theme = value
        case "lm_endpoint": _ = try ApprovalPolicy.validateEndpoint(value, localOnly: true); preferences.lmEndpoint = value
        case "comfy_endpoint": _ = try ApprovalPolicy.validateEndpoint(value, localOnly: true); preferences.comfyEndpoint = value
        case "default_model":
            guard models.contains(where: { $0.id == value }) else { throw AgentError.message("Модель не найдена в LM Studio") }
            preferences.defaultModel = value; if let i = index(chatID) { chats[i].model = value }
        case "web_search_enabled":
            guard ["true", "false"].contains(value) else { throw AgentError.message("web_search_enabled: true/false") }; preferences.webSearchEnabled = value == "true"
        case "voice_language":
            guard value.range(of: #"^[a-z]{2,3}[-_][A-Z]{2}$"#, options: .regularExpression) != nil else { throw AgentError.message("Язык диктовки: ru-RU, en-US и другие коды языка-региона") }; preferences.voiceLanguage = value
        case "image_prompt_language":
            guard ["auto", "en", "ru", "zh", "ja"].contains(value) else { throw AgentError.message("Язык промпта: auto/en/ru/zh/ja") }; if let i = index(chatID) { chats[i].imagePromptLanguage = value }
        case "font_size":
            guard let number = Double(value), number.isFinite, (11...24).contains(number) else { throw AgentError.message("Размер шрифта: 11–24") }; preferences.fontSize = number
        case "spacing":
            guard let number = Double(value), number.isFinite, (12...48).contains(number) else { throw AgentError.message("Отступы: 12–48") }; preferences.spacing = number
        case "question_level":
            guard let number = Int(value), (0...4).contains(number) else { throw AgentError.message("Уровень вопросов: 0–4") }; preferences.questionLevel = number; if let i = index(chatID) { chats[i].questionLevel = number }
        case "working_directory":
            let url = URL(fileURLWithPath: NSString(string: value).expandingTildeInPath)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { throw AgentError.message("Папка не найдена") }
            if let i = index(chatID) { chats[i].folder = url.path }
        default: throw AgentError.message("Неизвестная настройка")
        }; save(); return "Применено: \(key) = \(value)"
    }
    func collectSecret(id: String, label: String, detail: String, chatID: UUID) async throws {
        let answer = await interact(.init(kind: .secret, title: label, detail: detail), chatID: chatID)
        try Task.checkCancellation()
        guard case .text(let value) = answer, !value.isEmpty else { throw ActionDenied() }
        try vault.set(value, for: id)
    }
    func connectAPI(_ args: JSONValue, chatID: UUID) async throws -> ToolOutcome {
        let name = try args.requiredString("name"), base = try args.requiredString("base_url"), auth = try args.requiredString("auth")
        _ = try ApprovalPolicy.validateEndpoint(base)
        guard ["bearer", "header", "basic", "none", "oauth"].contains(auth) else { throw AgentError.message("Неизвестный тип авторизации") }
        let header = args["header_name"].string ?? "X-API-Key"
        guard header.range(of: #"^[A-Za-z][A-Za-z0-9-]{0,63}$"#, options: .regularExpression) != nil,
              !["host", "content-length", "connection", "cookie"].contains(header.lowercased()) else { throw AgentError.message("Недопустимое имя заголовка") }
        try await approve(tool: "connect_api", arguments: args, title: "Подключить \(name)?", detail: "\(base)\nАвторизация: \(auth). Ключ хранится только в Keychain.", chatID: chatID)
        let id = UUID().uuidString.lowercased()
        let directory = storage.paths.documentation.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if auth == "oauth" {
            let config = OAuthConfiguration(authorizationEndpoint: try args.requiredString("authorization_url"), tokenEndpoint: try args.requiredString("token_url"), clientID: try args.requiredString("client_id"), scopes: (args["scopes"].string ?? "").split(separator: " ").map(String.init))
            try config.validate()
            try await approve(tool: "oauth_authorize", arguments: args, title: "Войти через OAuth?", detail: "Сервис: \(base)\nАвторизация: \(config.authorizationEndpoint)\nToken endpoint: \(config.tokenEndpoint)\nПрава: \(config.scopes.joined(separator: ", "))", chatID: chatID)
            try JSONEncoder().encode(config).write(to: directory.appendingPathComponent("oauth.json"), options: .atomic)
            try await OAuthClient.shared.authorize(configuration: config, credentialID: id, vault: vault)
        } else if auth != "none" { try await collectSecret(id: id, label: "Ключ для \(name)", detail: "Адрес: \(base)\n\(auth == "basic" ? "Введите username:password" : "Введите API-ключ"). Значение не будет отправлено модели.", chatID: chatID) }
        let connection = APIConnection(id: id, name: name, baseURL: base, auth: auth, headerName: header, documentationPath: directory.path)
        preferences.connections.append(connection); save()
        return .init(text: "Подключено: \(name)\nconnection_id: \(id)\nДокументацию API положите в: \(directory.path)", attachments: [.init(path: directory.path, kind: "folder")])
    }
    func addPlugin(_ args: JSONValue, chatID: UUID) async throws -> ToolOutcome {
        let name = try args.requiredString("name"), transport = try args.requiredString("transport")
        guard ["stdio", "http"].contains(transport) else { throw AgentError.message("Транспорт: stdio или http") }
        let command = args["command"].string ?? ""
        let arguments: [String] = try JSONDecoder().decode([String].self, from: Data((args["arguments_json"].string ?? "[]").utf8))
        let url = args["url"].string ?? ""
        if transport == "http" { _ = try ApprovalPolicy.validateEndpoint(url) }
        if transport == "stdio", command.isEmpty { throw AgentError.message("Не задана команда плагина") }
        try await approve(tool: "add_plugin", arguments: args, title: "Добавить плагин \(name)?", detail: transport == "stdio" ? ([command] + arguments).joined(separator: " ") : url, chatID: chatID)
        let config = PluginConfig(id: String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)), name: name, transport: transport, command: command, arguments: arguments, url: url, enabled: true)
        try await activatePlugin(config); preferences.plugins.append(config); save()
        return .init(text: "Плагин подключён: \(name). Доступно инструментов: \(pluginTools[config.id]?.count ?? 0)")
    }
    func managePlugin(_ args: JSONValue, chatID: UUID) async throws -> ToolOutcome {
        let id = try args.requiredString("plugin_id"), action = try args.requiredString("action")
        guard let i = preferences.plugins.firstIndex(where: { $0.id == id }) else { throw AgentError.message("Плагин не найден") }
        if action == "enable" {
            let config = preferences.plugins[i]
            try await approve(tool: "enable_plugin", arguments: args, title: "Включить \(config.name)?", detail: config.transport == "stdio" ? ([config.command] + config.arguments).joined(separator: " ") : config.url, chatID: chatID)
            try await activatePlugin(config); preferences.plugins[i].enabled = true
        } else if ["disable", "remove"].contains(action) {
            if let client = plugins.removeValue(forKey: id) { await client.close() }; pluginTools.removeValue(forKey: id)
            if action == "remove" { preferences.plugins.remove(at: i) } else { preferences.plugins[i].enabled = false }
        } else { throw AgentError.message("Действие: enable, disable, remove") }
        save(); return .init(text: "Плагин: \(action)")
    }
    func presentArtifact(_ args: JSONValue, chatID: UUID? = nil) throws -> ToolOutcome {
        let kind = try args.requiredString("kind"), title = try args.requiredString("title"), content = vault.redact(try args.requiredString("content"))
        let extensions = ["html": "html", "mermaid": "mmd", "svg": "svg", "markdown": "md"]
        guard let ext = extensions[kind], content.utf8.count <= 2_000_000 else { throw AgentError.message("Недопустимый тип или размер артефакта") }
        let safe = title.replacingOccurrences(of: #"[^\p{L}\p{N} _-]"#, with: "", options: .regularExpression).prefix(70)
        let directory = (chatID.map { storage.paths.chatAttachments($0) } ?? storage.paths.attachments).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("\(safe.isEmpty ? "Artifact" : String(safe)).\(ext)")
        try Data(content.utf8).write(to: url, options: .atomic)
        return .init(text: title, attachments: [.init(path: url.path, kind: kind)])
    }
    func undoAction(_ id: UUID, chatID: UUID, messageID: UUID) {
        guard !undoing.contains(id), let record = undos[id] else { return }
        undoing.insert(id)
        let paths = storage.paths
        Task {
            defer { undoing.remove(id) }
            do {
                let result = try await fileWork { try FileChangePlanner(paths: paths).undo(record) }
                undos.removeValue(forKey: id)
                editMessage(messageID, chatID: chatID) { $0.undoID = nil; $0.status = "undone" }
                addMessage(.init(role: "assistant", text: result), to: chatID)
            } catch { self.error = vault.redact(error.localizedDescription) }
        }
    }

}

func fileWork<T>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
    let worker = Task.detached(priority: .userInitiated) { try Task.checkCancellation(); return try operation() }
    return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
}
