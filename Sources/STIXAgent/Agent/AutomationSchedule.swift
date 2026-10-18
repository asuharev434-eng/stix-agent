import Foundation
import Darwin

struct AutomationEvent: Codable, Identifiable {
    var id: String
    var ruleID: UUID
    var chatID: UUID
    var prompt: String
    var path: String?
    var createdAt: Date
}
struct AutomationRun: Codable, Identifiable { var id: String; var ruleID: UUID; var createdAt: Date; var status: String; var detail: String }
private struct AutomationCursor: Codable { var daily: [String:String] = [:]; var folders: [String:[String:String]] = [:] }

enum AutomationSchedule {
    static func dailyEvent(_ rule: LocalAutomation, now: Date, lastEvent: String?) -> String? {
        guard rule.enabled, rule.trigger == .daily, let zone = TimeZone(identifier: rule.timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let day = calendar.startOfDay(for: now)
        guard let due = calendar.date(bySettingHour: rule.hour, minute: rule.minute, second: 0, of: day), now >= due, due >= rule.createdAt else { return nil }
        let key = rule.id.uuidString + ":" + String(Int(due.timeIntervalSince1970))
        return key == lastEvent ? nil : key
    }
}

/// A separate inbox avoids concurrent writes into the app's canonical chat store.
/// Both the in-app timer and launchd helper use the same process lock.
enum AutomationScheduler {
    static func tick(paths: AppStoragePaths, rules: [LocalAutomation], now: Date = Date()) throws {
        try paths.prepare()
        let root = try StoreFiles.url("Automation", root: paths.root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let lock = open(try StoreFiles.url("Automation/.lock", root: paths.root).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw AgentError.message("Нет доступа к журналу автоматизаций") }
        defer { close(lock) }; guard flock(lock, LOCK_EX) == 0 else { throw AgentError.message("Журнал автоматизаций занят") }; defer { flock(lock, LOCK_UN) }
        var cursor = FileManager.default.fileExists(atPath: root.appendingPathComponent("cursor.json").path) ? try JSONDecoder().decode(AutomationCursor.self, from: StoreFiles.read("cursor.json", root: root)) : AutomationCursor()
        for rule in rules where rule.enabled {
            try rule.validated(); let key = rule.id.uuidString
            if rule.trigger == .daily {
                if let event = AutomationSchedule.dailyEvent(rule, now: now, lastEvent: cursor.daily[key]) {
                    try emit(rule, key: event, path: nil, now: now, root: root); cursor.daily[key] = event
                }
            } else if let folder = rule.folder {
                let url = try FileTools(paths: paths).resolve(folder, workingDirectory: nil)
                let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey], options: [.skipsHiddenFiles])
                guard items.count <= 2000 else { throw AgentError.message("Папка наблюдения содержит более 2000 объектов") }
                var current: [String:String] = [:]
                for item in items where rule.fileExtension == nil || item.pathExtension.lowercased() == rule.fileExtension?.lowercased() {
                    let info = try item.resourceValues(forKeys: [.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey,.contentModificationDateKey])
                    guard info.isRegularFile == true, info.isSymbolicLink != true else { continue }
                    // Wait for a quiet file; metadata signatures avoid reading private file contents.
                    guard let modified = info.contentModificationDate, now.timeIntervalSince(modified) >= 3 else { continue }
                    let signature = "\(info.fileSize ?? 0):\(modified.timeIntervalSince1970)"
                    current[item.path] = signature
                    if let previous = cursor.folders[key], previous[item.path] != signature {
                        try emit(rule, key: key + ":" + item.path + ":" + signature, path: item.path, now: now, root: root)
                    }
                }
                cursor.folders[key] = current
            }
        }
        try StoreFiles.write(StoreFiles.encode(cursor), relative: "cursor.json", root: root)
    }
    private static func emit(_ rule: LocalAutomation, key: String, path: String?, now: Date, root: URL) throws {
        let id = StoreFiles.digest(Data(key.utf8))
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("Acknowledged/\(id).json").path) { return }
        let event = AutomationEvent(id: id, ruleID: rule.id, chatID: rule.chatID, prompt: rule.prompt, path: path, createdAt: now)
        try StoreFiles.write(StoreFiles.encode(event), relative: "Inbox/\(id).json", root: root)
    }
    static func pending(paths: AppStoragePaths) throws -> [AutomationEvent] {
        let root = try StoreFiles.url("Automation/Inbox", root: paths.root)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        guard files.count <= 500 else { throw AgentError.message("В очереди автоматизаций более 500 событий; остановите правила и разберите очередь") }
        return try files.map { try JSONDecoder().decode(AutomationEvent.self, from: StoreFiles.read($0.lastPathComponent, root: root)) }.sorted { $0.createdAt < $1.createdAt }
    }
    static func acknowledge(_ event: AutomationEvent, status: String, paths: AppStoragePaths) throws {
        let root = try StoreFiles.url("Automation", root: paths.root)
        let record = AutomationRun(id: event.id, ruleID: event.ruleID, createdAt: event.createdAt, status: status, detail: event.path ?? "По расписанию")
        try StoreFiles.write(StoreFiles.encode(record), relative: "Acknowledged/\(event.id).json", root: root)
        let inbox = try StoreFiles.url("Inbox/\(event.id).json", root: root)
        if FileManager.default.fileExists(atPath: inbox.path) { try FileManager.default.removeItem(at: inbox) }
    }
    static func history(paths: AppStoragePaths) throws -> [AutomationRun] {
        let root = try StoreFiles.url("Automation/Acknowledged", root: paths.root)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.suffix(500).map { try JSONDecoder().decode(AutomationRun.self, from: StoreFiles.read($0.lastPathComponent, root: root)) }.sorted { $0.createdAt > $1.createdAt }
    }
}
