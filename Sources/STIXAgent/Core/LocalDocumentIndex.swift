import Foundation
import SQLite3

struct DocumentHit: Identifiable, Sendable {
    var id: String { path + ":\(page ?? 0):\(fragment)" }
    var path: String
    var page: Int?
    var fragment: Int
    var text: String
    var citation: String { URL(fileURLWithPath: path).lastPathComponent + (page.map { " · стр. \($0)" } ?? " · фрагмент \(fragment)") }
}

/// A disposable full-text cache. Canonical documents are never modified.
actor LocalDocumentIndex {
    let paths: AppStoragePaths
    init(paths: AppStoragePaths) { self.paths = paths }
    func rebuild(folders:[String]) async throws->String {
        for name in ["documents.sqlite","documents.sqlite-wal","documents.sqlite-shm"] {
            let file=try StoreFiles.url(name,root:paths.root)
            if FileManager.default.fileExists(atPath:file.path){try FileManager.default.removeItem(at:file)}
        }
        return try await refresh(folders:folders)
    }
    func refresh(folders: [String]) async throws -> String {
        let db = try DocumentDB(paths: paths), tools = FileTools(paths: paths)
        var seen = Set<String>(), updated = 0, failures: [String] = []
        for folder in folders {
            try Task.checkCancellation()
            let root = try tools.resolve(folder, workingDirectory: nil)
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey], options: [.skipsHiddenFiles]) else { throw AgentError.message("Не удалось открыть папку документов") }
            var visited = 0
            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation(); visited += 1
                guard visited <= 5000 else { throw AgentError.message("В папке документов более 5000 объектов; подключите более узкую папку") }
                let info = try url.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
                if info.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard info.isRegularFile == true, ["txt","md","markdown","json","csv","swift","py","js","ts","html","xml","yaml","yml","pdf","docx"].contains(url.pathExtension.lowercased()) else { continue }
                let path = try tools.resolve(url.path, workingDirectory: nil).path
                guard seen.insert(path).inserted else { continue }
                guard seen.count <= 1000 else { throw AgentError.message("В индекс разрешено до 1000 документов") }
                do {
                    guard (info.fileSize ?? Int.max) <= DocumentReader.maximumFileBytes else { throw AgentError.message("Файл больше 25 МБ") }
                    let digest = try await fileWork { try tools.digest(URL(fileURLWithPath: path)) }
                    if try db.digest(path) == digest { continue }
                    let text = try await DocumentReader.prepare(attachments: [.init(path: path, kind: "file")]).text
                    // Verify that extraction did not race a file rewrite.
                    guard try await fileWork({ try tools.digest(URL(fileURLWithPath: path)) }) == digest else { throw AgentError.message("Документ изменился при чтении") }
                    try db.replace(path: path, digest: digest, chunks: Self.chunks(text, pdf: url.pathExtension.lowercased() == "pdf")); updated += 1
                } catch {
                    if Task.isCancelled { throw CancellationError() }
                    try db.remove(path); failures.append(url.lastPathComponent + ": " + error.localizedDescription)
                }
            }
        }
        for path in try db.paths() where !seen.contains(path) { try db.remove(path) }
        return "Документов: \(seen.count), обновлено: \(updated)." + (failures.isEmpty ? "" : "\nНе удалось прочитать:\n" + failures.prefix(30).joined(separator: "\n"))
    }
    func search(_ query: String, folders: [String]) throws -> [DocumentHit] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, term.count <= 500 else { throw AgentError.message("Поисковый запрос: 1–500 символов") }
        let roots = try folders.map { try FileTools(paths: paths).resolve($0, workingDirectory: nil).path }
        return try DocumentDB(paths: paths).search(term).filter { hit in roots.contains { hit.path.hasPrefix($0 + "/") } && FileManager.default.fileExists(atPath: hit.path) }.prefix(30).map { $0 }
    }
    static func chunks(_ text: String, pdf: Bool) -> [(Int?,Int,String)] {
        var result: [(Int?,Int,String)] = [], page: Int? = nil, buffer = "", part = 0
        func flush() {
            while !buffer.isEmpty { let chunk = String(buffer.prefix(1800)); buffer.removeFirst(chunk.count); part += 1; result.append((page,part,chunk)) }
        }
        for line in text.components(separatedBy: "\n") {
            if pdf, line.hasPrefix("Страница "), let number = Int(line.dropFirst(9).dropLast()), line.hasSuffix(":") { flush(); page = number }
            else { buffer += line + "\n"; if buffer.count >= 1800 { flush() } }
        }
        flush(); return result
    }
}

