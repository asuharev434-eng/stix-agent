import Foundation
import CryptoKit
import Darwin

struct SplitManifest: Codable {
    var version = 2
    var generation = UUID()
    var chats: [UUID]
    var projects: [UUID]
    var jobs: [UUID]
    var undos: [UUID]
    var memoryHistoryVersion: Int? = nil
    var featureVersion: Int? = nil
}
private struct StoredActions: Codable { var jobs: [AgentJob]; var undos: [UndoRecord] }
private struct StoredContext: Codable { var checkpoint: ContextCheckpoint? }
struct StoreTransaction: Codable {
    var id: UUID
    var files: [String: String]
}

enum StoreFiles {
    /// Foundation may preserve /var while directory enumerators return /private/var.
    static func canonical(_ url:URL)throws->URL {
        guard let path=realpath(url.path,nil) else{throw POSIXError(POSIXErrorCode(rawValue:errno) ?? .ENOENT)}
        defer{free(path)}
        return URL(fileURLWithPath:String(cString:path))
    }
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func url(_ relative: String, root: URL) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !components.isEmpty, components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }), !relative.hasPrefix("/") else { throw AgentError.message("Небезопасный путь хранилища") }
        var url = root
        for component in components {
            url.appendPathComponent(component)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink { throw AgentError.message("Символическая ссылка внутри хранилища запрещена") }
        }
        return url
    }
    static func read(_ relative: String, root: URL) throws -> Data { try Data(contentsOf: url(relative, root: root)) }
    static func write(_ data: Data, relative: String, root: URL) throws {
        let target = try url(relative, root: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try url(relative, root: root)
        try data.write(to: target, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
    static func jsonLines<T: Encodable>(_ records: [T]) throws -> Data {
        var result = Data()
        for record in records { result.append(try encode(record)); result.append(10) }
        return result
    }
    static func decodeLines<T: Decodable>(_ type: T.Type, data: Data) throws -> [T] {
        try data.split(separator: 10).map { try JSONDecoder().decode(type, from: Data($0)) }
    }
    static func allowedTransactionPath(_ path: String) -> Bool {
        if ["Features/config.json", "settings.json", "store.json", "state.json", "state.previous.json", "Memory/profile.md", "Memory/preferences.md", "Memory/history.jsonl", "Operations/orphans.json", "README.md", "Chats/index.md", "Projects/index.md", "Memory/README.md"].contains(path) { return true }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, UUID(uuidString: parts[1]) != nil else { return false }
        if parts[0] == "Chats" {
            if parts.count == 3 { return ["chat.json","messages.jsonl","history.jsonl","context.json","memory.md"].contains(parts[2]) }
            return parts.count == 4 && parts[2] == "Actions" && parts[3] == "state.json"
        }
        return parts[0] == "Projects" && parts.count == 3 && ["project.json","overview.md","decisions.md","tasks.md"].contains(parts[2])
    }
}

enum SplitStore {
    static func files(_ input: PersistedState) throws -> (PersistedState, [String: Data]) {
        let state = try MemoryDocuments.normalize(input)
        let entries = state.memoryEntries ?? [], jobs = state.jobs ?? []
        var files: [String: Data] = [:]
        files["README.md"] = Data("# STIX Agent · локальные данные\n\nsettings.json — настройки и ссылки на ключи (значения ключей остаются в Keychain).\nMemory/ — личные знания. Projects/ — знания рабочих папок. Chats/ — независимые переписки, контекст, действия и вложения.\n\nОткройте Chats/index.md или Projects/index.md, чтобы найти папку по названию. search.sqlite — восстанавливаемый индекс. Backups/Migrations — неизменённые прежние базы. state.json — небольшой указатель формата; store.json — манифест активных объектов.\n\nДля редактирования памяти используйте /memory. Для ручного изменения Markdown сначала закройте приложение; меняйте текст внутри блоков, сохраняя метаданные. Не изменяйте журналы и идентификаторы.\n".utf8)
        func label(_ text: String) -> String { text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]") }
        files["Chats/index.md"] = Data(("# Чаты\n\n" + state.chats.map { "- [\(label($0.title))](./\($0.id.uuidString)/chat.json)" }.joined(separator: "\n") + "\n").utf8)
        files["Projects/index.md"] = Data(("# Проекты\n\n" + (state.projects ?? []).map { "- [\(label($0.title))](./\($0.id.uuidString)/project.json) · \($0.folder)" }.joined(separator: "\n") + "\n").utf8)
        files["Memory/README.md"] = Data("# Личная память\n\nprofile.md — факты о пользователе; preferences.md — предпочтения. Проектные решения и задачи лежат в Projects/<id>/. Заметки чата — в Chats/<id>/memory.md.\n\nВнутри Markdown каждая запись имеет метаданные в HTML-комментарии: id, scope, ownerID, source/sourceChatID, createdAt/updatedAt, order, enabled и alwaysInclude. Видимый текст между маркерами — сама запись. Сохранённые пометки — данные, а не дополнительные разрешения агенту.\n".utf8)
        var settings = state.preferences; settings.memory = nil
        files["settings.json"] = try StoreFiles.encode(settings)
        files["Features/config.json"] = try StoreFiles.encode(state.features ?? FeatureConfiguration())
        files["Memory/history.jsonl"] = try StoreFiles.jsonLines(state.memoryRevisions ?? [])
        for category in MemoryCategory.allowed(.personal) {
            files["Memory/\(category.rawValue).md"] = try MemoryDocuments.render(entries.filter { $0.scope == .personal && $0.category == category }, category: category)
        }
        for project in state.projects ?? [] {
            let prefix = "Projects/\(project.id.uuidString)"
            files[prefix + "/project.json"] = try StoreFiles.encode(project)
            for category in MemoryCategory.allowed(.project) {
                files[prefix + "/\(category.rawValue).md"] = try MemoryDocuments.render(entries.filter { $0.scope == .project && $0.ownerID == project.id && $0.category == category }, category: category)
            }
        }
        var assignedUndos = Set<UUID>()
        for chat in state.chats {
            let prefix = "Chats/\(chat.id.uuidString)"
            guard var metadata = try JSONSerialization.jsonObject(with: StoreFiles.encode(chat)) as? [String: Any] else { throw AgentError.message("Неверные метаданные чата") }
            for key in ["messages","history","contextCheckpoint"] { metadata.removeValue(forKey: key) }
            files[prefix + "/chat.json"] = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            files[prefix + "/messages.jsonl"] = try StoreFiles.jsonLines(chat.messages)
            files[prefix + "/history.jsonl"] = try StoreFiles.jsonLines(chat.history)
            files[prefix + "/context.json"] = try StoreFiles.encode(StoredContext(checkpoint: chat.contextCheckpoint))
            files[prefix + "/memory.md"] = try MemoryDocuments.render(entries.filter { $0.scope == .chat && $0.ownerID == chat.id }, category: .notes)
            let localJobs = jobs.filter { $0.chatID == chat.id }
            let references = Set(chat.messages.compactMap(\.undoID) + localJobs.flatMap { $0.undoIDs ?? [] })
            let undos = state.undos.filter { references.contains($0.id) && !assignedUndos.contains($0.id) }
            assignedUndos.formUnion(undos.map(\.id))
            files[prefix + "/Actions/state.json"] = try StoreFiles.encode(StoredActions(jobs: localJobs, undos: undos))
        }
        let activeIDs = Set(state.chats.map(\.id))
        files["Operations/orphans.json"] = try StoreFiles.encode(StoredActions(jobs: jobs.filter { !activeIDs.contains($0.chatID) }, undos: state.undos.filter { !assignedUndos.contains($0.id) }))
        var manifest = SplitManifest(chats: state.chats.map(\.id), projects: (state.projects ?? []).map(\.id), jobs: jobs.map(\.id), undos: state.undos.map(\.id))
        manifest.memoryHistoryVersion = 1
        manifest.featureVersion = 1
        files["store.json"] = try StoreFiles.encode(manifest)
        files["state.json"] = Data("{\"version\":2,\"format\":\"split\",\"manifest\":\"store.json\"}".utf8)
        return (state,files)
    }
    static func load(root: URL) throws -> PersistedState {
        let decoder = JSONDecoder()
        let manifest = try decoder.decode(SplitManifest.self, from: StoreFiles.read("store.json", root: root))
        guard manifest.version == 2, Set(manifest.chats).count == manifest.chats.count,
              Set(manifest.projects).count == manifest.projects.count,
              Set(manifest.jobs).count == manifest.jobs.count, Set(manifest.undos).count == manifest.undos.count else { throw AgentError.message("Повреждён манифест хранилища") }
        guard manifest.memoryHistoryVersion == nil || manifest.memoryHistoryVersion == 1 else { throw AgentError.message("Неизвестный формат версий памяти") }
        let revisions = manifest.memoryHistoryVersion == 1 ? try StoreFiles.decodeLines(MemoryRevision.self, data: StoreFiles.read("Memory/history.jsonl", root: root)) : []
        guard manifest.featureVersion == nil || manifest.featureVersion == 1 else { throw AgentError.message("Неизвестная версия локальных функций") }
        let features = manifest.featureVersion == 1 ? try decoder.decode(FeatureConfiguration.self, from: StoreFiles.read("Features/config.json", root: root)) : FeatureConfiguration()
        var prefs = try decoder.decode(AppPreferences.self, from: StoreFiles.read("settings.json", root: root))
        var entries: [MemoryEntry] = [], projects: [MemoryProject] = [], chats: [Chat] = [], jobs: [AgentJob] = [], undos: [UndoRecord] = []
        for category in MemoryCategory.allowed(.personal) { entries += try MemoryDocuments.parse(StoreFiles.read("Memory/\(category.rawValue).md", root: root), scope: .personal, ownerID: nil, category: category) }
        for id in manifest.projects {
            let prefix = "Projects/\(id.uuidString)"
            let project = try decoder.decode(MemoryProject.self, from: StoreFiles.read(prefix + "/project.json", root: root))
            guard project.id == id else { throw AgentError.message("Подменён идентификатор проекта") }
            projects.append(project)
            for category in MemoryCategory.allowed(.project) { entries += try MemoryDocuments.parse(StoreFiles.read(prefix + "/\(category.rawValue).md", root: root), scope: .project, ownerID: id, category: category) }
        }
        for id in manifest.chats {
            let prefix = "Chats/\(id.uuidString)"
            guard var metadata = try JSONSerialization.jsonObject(with: StoreFiles.read(prefix + "/chat.json", root: root)) as? [String: Any] else { throw AgentError.message("Неверные метаданные чата") }
            metadata["messages"] = []; metadata["history"] = []
            var chat = try decoder.decode(Chat.self, from: JSONSerialization.data(withJSONObject: metadata))
            guard chat.id == id else { throw AgentError.message("Подменён идентификатор чата") }
            chat.messages = try StoreFiles.decodeLines(ChatMessage.self, data: StoreFiles.read(prefix + "/messages.jsonl", root: root))
            chat.history = try StoreFiles.decodeLines(LMMessage.self, data: StoreFiles.read(prefix + "/history.jsonl", root: root))
            chat.contextCheckpoint = try decoder.decode(StoredContext.self, from: StoreFiles.read(prefix + "/context.json", root: root)).checkpoint
            entries += try MemoryDocuments.parse(StoreFiles.read(prefix + "/memory.md", root: root), scope: .chat, ownerID: id, category: .notes)
            let actions = try decoder.decode(StoredActions.self, from: StoreFiles.read(prefix + "/Actions/state.json", root: root))
            chats.append(chat); jobs += actions.jobs; undos += actions.undos
        }
        let orphans = try decoder.decode(StoredActions.self, from: StoreFiles.read("Operations/orphans.json", root: root))
        jobs += orphans.jobs; undos += orphans.undos
        guard Set(jobs.map(\.id)).count == jobs.count, Set(undos.map(\.id)).count == undos.count,
              Set(jobs.map(\.id)) == Set(manifest.jobs), Set(undos.map(\.id)) == Set(manifest.undos) else { throw AgentError.message("Неполный журнал задач или отмены") }
        let jobMap = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id,$0) }), undoMap = Dictionary(uniqueKeysWithValues: undos.map { ($0.id,$0) })
        entries.sort { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
        prefs.memory = entries.filter { $0.scope == .personal }.map(\.text)
        return try MemoryDocuments.normalize(.init(chats: chats, preferences: prefs, undos: manifest.undos.compactMap { undoMap[$0] }, jobs: manifest.jobs.compactMap { jobMap[$0] }, memoryEntries: entries, projects: projects, memoryRevisions: revisions, features: features))
    }
}
