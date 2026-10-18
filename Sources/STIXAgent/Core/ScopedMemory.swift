import Foundation
import CryptoKit

enum MemoryScope: String, Codable, CaseIterable, Identifiable {
    case personal, project, chat
    var id: String { rawValue }
    var title: String { switch self { case .personal: return "Обо мне"; case .project: return "Этот проект"; case .chat: return "Этот чат" } }
}
enum MemoryCategory: String, Codable, CaseIterable, Identifiable {
    case profile, preferences, overview, decisions, tasks, notes
    var id: String { rawValue }
    var title: String {
        switch self { case .profile: return "Обо мне"; case .preferences: return "Предпочтения"; case .overview: return "О проекте"; case .decisions: return "Решения"; case .tasks: return "Задачи"; case .notes: return "Заметки чата" }
    }
    static func allowed(_ scope: MemoryScope) -> [Self] {
        switch scope { case .personal: return [.profile, .preferences]; case .project: return [.overview, .decisions, .tasks]; case .chat: return [.notes] }
    }
}
struct MemoryEntry: Codable, Equatable, Identifiable {
    var id = UUID()
    var scope: MemoryScope
    var ownerID: UUID?
    var category: MemoryCategory
    var text: String
    var source: String
    var sourceChatID: UUID?
    var createdAt = Date()
    var updatedAt = Date()
    var order: Int
    var enabled = true
    var alwaysInclude: Bool? = nil
    var isCore: Bool { alwaysInclude ?? (category == .preferences || category == .overview || category == .notes) }
    func validated() throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.count <= 8000,
              !text.contains("<!-- stix-memory"), !text.contains("<!-- /stix-memory"),
              MemoryCategory.allowed(scope).contains(category), (scope == .personal) == (ownerID == nil) else {
            throw AgentError.message("Недопустимая запись памяти или область действия")
        }
    }
}
struct MemoryProject: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var folder: String
    var createdAt: Date
    static func identity(_ folder: String) -> (UUID, String) {
        let path = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path
        return (MemoryDocuments.stableID(path), path)
    }
}
enum MemoryDocuments {
    static let opening = "<!-- stix-memory "
    static let closing = "<!-- /stix-memory -->"
    static func stableID(_ key: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
    static func render(_ entries: [MemoryEntry], category: MemoryCategory) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var result = "# \(category.title)\n\n"
        for entry in entries.sorted(by: { $0.order < $1.order }) {
            try entry.validated()
            var metadata = entry; metadata.text = ""
            let json = String(decoding: try encoder.encode(metadata), as: UTF8.self)
            result += opening + json + " -->\n" + entry.text + "\n" + closing + "\n\n"
        }
        return Data(result.utf8)
    }
    static func parse(_ data: Data, scope: MemoryScope, ownerID: UUID?, category: MemoryCategory) throws -> [MemoryEntry] {
        guard let text = String(data: data, encoding: .utf8) else { throw AgentError.message("Память должна быть UTF-8 Markdown") }
        let lines = text.components(separatedBy: "\n")
        var entries: [MemoryEntry] = [], current: MemoryEntry?, body: [String] = []
        for (index,line) in lines.enumerated() {
            if line.hasPrefix(opening), line.hasSuffix(" -->") {
                guard current == nil else { throw AgentError.message("Повреждён блок памяти") }
                let raw = String(line.dropFirst(opening.count).dropLast(4))
                current = try JSONDecoder().decode(MemoryEntry.self, from: Data(raw.utf8)); body = []
            } else if line == closing {
                guard var entry = current else { throw AgentError.message("Неожиданный конец блока памяти") }
                entry.text = body.joined(separator: "\n")
                try entry.validated()
                guard entry.scope == scope, entry.ownerID == ownerID, entry.category == category else { throw AgentError.message("Область памяти не соответствует файлу") }
                entries.append(entry); current = nil; body = []
            } else if current != nil { body.append(line) }
            else if !line.isEmpty && !(index == 0 && line.hasPrefix("# ")) {
                throw AgentError.message("Текст вне блока памяти: изменяйте запись внутри её маркеров или через /memory")
            }
        }
        guard current == nil, Set(entries.map(\.id)).count == entries.count else { throw AgentError.message("Незавершённый или повторный блок памяти") }
        return entries
    }
    static func normalize(_ input: PersistedState) throws -> PersistedState {
        var state = input
        state.jobs = state.jobs ?? []
        state.features = state.features ?? FeatureConfiguration()
        try state.features?.validated()
        var projects = state.projects ?? []
        for i in state.chats.indices {
            if let folder = state.chats[i].folder {
                let (id,path) = MemoryProject.identity(folder)
                if !projects.contains(where: { $0.id == id }) { projects.append(.init(id: id, title: URL(fileURLWithPath: path).lastPathComponent, folder: path, createdAt: state.chats[i].updatedAt)) }
                state.chats[i].projectID = id
            } else { state.chats[i].projectID = nil }
        }
        state.projects = projects.sorted { $0.id.uuidString < $1.id.uuidString }
        if state.memoryEntries == nil {
            state.memoryEntries = (state.preferences.memory ?? []).enumerated().map { index,text in
                .init(id: stableID("legacy-\(index):\(text)"), scope: .personal, category: .preferences, text: text,
                      source: "Перенесено из прежней памяти", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0), order: index)
            }
        }
        state.memoryEntries = (state.memoryEntries ?? []).sorted { $0.order == $1.order ? $0.id.uuidString < $1.id.uuidString : $0.order < $1.order }
        for entry in state.memoryEntries ?? [] {
            try entry.validated()
            if entry.scope == .project, !projects.contains(where: { $0.id == entry.ownerID }) { throw AgentError.message("Проект записи памяти не найден") }
            if entry.scope == .chat, !state.chats.contains(where: { $0.id == entry.ownerID }) { throw AgentError.message("Чат записи памяти не найден") }
        }
        guard Set((state.memoryEntries ?? []).map(\.id)).count == (state.memoryEntries ?? []).count,
              Set(state.chats.map(\.id)).count == state.chats.count,
              Set(projects.map(\.id)).count == projects.count else { throw AgentError.message("Повторные идентификаторы хранилища") }
        state.memoryRevisions = state.memoryRevisions ?? []
        guard Set((state.memoryRevisions ?? []).map(\.id)).count == (state.memoryRevisions ?? []).count else { throw AgentError.message("Повторные идентификаторы версий памяти") }
        for revision in state.memoryRevisions ?? [] { try revision.validated() }
        state.preferences.memory = (state.memoryEntries ?? []).filter { $0.scope == .personal }.map(\.text)
        return state
    }
}
