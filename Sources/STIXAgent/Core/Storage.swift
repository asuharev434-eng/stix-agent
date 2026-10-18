import Foundation
import OSLog
import Darwin

struct AppStoragePaths {
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("STIX Agent", isDirectory: true)
    }
    var state: URL { root.appendingPathComponent("state.json") }
    var attachments: URL { root.appendingPathComponent("Attachments", isDirectory: true) }
    var backups: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    var documentation: URL { root.appendingPathComponent("Documentation", isDirectory: true) }
    var workflows: URL { root.appendingPathComponent("Workflows", isDirectory: true) }
    var skills: URL { root.appendingPathComponent("Skills", isDirectory: true) }
    func chatAttachments(_ id: UUID) -> URL { root.appendingPathComponent("Chats/" + id.uuidString + "/Attachments", isDirectory: true) }
    func prepare() throws {
        for url in [root, attachments, backups, documentation, workflows, skills] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}
final class StateStorage {
    let paths: AppStoragePaths
    private let transactionFault: ((String) throws -> Void)?
    private let mutex = NSLock()
    private var fingerprints: [String: String]?
    init(paths: AppStoragePaths = .init(), transactionFault: ((String) throws -> Void)? = nil) {
        self.paths = paths; self.transactionFault = transactionFault
    }
    private func locked<T>(_ operation: () throws -> T) throws -> T {
        mutex.lock(); defer { mutex.unlock() }
        try paths.prepare()
        let lockURL = try StoreFiles.url(".store.lock", root: paths.root)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw AgentError.message("Не удалось открыть блокировку хранилища") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw AgentError.message("Не удалось заблокировать хранилище") }
        defer { flock(fd, LOCK_UN) }
        try recover()
        return try operation()
    }
    func createBackup(in directory: URL, automatic: Bool) throws -> BackupRecord {
        try locked {
            let state = try SplitStore.load(root: paths.root)
            return try LocalBackups.create(paths: paths, state: state, in: directory, automatic: automatic)
        }
    }
    func load() throws -> PersistedState? {
        try LocalBackups.recoverRestore(paths: paths)
        return try locked {
            if FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("store.json").path) {
                let state = try SplitStore.load(root: paths.root)
                fingerprints = try currentFingerprints(state)
                return state
            }
            guard FileManager.default.fileExists(atPath: paths.state.path) else { return nil }
            let bytes = try StoreFiles.read("state.json", root: paths.root)
            let state = try JSONDecoder().decode(PersistedState.self, from: bytes)
            guard state.version == 1 else { throw AgentError.message("Неподдерживаемый формат. Исходные данные сохранены.") }
            guard try Self.containsOnlyKnownFields(JSONSerialization.jsonObject(with: bytes), JSONSerialization.jsonObject(with: StoreFiles.encode(state))) else { throw AgentError.message("В прежней базе есть неизвестные поля. Миграция остановлена без изменения исходника") }
            let archive = "Backups/Migrations/" + UUID().uuidString
            try StoreFiles.write(bytes, relative: archive + "/state.json", root: paths.root)
            if FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("state.previous.json").path) {
                try StoreFiles.write(StoreFiles.read("state.previous.json", root: paths.root), relative: archive + "/state.previous.json", root: paths.root)
            }
            guard try StoreFiles.read(archive + "/state.json", root: paths.root) == bytes else { throw AgentError.message("Резервная копия миграции не совпала") }
            try archiveAttachments(MemoryDocuments.normalize(state))
            let normalized = try commit(state)
            let report: [String: String] = ["sourceSHA256": StoreFiles.digest(bytes), "chats": String(state.chats.count), "messages": String(state.chats.reduce(0) { $0 + $1.messages.count }), "history": String(state.chats.reduce(0) { $0 + $1.history.count }), "result": "verified-roundtrip"]
            try StoreFiles.write(StoreFiles.encode(report), relative: archive + "/migration.json", root: paths.root)
            return normalized
        }
    }
    func save(_ state: PersistedState) throws {
        try locked {
            if !FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("store.json").path), FileManager.default.fileExists(atPath: paths.state.path) { throw AgentError.message("Сначала прочитайте и перенесите прежнее хранилище через load; исходные данные не изменены") }
            if let fingerprints {
                for (path,digest) in fingerprints {
                    let actual = digest == "absent" && !FileManager.default.fileExists(atPath: paths.root.appendingPathComponent(path).path) ? "absent" : try StoreFiles.digest(StoreFiles.read(path, root: paths.root))
                    guard actual == digest else {
                        throw AgentError.message("Файлы хранилища изменены вне приложения. Изменения сохранены; перезапустите приложение для перечитывания")
                    }
                }
            } else if FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("store.json").path) { _ = try SplitStore.load(root: paths.root) }
            _ = try commit(state)
        }
    }
    private static func containsOnlyKnownFields(_ original: Any, _ decoded: Any) -> Bool {
        if original is NSNull { return true }
        if let source = original as? [String:Any], let target = decoded as? [String:Any] {
            return source.allSatisfy { key,value in value is NSNull || target[key].map { containsOnlyKnownFields(value,$0) } == true }
        }
        if let source = original as? [Any], let target = decoded as? [Any] {
            return source.count == target.count && zip(source,target).allSatisfy { containsOnlyKnownFields($0,$1) }
        }
        // Decoding validates scalar types; UUID casing and Set ordering may normalize.
        // Typed staged round-trip and the raw backup independently preserve values.
        return !(original is [String:Any]) && !(original is [Any])
    }
    private func currentFingerprints(_ state: PersistedState) throws -> [String:String] {
        let (_,files) = try SplitStore.files(state)
        return try Dictionary(uniqueKeysWithValues: files.keys.map { path in
            if ["Memory/history.jsonl", "Features/config.json"].contains(path), !FileManager.default.fileExists(atPath: paths.root.appendingPathComponent(path).path) { return (path, "absent") }
            return (path, try StoreFiles.digest(StoreFiles.read(path, root: paths.root)))
        })
    }
    private func commit(_ input: PersistedState) throws -> PersistedState {
        let (normalized, encoded) = try SplitStore.files(input)
        let id = UUID(), stage = ".Transactions/" + id.uuidString
        let stageRoot = try StoreFiles.url(stage + "/Files", root: paths.root)
        try FileManager.default.createDirectory(at: stageRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var files = encoded
        if FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("store.json").path) { files["state.previous.json"] = try StoreFiles.read("store.json", root: paths.root) }
        var journalPublished = false
        do {
            for (path,data) in files {
                guard StoreFiles.allowedTransactionPath(path) else { throw AgentError.message("Неизвестный путь транзакции") }
                try StoreFiles.write(data, relative: path, root: stageRoot)
            }
            let roundtrip = try SplitStore.load(root: stageRoot)
            guard try StoreFiles.encode(roundtrip) == StoreFiles.encode(normalized) else { throw AgentError.message("Проверка сохранности данных не прошла; исходные файлы не изменены") }
            let tx = StoreTransaction(id: id, files: files.mapValues(StoreFiles.digest))
            try StoreFiles.write(StoreFiles.encode(tx), relative: "pending.json", root: paths.root)
            journalPublished = true
            try apply(tx, fault: transactionFault)
            fingerprints = tx.files.filter { $0.key != "state.previous.json" }
            return normalized
        } catch {
            if !journalPublished { try? FileManager.default.removeItem(at: paths.root.appendingPathComponent(stage)) }
            throw error
        }
    }
    private func recover() throws {
        guard FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("pending.json").path) else { return }
        let tx = try JSONDecoder().decode(StoreTransaction.self, from: StoreFiles.read("pending.json", root: paths.root))
        try apply(tx, fault: nil)
    }
    private func apply(_ tx: StoreTransaction, fault: ((String) throws -> Void)?) throws {
        guard tx.files["store.json"] != nil, !tx.files.isEmpty else { throw AgentError.message("Неполная транзакция") }
        let stageRoot = try StoreFiles.url(".Transactions/" + tx.id.uuidString + "/Files", root: paths.root)
        for (path,digest) in tx.files {
            guard StoreFiles.allowedTransactionPath(path), try StoreFiles.digest(StoreFiles.read(path, root: stageRoot)) == digest else { throw AgentError.message("Повреждена транзакция; запись остановлена") }
            _ = try StoreFiles.url(path, root: paths.root)
        }
        let pathsToApply = tx.files.keys.sorted { lhs,rhs in lhs == "store.json" ? false : rhs == "store.json" ? true : lhs < rhs }
        for (index,path) in pathsToApply.enumerated() {
            let data = try StoreFiles.read(path, root: stageRoot)
            if (try? StoreFiles.read(path, root: paths.root)) != data { try StoreFiles.write(data, relative: path, root: paths.root) }
            if index == 0 { try fault?("after-first-file") }
        }
        _ = try SplitStore.load(root: paths.root)
        try FileManager.default.removeItem(at: StoreFiles.url("pending.json", root: paths.root))
        try? FileManager.default.removeItem(at: paths.root.appendingPathComponent(".Transactions/" + tx.id.uuidString))
    }
    private func archiveAttachments(_ state: PersistedState) throws {
        for chat in state.chats {
            let destination = try StoreFiles.url("Chats/" + chat.id.uuidString + "/Attachments", root: paths.root)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var references: [[String: String]] = []
            for item in chat.messages.flatMap(\.attachments) + (chat.draftAttachments ?? []) {
                let source = URL(fileURLWithPath: item.path).standardizedFileURL
                let managed = paths.attachments.standardizedFileURL.path + "/"
                let canonicalManaged = paths.attachments.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                guard source.path.hasPrefix(managed), source.resolvingSymlinksInPath().path.hasPrefix(canonicalManaged), (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                let data = try Data(contentsOf: source)
                let name = item.id.uuidString + "-" + source.lastPathComponent
                let relative = "Chats/" + chat.id.uuidString + "/Attachments/" + name
                try StoreFiles.write(data, relative: relative, root: paths.root)
                guard try StoreFiles.read(relative, root: paths.root) == data else { throw AgentError.message("Копия вложения не совпала") }
                references.append(["original": item.path, "copy": relative, "sha256": StoreFiles.digest(data)])
            }
            try StoreFiles.write(StoreFiles.encode(references), relative: "Chats/" + chat.id.uuidString + "/Attachments/references.json", root: paths.root)
        }
    }
}
