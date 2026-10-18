import Foundation
import CryptoKit
import Darwin

struct FileTools {
    let paths: AppStoragePaths
    private let fm = FileManager.default
    private let maximumBytes = 1_048_576

    func resolve(_ path: String, workingDirectory: String?) throws -> URL {
        guard !path.isEmpty, !path.contains("\0") else { throw AgentError.message("Некорректный путь") }
        let expanded = (path as NSString).expandingTildeInPath
        let base = workingDirectory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? URL(fileURLWithPath: fm.currentDirectoryPath)
        let url = try canonicalURL(expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : base.appendingPathComponent(expanded))
        let root = try canonicalURL(paths.root).path
        let allowed = try [paths.documentation, paths.attachments].contains { subtree in
            let allowedRoot = try canonicalURL(subtree).path
            let expectedRoot = URL(fileURLWithPath: root).appendingPathComponent(subtree.lastPathComponent).path
            return allowedRoot == expectedRoot && (url.path == allowedRoot || url.path.hasPrefix(allowedRoot + "/"))
        }
        guard allowed || (url.path != root && !url.path.hasPrefix(root + "/")) else { throw AgentError.message("Доступ к внутренним данным приложения запрещён") }
        return url
    }
    /// Walk components ourselves: Foundation may leave symlinks unresolved when a leaf is absent.
    private func canonicalURL(_ input: URL, depth: Int = 0) throws -> URL {
        guard depth < 40 else { throw AgentError.message("Слишком много символических ссылок") }
        let components = input.pathComponents
        var result = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst() {
            if component == "." { continue }
            if component == ".." { result.deleteLastPathComponent(); continue }
            result.appendPathComponent(component)
            if let destination = try? fm.destinationOfSymbolicLink(atPath: result.path) {
                let linkTarget = destination.hasPrefix("/") ? URL(fileURLWithPath: destination) : result.deletingLastPathComponent().appendingPathComponent(destination)
                result = try canonicalURL(linkTarget, depth: depth + 1)
            } else if let attributes = try? fm.attributesOfItem(atPath: result.path), attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw AgentError.message("Не удалось разрешить символическую ссылку")
            }
        }
        return result
    }
    func list(path: String, workingDirectory: String?) throws -> String {
        let url = try resolve(path, workingDirectory: workingDirectory)
        let entries = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]).sorted { $0.lastPathComponent < $1.lastPathComponent }
        let lines = entries.prefix(500).map { entry in
            entry.lastPathComponent + (((try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) ? "/" : "")
        }
        return bounded(lines.joined(separator: "\n") + (entries.count > 500 ? "\n[Показаны первые 500 записей]" : ""))
    }
    func read(path: String, workingDirectory: String?, offset: Int = 0, limit: Int = 30_000) throws -> String {
        guard offset >= 0, limit > 0 else { throw AgentError.message("Некорректный диапазон чтения") }
        let url = try resolve(path, workingDirectory: workingDirectory)
        let data = try smallData(url)
        guard let text = String(data: data, encoding: .utf8) else { throw AgentError.message("Файл не является текстом UTF-8") }
        return String(text.dropFirst(offset).prefix(min(limit, 30_000)))
    }
    func search(path: String, query: String, workingDirectory: String?) throws -> String {
        guard !query.isEmpty else { throw AgentError.message("Поисковый запрос пуст") }
        let root = try resolve(path, workingDirectory: workingDirectory)
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &directory) else { throw AgentError.message("Путь не найден") }
        let candidates: [URL]
        if directory.boolValue {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { throw AgentError.message("Не удалось прочитать каталог") }
            var files: [URL] = []
            while let url = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                if files.count >= 10_000 { break }
                if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { files.append(url) }
            }
            candidates = files
        } else { candidates = [root] }
        var output = ""
        var scannedBytes = 0
        for candidate in candidates {
            try Task.checkCancellation()
            guard let safe = try? resolve(candidate.path, workingDirectory: nil), let data = try? smallData(safe), let text = String(data: data, encoding: .utf8) else { continue }
            scannedBytes += data.count
            guard scannedBytes <= 33_554_432 else { return bounded(output + "\n[Достигнут предел поиска 32 МБ]") }
            for (index, line) in text.components(separatedBy: .newlines).enumerated() where line.localizedCaseInsensitiveContains(query) {
                output += "\(candidate.path):\(index + 1): \(line)\n"
                if output.count >= 30_000 { return bounded(output) }
            }
        }
        return output.isEmpty ? "Совпадений нет" : output
    }
    func write(path: String, content: String, workingDirectory: String?) throws -> UndoRecord {
        let url = try resolve(path, workingDirectory: workingDirectory)
        var backup: String?
        if fm.fileExists(atPath: url.path) {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw AgentError.message("Запись разрешена только в обычный файл") }
            backup = try backupItem(url).path
        }
        let data = Data(content.utf8)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Resolve once more after directory creation to catch an unexpected protected target.
        _ = try resolve(url.path, workingDirectory: nil)
        try data.write(to: url, options: .atomic)
        return UndoRecord(kind: "write", source: url.path, backup: backup, expectedDigest: try digest(url))
    }
    func move(source: String, destination: String, workingDirectory: String?) throws -> UndoRecord {
        let from = try resolve(source, workingDirectory: workingDirectory)
        let to = try resolve(destination, workingDirectory: workingDirectory)
        try requireMutableTree(from)
        guard !fm.fileExists(atPath: to.path) else { throw AgentError.message("Назначение уже существует") }
        let hash = try digest(from)
        try fm.moveItem(at: from, to: to)
        return UndoRecord(kind: "move", source: from.path, destination: to.path, expectedDigest: hash)
    }
    func trash(path: String, workingDirectory: String?) throws -> UndoRecord {
        let url = try resolve(path, workingDirectory: workingDirectory)
        try requireMutableTree(url)
        let hash = try digest(url)
        let backup = try backupItem(url)
        var trashed: NSURL?
        try fm.trashItem(at: url, resultingItemURL: &trashed)
        return UndoRecord(kind: "trash", source: url.path, destination: trashed?.path, backup: backup.path, expectedDigest: hash)
    }
    func undo(_ record: UndoRecord) throws -> String {
        let source = try resolve(record.source, workingDirectory: nil)
        guard source.path == URL(fileURLWithPath: record.source).path else { throw AgentError.message("Конфликт отмены: путь заменён символической ссылкой") }
        switch record.kind {
        case "write":
            try verify(source, expected: record.expectedDigest)
            if let backup = record.backup {
                let saved = try checkedBackup(backup)
                let temporary = source.deletingLastPathComponent().appendingPathComponent(".stix-restore-" + UUID().uuidString)
                defer { try? fm.removeItem(at: temporary) }
                try fm.copyItem(at: saved, to: temporary)
                try verify(source, expected: record.expectedDigest)
                guard rename(temporary.path, source.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            } else { try fm.removeItem(at: source) }
        case "move":
            guard let destination = record.destination, !fm.fileExists(atPath: source.path) else { throw AgentError.message("Конфликт отмены: исходный путь занят") }
            let target = try resolve(destination, workingDirectory: nil)
            guard target.path == URL(fileURLWithPath: destination).path else { throw AgentError.message("Конфликт отмены: путь заменён символической ссылкой") }
            try verify(target, expected: record.expectedDigest)
            try fm.moveItem(at: target, to: source)
        case "trash":
            guard !fm.fileExists(atPath: source.path), let backup = record.backup else { throw AgentError.message("Конфликт отмены: исходный путь занят") }
            let saved = try checkedBackup(backup)
            try verify(saved, expected: record.expectedDigest)
            try fm.copyItem(at: saved, to: source)
            // Restore succeeds from the immutable backup even when Trash was emptied.
            // Only clean up the matching Trash item, never an externally changed entry.
            if let destination = record.destination {
                let trashURL = URL(fileURLWithPath: destination).standardizedFileURL
                let trashRoot = fm.urls(for: .trashDirectory, in: .userDomainMask).first?.standardizedFileURL.path
                if let trashRoot, trashURL.path.hasPrefix(trashRoot + "/"),
                   (try? digest(trashURL)) == record.expectedDigest {
                    try? fm.removeItem(at: trashURL)
                }
            }
        default: throw AgentError.message("Неизвестная операция отмены")
        }
        return "Операция отменена: \(source.path)"
    }
    private func requireMutableTree(_ url: URL) throws {
        let internalRoot = try canonicalURL(paths.root).path
        guard !internalRoot.hasPrefix(url.path + "/"), url.path != "/" else { throw AgentError.message("Нельзя перемещать каталог, содержащий внутренние данные приложения") }
    }
    private func checkedBackup(_ path: String) throws -> URL {
        let url = try canonicalURL(URL(fileURLWithPath: path))
        let root = try canonicalURL(paths.backups).path
        guard url.path.hasPrefix(root + "/"), fm.fileExists(atPath: url.path) else { throw AgentError.message("Резервная копия недоступна") }
        return url
    }
    private func backupItem(_ url: URL) throws -> URL {
        try paths.prepare()
        let backup = paths.backups.appendingPathComponent(UUID().uuidString)
        try fm.copyItem(at: url, to: backup)
        return backup
    }
    private func verify(_ url: URL, expected: String?) throws {
        guard let expected, try digest(url) == expected else { throw AgentError.message("Конфликт отмены: файл изменён другой программой") }
    }
    private func digest(_ url: URL) throws -> String {
        var hash = SHA256()
        var count = 0
        var totalBytes = 0
        func visit(_ item: URL, relative: String) throws {
            try Task.checkCancellation()
            count += 1
            guard count <= 10_000 else { throw AgentError.message("Каталог содержит более 10000 объектов") }
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw AgentError.message("Операция с каталогом, содержащим символические ссылки, запрещена") }
            let kind: String
            if values.isDirectory == true { kind = "directory" }
            else if values.isRegularFile == true { kind = "file" }
            else { throw AgentError.message("Операция поддерживает только обычные файлы и каталоги") }
            let entry = Data("\(kind):\(relative.utf8.count):\(relative)\n".utf8)
            hash.update(data: entry)
            if kind == "directory" {
                for child in try fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try visit(child, relative: relative + "/" + child.lastPathComponent)
                }
            } else {
                let handle = try FileHandle(forReadingFrom: item); defer { try? handle.close() }
                var contentHash = SHA256()
                while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
                    try Task.checkCancellation()
                    totalBytes += chunk.count
                    guard totalBytes <= 536_870_912 else { throw AgentError.message("Общий размер операции превышает 512 МБ") }
                    contentHash.update(data: chunk)
                }
                hash.update(data: Data(contentHash.finalize()))
            }
        }
        try visit(url, relative: "")
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private func smallData(_ url: URL) throws -> Data {
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw AgentError.message("Чтение поддерживает только обычные файлы") }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count <= maximumBytes else { throw AgentError.message("Файл больше 1 МБ") }
        return data
    }
    private func bounded(_ string: String) -> String { String(string.prefix(30_000)) }
}
