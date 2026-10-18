import Foundation
import SQLite3

/// Disposable search projection. Canonical chat files are always the source of truth.
struct ChatSearchIndex {
    let paths: AppStoragePaths
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private func folded(_ text: String) -> String { text.folding(options: [.caseInsensitive,.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
    func search(_ query: String, in chats: [Chat]) throws -> [ChatSearchHit] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        return try cached(query, chats: chats)
    }
    func synchronize(in chats: [Chat]) throws { _ = try cached(nil, chats: chats) }
    private func cached(_ query: String?, chats: [Chat]) throws -> [ChatSearchHit] {
        try paths.prepare()
        let url = try StoreFiles.url("search.sqlite", root: paths.root)
        do { return try perform(query, chats: chats, url: url) }
        catch {
            // Only the derived cache can be discarded, never canonical documents.
            _ = try StoreFiles.url("search.sqlite", root: paths.root)
            try? FileManager.default.removeItem(at: url)
            return try perform(query, chats: chats, url: url)
        }
    }
    private func perform(_ query: String?, chats: [Chat], url: URL) throws -> [ChatSearchHit] {
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url, options: [.atomic,.completeFileProtectionUnlessOpen]) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw AgentError.message("Не удалось открыть индекс поиска")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        func sql(_ text: String) throws {
            guard sqlite3_exec(db,text,nil,nil,nil) == SQLITE_OK else { throw AgentError.message("Не удалось обновить индекс поиска") }
        }
        func statement(_ text: String) throws -> OpaquePointer {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db,text,-1,&statement,nil) == SQLITE_OK, let statement else { throw AgentError.message("Неверная структура индекса поиска") }
            return statement
        }
        func bind(_ text: String, _ at: Int32, _ to: OpaquePointer) { sqlite3_bind_text(to,at,text,-1,Self.transient) }
        try sql("CREATE TABLE IF NOT EXISTS chats(id TEXT PRIMARY KEY,digest TEXT NOT NULL); CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY,chat TEXT NOT NULL,folded TEXT NOT NULL,updated REAL NOT NULL,position INTEGER NOT NULL); CREATE INDEX IF NOT EXISTS chat_messages ON messages(chat);")
        try sql("BEGIN IMMEDIATE")
        do {
            let existing = try statement("SELECT id,digest FROM chats")
            var digests: [String:String] = [:]
            while sqlite3_step(existing) == SQLITE_ROW { digests[String(cString: sqlite3_column_text(existing,0))] = String(cString: sqlite3_column_text(existing,1)) }
            sqlite3_finalize(existing)
            let active = Set(chats.map { $0.id.uuidString })
            for id in digests.keys where !active.contains(id) {
                for table in ["messages","chats"] {
                    let delete = try statement("DELETE FROM \(table) WHERE \(table == "messages" ? "chat" : "id")=?")
                    bind(id,1,delete); guard sqlite3_step(delete) == SQLITE_DONE else { sqlite3_finalize(delete); throw AgentError.message("Ошибка очистки индекса") }; sqlite3_finalize(delete)
                }
            }
            for chat in chats {
                let id = chat.id.uuidString
                let fingerprint = StoreFiles.digest(try StoreFiles.encode(chat.messages)) + String(chat.updatedAt.timeIntervalSince1970)
                guard digests[id] != fingerprint else { continue }
                let delete = try statement("DELETE FROM messages WHERE chat=?"); bind(id,1,delete); sqlite3_step(delete); sqlite3_finalize(delete)
                let insert = try statement("INSERT INTO messages(id,chat,folded,updated,position) VALUES(?,?,?,?,?)")
                for (position,message) in chat.messages.enumerated() {
                    sqlite3_reset(insert); sqlite3_clear_bindings(insert)
                    bind(message.id.uuidString,1,insert); bind(id,2,insert); bind(folded(message.text),3,insert)
                    sqlite3_bind_double(insert,4,chat.updatedAt.timeIntervalSince1970); sqlite3_bind_int64(insert,5,Int64(position))
                    guard sqlite3_step(insert) == SQLITE_DONE else { sqlite3_finalize(insert); throw AgentError.message("Ошибка заполнения индекса") }
                }
                sqlite3_finalize(insert)
                let update = try statement("INSERT OR REPLACE INTO chats(id,digest) VALUES(?,?)");bind(id,1,update);bind(fingerprint,2,update)
                guard sqlite3_step(update) == SQLITE_DONE else { sqlite3_finalize(update); throw AgentError.message("Ошибка версии индекса") };sqlite3_finalize(update)
            }
            try sql("COMMIT")
        } catch { try? sql("ROLLBACK"); throw error }
        guard let query else { return [] }
        let select = try statement("SELECT id FROM messages WHERE instr(folded,?)>0 ORDER BY updated DESC,position DESC LIMIT 20")
        defer { sqlite3_finalize(select) };bind(folded(query),1,select)
        var ids = Set<UUID>()
        while sqlite3_step(select) == SQLITE_ROW { if let id = UUID(uuidString: String(cString: sqlite3_column_text(select,0))) { ids.insert(id) } }
        let candidates = chats.map { chat -> Chat in var copy = chat; copy.messages = chat.messages.filter { ids.contains($0.id) }; return copy }
        return LocalChatSearch.search(query,in:candidates)
    }
}
