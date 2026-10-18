import Foundation
import OSLog

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
    func prepare() throws {
        for url in [root, attachments, backups, documentation, workflows] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }
}
final class StateStorage {
    let paths: AppStoragePaths
    init(paths: AppStoragePaths = .init()) { self.paths = paths }
    func load() throws -> PersistedState? {
        try paths.prepare()
        guard FileManager.default.fileExists(atPath: paths.state.path) else { return nil }
        let state = try JSONDecoder().decode(PersistedState.self, from: Data(contentsOf: paths.state))
        guard state.version == 1 else { throw AgentError.message("Неподдерживаемая версия данных \(state.version). Исходный файл сохранён.") }
        return state
    }
    func save(_ state: PersistedState) throws {
        try paths.prepare()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        if FileManager.default.fileExists(atPath: paths.state.path) {
            let previous = paths.root.appendingPathComponent("state.previous.json")
            try Data(contentsOf: paths.state).write(to: previous, options: [.atomic, .completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previous.path)
        }
        try data.write(to: paths.state, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.state.path)
    }
}