private final class DocumentDB {
    private var db: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(paths: AppStoragePaths) throws {
        try paths.prepare(); let url = try StoreFiles.url("documents.sqlite", root: paths.root)
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw AgentError.message("Индекс документов недоступен; исходники сохранены") }
        sqlite3_busy_timeout(db, 2000)
        try exec("PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY,digest TEXT NOT NULL); CREATE TABLE IF NOT EXISTS chunks(path TEXT NOT NULL,page INTEGER,part INTEGER,text TEXT NOT NULL,folded TEXT NOT NULL); CREATE INDEX IF NOT EXISTS chunks_path ON chunks(path);")
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: url.path)
    }
    deinit { sqlite3_close(db) }
    private func exec(_ sql: String) throws { guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw AgentError.message("Не удалось обновить индекс документов; исходники не изменены") } }
    private func statement(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw AgentError.message("Не удалось прочитать индекс документов") }; return statement
    }
    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) { sqlite3_bind_text(statement, index, value, -1, transient) }
    private func done(_ statement: OpaquePointer) throws { guard sqlite3_step(statement) == SQLITE_DONE else { throw AgentError.message("Ошибка записи индекса документов") } }
    private func row(_ statement:OpaquePointer)throws->Bool {
        let status=sqlite3_step(statement)
        guard status==SQLITE_ROW || status==SQLITE_DONE else{throw AgentError.message("Индекс документов повреждён или недоступен. Перестройте индекс; исходные файлы сохранены")}
        return status==SQLITE_ROW
    }
    func digest(_ path: String) throws -> String? {
        let q = try statement("SELECT digest FROM files WHERE path=?"); defer { sqlite3_finalize(q) }; bind(path, at:1,to:q)
        return try row(q) ? String(cString: sqlite3_column_text(q,0)) : nil
    }
    func paths() throws -> [String] { let q = try statement("SELECT path FROM files"); defer { sqlite3_finalize(q) }; var result:[String]=[]; while try row(q) { result.append(String(cString:sqlite3_column_text(q,0))) }; return result }
    func remove(_ path: String) throws {
        for sql in ["DELETE FROM chunks WHERE path=?", "DELETE FROM files WHERE path=?"] { let q=try statement(sql); defer { sqlite3_finalize(q) };bind(path,at:1,to:q);try done(q) }
    }
    func replace(path: String, digest: String, chunks: [(Int?,Int,String)]) throws {
        try exec("BEGIN IMMEDIATE"); var committed=false;defer { if !committed { try? exec("ROLLBACK") } }
        try remove(path)
        let file=try statement("INSERT INTO files VALUES(?,?)");defer {sqlite3_finalize(file)};bind(path,at:1,to:file);bind(digest,at:2,to:file);try done(file)
        let q=try statement("INSERT INTO chunks VALUES(?,?,?,?,?)");defer {sqlite3_finalize(q)}
        for (page,part,text) in chunks {
            sqlite3_reset(q);sqlite3_clear_bindings(q);bind(path,at:1,to:q)
            if let page {sqlite3_bind_int(q,2,Int32(page))}else{sqlite3_bind_null(q,2)}
            sqlite3_bind_int(q,3,Int32(part));bind(text,at:4,to:q);bind(text.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:.current),at:5,to:q);try done(q)
        }
        try exec("COMMIT");committed=true
    }
    func search(_ query: String) throws -> [DocumentHit] {
        let q=try statement("SELECT path,page,part,text FROM chunks WHERE instr(folded,?)>0 ORDER BY path,part LIMIT 100");defer{sqlite3_finalize(q)}
        bind(query.folding(options:[.caseInsensitive,.diacriticInsensitive],locale:.current),at:1,to:q)
        var result:[DocumentHit]=[]
        while try row(q) { result.append(.init(path:String(cString:sqlite3_column_text(q,0)),page:sqlite3_column_type(q,1)==SQLITE_NULL ? nil : Int(sqlite3_column_int(q,1)),fragment:Int(sqlite3_column_int(q,2)),text:String(cString:sqlite3_column_text(q,3)))) }
        return result
    }
}
