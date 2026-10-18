import Foundation

struct LocalSkill: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let description: String
    let path: String
    var enabled: Bool
}

/// Skills are plain local folders. Metadata is cheap; bodies are read only on use.
struct SkillLibrary {
    let root: URL
    init(paths: AppStoragePaths) { root = paths.skills }
    static func validName(_ name: String) -> Bool {
        name.range(of: #"^[a-z0-9][a-z0-9-]{0,62}$"#, options: .regularExpression) != nil
    }
    static func metadata(_ content: String) throws -> (String, String) {
        guard content.utf8.count <= 128_000, !content.contains("\0") else { throw AgentError.message("SKILL.md: максимум 128 КБ, текст UTF-8") }
        let lines = content.components(separatedBy: .newlines)
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---"), end < 80 else { throw AgentError.message("SKILL.md должен начинаться YAML-блоком name и description между ---") }
        var fields: [String: String] = [:]
        var multiline: String?
        for line in lines[1..<end] {
            if let key = multiline, line.hasPrefix(" ") || line.hasPrefix("\t") {
                fields[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces); continue
            }
            multiline = nil
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = String(line[..<colon]), value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if [">", "|", ">-", "|-"].contains(value) { fields[key] = ""; multiline = key }
            else if value.count >= 2, (value.first == "\"" && value.last == "\"" || value.first == "'" && value.last == "'") { fields[key] = String(value.dropFirst().dropLast()) }
            else { fields[key] = value }
        }
        let name = fields["name"] ?? "", description = (fields["description"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard validName(name), !description.isEmpty, description.count <= 1000, !lines.dropFirst(end + 1).joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AgentError.message("Скилл: имя a-z/0-9/дефис до 63 символов, description до 1000 символов и непустое тело") }
        return (name, description)
    }
    func directory(_ name: String) throws -> URL {
        guard Self.validName(name) else { throw AgentError.message("Недопустимое имя скилла") }
        let directory = root.appendingPathComponent(name, isDirectory: true)
        guard directory.resolvingSymlinksInPath().path == directory.standardizedFileURL.path else { throw AgentError.message("Папка скилла не должна быть символической ссылкой") }
        return directory
    }
    func read(_ name: String) throws -> String {
        let file = try directory(name).appendingPathComponent("SKILL.md")
        guard file.resolvingSymlinksInPath().path == file.path else { throw AgentError.message("SKILL.md не должен быть символической ссылкой") }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 128_000 else { throw AgentError.message("Слишком большой SKILL.md") }
        let content = try String(contentsOf: file, encoding: .utf8)
        let (parsed, _) = try Self.metadata(content)
        guard parsed == name else { throw AgentError.message("Имя папки и name в SKILL.md должны совпадать") }
        return content
    }
    func workflow(_ name:String)throws->LocalWorkflow {
        _ = try read(name)
        let file=try StoreFiles.url("form.json",root:directory(name))
        guard (try file.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? Int.max)<=128000 else{throw AgentError.message("Форма скилла превышает 128 КБ")}
        var workflow=try LocalWorkflow.parse(String(contentsOf:file,encoding:.utf8))
        workflow.skill=name;try workflow.validated();return workflow
    }
    @discardableResult func save(name: String, content: String) throws -> URL {
        let (parsed, _) = try Self.metadata(content)
        guard parsed == name else { throw AgentError.message("Имя скилла не совпадает с name") }
        let directory = try directory(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = directory.appendingPathComponent("SKILL.md")
        guard file.resolvingSymlinksInPath().path == file.path else { throw AgentError.message("SKILL.md: символическая ссылка запрещена") }
        if FileManager.default.fileExists(atPath: file.path) {
            let revisions = directory.appendingPathComponent(".revisions", isDirectory: true)
            guard revisions.resolvingSymlinksInPath().path == revisions.path else { throw AgentError.message("Недопустимый каталог версий") }
            try FileManager.default.createDirectory(at: revisions, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try Data(contentsOf: file).write(to: revisions.appendingPathComponent(UUID().uuidString + ".md"), options: .atomic)
        }
        try Data(content.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return directory
    }
    func seed() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent("skill-creator").path),
              let resources = Bundle.module.url(forResource: "Resources", withExtension: nil) else { return }
        let file = resources.appendingPathComponent("Skills/skill-creator/SKILL.md")
        try save(name: "skill-creator", content: String(contentsOf: file, encoding: .utf8))
    }
    func importFolder(_ source: URL) throws -> URL {
        guard source.path.hasPrefix("/"), try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw AgentError.message("Выберите обычную локальную папку скилла") }
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let entry = source.appendingPathComponent("SKILL.md")
        guard entry.resolvingSymlinksInPath() == entry, (try entry.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 128_000 else { throw AgentError.message("Нет допустимого SKILL.md") }
        let content = try String(contentsOf: entry, encoding: .utf8), (name, _) = try Self.metadata(content)
        let destination = try directory(name)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw AgentError.message("Скилл \(name) уже существует. Обновите его через save, чтобы сохранить версию.") }
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { throw AgentError.message("Не удалось прочитать папку") }
        var files: [URL] = [], bytes = 0
        for case let file as URL in enumerator {
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey, .fileSizeKey])
            guard values.isSymbolicLink != true, values.isRegularFile == true || values.isDirectory == true else { throw AgentError.message("Скилл содержит ссылку или специальный файл") }
            bytes += values.fileSize ?? 0; files.append(file)
            guard files.count <= 200, bytes <= 20_000_000 else { throw AgentError.message("Импорт: до 200 файлов и 20 МБ") }
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            for file in files {
                let relative = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents.dropFirst(source.pathComponents.count).joined(separator: "/"), target = destination.appendingPathComponent(relative)
                let values = try file.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory == true { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
                else { try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true); try FileManager.default.copyItem(at: file, to: target); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path) }
            }
            _ = try read(name)
        } catch { try? FileManager.default.removeItem(at: destination); throw error }
        return destination
    }
    func list(disabled: Set<String>) throws -> [LocalSkill] {
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { folder in
            let name = folder.lastPathComponent
            guard Self.validName(name), let content = try? read(name), let (_, description) = try? Self.metadata(content) else { return nil }
            return .init(name: name, description: description, path: folder.path, enabled: !disabled.contains(name))
        }
    }
}
