import Foundation

/// Durable, immutable previews. Batch targets must be independent so every precondition
/// can be checked before the first filesystem mutation.
struct FileChangePlanner: Sendable {
    let paths: AppStoragePaths
    private static let lock = NSLock()
    private var fm: FileManager { .default }

    struct Preview: Sendable {
        let id: String
        let summary: String
        let attachment: Attachment
    }
    struct OperationResult: Sendable {
        let text: String
        let undo: UndoRecord?
    }
    struct ApplyResult: Sendable { let results: [OperationResult] }
    struct Recovery: Sendable {
        let planID: String
        let workingDirectory: String
        let status: String
        let receipts: [UndoRecord]
    }
    struct ApplyFailure: LocalizedError, Sendable {
        let planID: String
        let undoRecords: [UndoRecord]
        let errorDescription: String?
    }
    private struct Operation: Codable {
        let kind: String
        let source: String
        let destination: String?
        let content: String?
        let expectedDigest: String?
    }
    private struct Plan: Codable {
        let version: Int
        let id: String
        let workingDirectory: String
        let operations: [Operation]
        var status: String
        var receipts: [UndoRecord]
        var failure: String?
    }

    func preview(operations input: JSONValue, workingDirectory: String) throws -> Preview {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard let inputs = input.array, !inputs.isEmpty, inputs.count <= 100 else {
            throw AgentError.message("План должен содержать от 1 до 100 операций")
        }
        let tools = FileTools(paths: paths)
        let directory = try tools.resolve(workingDirectory, workingDirectory: nil).path
        var operations: [Operation] = []
        var touched: [String] = []
        var previews: [String] = []
        var bytes = 0
        for item in inputs {
            guard item.object != nil else { throw AgentError.message("Операция должна быть объектом JSON") }
            let kind = item["kind"].string ?? item["type"].string ?? item["operation"].string ?? ""
            guard ["write", "move", "trash"].contains(kind) else { throw AgentError.message("Неизвестная операция плана: \(kind)") }
            let source = try tools.resolve(try item.requiredString(kind == "move" ? "source" : "path"), workingDirectory: directory)
            let destination = kind == "move" ? try tools.resolve(try item.requiredString("destination"), workingDirectory: directory) : nil
            for target in [source, destination].compactMap({ $0 }) {
                guard !touched.contains(where: { overlaps($0, target.path) }) else {
                    throw AgentError.message("Цели операций пересекаются: \(target.path). Разделите зависимые изменения на отдельные планы.")
                }
                touched.append(target.path)
            }
            let exists = fm.fileExists(atPath: source.path)
            if kind != "write" {
                guard exists else { throw AgentError.message("Исходный путь не найден: \(source.path)") }
                let internalRoot = paths.root.resolvingSymlinksInPath().standardizedFileURL.path
                guard source.path != "/", !internalRoot.hasPrefix(source.path + "/") else {
                    throw AgentError.message("Нельзя перемещать каталог, содержащий внутренние данные приложения")
                }
            }
            if let destination {
                guard !fm.fileExists(atPath: destination.path) else { throw AgentError.message("Назначение уже существует: \(destination.path)") }
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: destination.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    throw AgentError.message("Родительский каталог назначения не найден")
                }
            }
            let digest = exists ? try tools.digest(source) : nil
            var content: String?
            if kind == "write" {
                guard let newContent = item["content"].string else { throw AgentError.message("Поле content должно содержать текст") }
                guard newContent.utf8.count <= 1_048_576 else { throw AgentError.message("Новый текст превышает 1 МБ") }
                let oldData: Data
                if exists {
                    guard try source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                        throw AgentError.message("Предпросмотр записи поддерживает только обычные файлы")
                    }
                    let handle = try FileHandle(forReadingFrom: source)
                    defer { try? handle.close() }
                    oldData = try handle.read(upToCount: 1_048_577) ?? Data()
                } else { oldData = Data() }
                guard oldData.count <= 1_048_576, let oldText = String(data: oldData, encoding: .utf8) else {
                    throw AgentError.message("Предпросмотр поддерживает текст UTF-8 до 1 МБ")
                }
                bytes += oldData.count + newContent.utf8.count
                guard bytes <= 8_388_608 else { throw AgentError.message("Общий размер предпросмотра превышает 8 МБ") }
                content = newContent
                previews.append("<section><h2>Запись: \(escape(source.path))</h2>" + diff(old: oldText, new: newContent) + "</section>")
            } else {
                previews.append("<section><h2>\(kind == "move" ? "Перемещение" : "В корзину")</h2><p>\(escape(source.path))\(destination.map { " → " + escape($0.path) } ?? "")</p></section>")
            }
            if let digest, try tools.digest(source) != digest { throw AgentError.message("Файл изменился во время предпросмотра; создайте план повторно") }
            operations.append(Operation(kind: kind, source: source.path, destination: destination?.path, content: content, expectedDigest: digest))
        }
        let id = UUID().uuidString.lowercased()
        let plan = Plan(version: 1, id: id, workingDirectory: directory, operations: operations, status: "preview", receipts: [])
        try save(plan)
        let html = """
        <!doctype html><html lang="ru"><meta charset="utf-8"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'"><meta name="viewport" content="width=device-width"><title>Предпросмотр изменений</title><style>body{font:15px system-ui;margin:32px;color:#e5e7eb;background:#111827}section{padding:16px;margin:16px 0;background:#1f2937;border-radius:12px}h2{font-size:16px;overflow-wrap:anywhere}pre{white-space:pre-wrap;overflow-wrap:anywhere;font:13px ui-monospace,monospace}.removed{background:#54252d}.added{background:#164333}.context{color:#9ca3af}p{overflow-wrap:anywhere}</style><h1>Предпросмотр изменений</h1><p>План \(id) · \(operations.count) операций. Изменения ещё не применены.</p>\(previews.joined())</html>
        """
        let artifact = paths.attachments.appendingPathComponent("file-plan-\(id).html")
        try Data(html.utf8).write(to: artifact, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: artifact.path)
        return Preview(id: id, summary: "План \(id): \(operations.count) операций. Изменения ещё не применены. Проверьте вложенный предпросмотр.", attachment: Attachment(path: artifact.path, kind: "html"))
    }

    func apply(id: String, workingDirectory: String) throws -> ApplyResult {
        Self.lock.lock(); defer { Self.lock.unlock() }
        guard UUID(uuidString: id) != nil else { throw AgentError.message("Некорректный идентификатор плана") }
        let url = planURL(id.lowercased())
        var plan = try load(id)
        guard plan.version == 1, plan.id == id.lowercased(), plan.status == "preview" else {
            throw AgentError.message("План уже запускался или имеет неподдерживаемую версию")
        }
        let tools = FileTools(paths: paths)
        guard try tools.resolve(workingDirectory, workingDirectory: nil).path == plan.workingDirectory else {
            throw AgentError.message("Рабочий каталог плана изменился")
        }
        for operation in plan.operations { try preflight(operation, tools: tools) }
        plan.status = "applying"
        try save(plan)
        var results: [OperationResult] = []
        do {
            for operation in plan.operations {
                try Task.checkCancellation()
                // Repeat per-operation checks to narrow the external-edit race window.
                try preflight(operation, tools: tools)
                let receipt: UndoRecord
                switch operation.kind {
                case "write": receipt = try tools.write(path: operation.source, content: operation.content!, workingDirectory: nil)
                case "move": receipt = try tools.move(source: operation.source, destination: operation.destination!, workingDirectory: nil)
                case "trash": receipt = try tools.trash(path: operation.source, workingDirectory: nil)
                default: throw AgentError.message("Повреждённая операция плана")
                }
                plan.receipts.append(receipt)
                try save(plan)
                results.append(OperationResult(text: "\(operation.kind): \(operation.source)\(operation.destination.map { " → " + $0 } ?? "")", undo: receipt))
            }
            plan.status = "applied"
            try save(plan)
            return ApplyResult(results: results)
        } catch {
            let originalError = error.localizedDescription
            var remaining: [UndoRecord] = []
            var rollbackErrors: [String] = []
            for receipt in plan.receipts.reversed() {
                do { _ = try tools.undo(receipt) }
                catch { remaining.append(receipt); rollbackErrors.append(error.localizedDescription) }
            }
            plan.receipts = remaining.reversed()
            plan.status = remaining.isEmpty ? "rolledBack" : "rollbackFailed"
            plan.failure = originalError + (rollbackErrors.isEmpty ? "" : "; " + rollbackErrors.joined(separator: "; "))
            try? save(plan)
            throw ApplyFailure(planID: id, undoRecords: plan.receipts,
                               errorDescription: "Не удалось применить план \(id): \(originalError). " + (remaining.isEmpty ? "Выполненные операции отменены." : "Не все операции удалось отменить. Квитанции сохранены в \(url.path): \(rollbackErrors.joined(separator: "; "))"))
        }
    }

    /// Only interrupted/failed batches are advertised automatically. Applied plans
    /// remain available for explicit rollback by ID, without resurrecting normal undo.
    func undoReceipts(id: String) throws -> [UndoRecord] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try load(id).receipts
    }

    func recoveries() throws -> [Recovery] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let directory = paths.backups.appendingPathComponent("plans", isDirectory: true)
        guard fm.fileExists(atPath: directory.path) else { return [] }
        guard let entries = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsSubdirectoryDescendants, .skipsHiddenFiles]) else {
            throw AgentError.message("Не удалось прочитать журнал планов")
        }
        var count = 0
        var seen = Set<UUID>()
        var recovered: [Recovery] = []
        for case let entry as URL in entries {
            count += 1
            guard count <= 1_000 else { throw AgentError.message("В журнале более 1000 планов; требуется архивирование старых записей") }
            guard entry.pathExtension == "json", UUID(uuidString: entry.deletingPathExtension().lastPathComponent) != nil else { continue }
            let plan = try load(entry.deletingPathExtension().lastPathComponent)
            guard ["applying", "rollbackFailed"].contains(plan.status) else { continue }
            let receipts = plan.receipts.filter { seen.insert($0.id).inserted }
            recovered.append(Recovery(planID: plan.id, workingDirectory: plan.workingDirectory, status: plan.status, receipts: receipts))
        }
        return recovered.sorted { $0.planID < $1.planID }
    }

    /// Each successful undo advances the durable journal. A second invocation can
    /// safely continue after a conflict, cancellation, or process interruption.
    func rollback(id: String) throws -> [String] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        var plan = try load(id)
        guard ["applying", "rollbackFailed", "applied"].contains(plan.status) else {
            throw AgentError.message("Этот план нельзя отменить: он ещё не запускался или уже отменён")
        }
        plan.status = "rollbackFailed"
        try save(plan)
        let tools = FileTools(paths: paths)
        var messages: [String] = []
        do {
            while let receipt = plan.receipts.last {
                try Task.checkCancellation()
                if try alreadyRestored(receipt, tools: tools) {
                    messages.append("Изменение уже отменено: \(receipt.source)")
                } else {
                    messages.append(try tools.undo(receipt))
                }
                plan.receipts.removeLast()
                try save(plan)
            }
            plan.status = "rolledBack"
            plan.failure = nil
            try save(plan)
            return messages
        } catch {
            plan.failure = error.localizedDescription
            try? save(plan)
            throw ApplyFailure(planID: plan.id, undoRecords: plan.receipts,
                               errorDescription: "Отмена плана \(plan.id) остановлена: \(error.localizedDescription). Оставшиеся квитанции сохранены; устраните конфликт и повторите отмену.")
        }
    }

    /// Undo one independent file from a batch, keeping the remaining receipts durable.
    /// A conflict leaves the journal intact, allowing retry without losing recovery data.
    func rollback(id: String, receiptID: UUID) throws -> String {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return try rollbackReceipt(in: load(id), receiptID: receiptID)
    }

    /// UI entry point for individual undo. Batch ownership is recovered from the
    /// durable journal, so callers need not persist a second receipt-to-plan index.
    func undo(_ receipt: UndoRecord) throws -> String {
        Self.lock.lock(); defer { Self.lock.unlock() }
        let directory = paths.backups.appendingPathComponent("plans", isDirectory: true)
        guard fm.fileExists(atPath: directory.path) else { return try FileTools(paths: paths).undo(receipt) }
        let entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard entries.count <= 1_000 else { throw AgentError.message("В журнале более 1000 планов; требуется архивирование старых записей") }
        var owner: Plan?
        for entry in entries where entry.pathExtension == "json" && UUID(uuidString: entry.deletingPathExtension().lastPathComponent) != nil {
            let plan = try load(entry.deletingPathExtension().lastPathComponent)
            guard let saved = plan.receipts.first(where: { $0.id == receipt.id }) else { continue }
            guard owner == nil, saved.kind == receipt.kind, saved.source == receipt.source,
                  saved.destination == receipt.destination, saved.backup == receipt.backup, saved.expectedDigest == receipt.expectedDigest else {
                throw AgentError.message("Квитанция отмены не совпадает с журналом плана")
            }
            owner = plan
        }
        if let owner { return try rollbackReceipt(in: owner, receiptID: receipt.id) }
        return try FileTools(paths: paths).undo(receipt)
    }

    private func rollbackReceipt(in savedPlan: Plan, receiptID: UUID) throws -> String {
        var plan = savedPlan
        guard ["applying", "rollbackFailed", "applied"].contains(plan.status),
              let index = plan.receipts.firstIndex(where: { $0.id == receiptID }) else {
            throw AgentError.message("Изменение уже отменено или не принадлежит этому плану")
        }
        let receipt = plan.receipts[index]
        let tools = FileTools(paths: paths)
        let message = try alreadyRestored(receipt, tools: tools)
            ? "Изменение уже отменено: \(receipt.source)" : tools.undo(receipt)
        plan.receipts.remove(at: index)
        if plan.receipts.isEmpty { plan.status = "rolledBack"; plan.failure = nil }
        try save(plan)
        return message
    }

    private func load(_ id: String) throws -> Plan {
        guard UUID(uuidString: id) != nil else { throw AgentError.message("Некорректный идентификатор плана") }
        let url = planURL(id.lowercased())
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 67_108_864 else {
            throw AgentError.message("Недопустимый файл журнала: \(url.lastPathComponent)")
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: 67_108_865) ?? Data()
        guard data.count <= 67_108_864 else { throw AgentError.message("Журнал плана превышает 64 МБ") }
        let plan = try JSONDecoder().decode(Plan.self, from: data)
        guard plan.version == 1, plan.id == id.lowercased(), plan.operations.count <= 100, plan.receipts.count <= 100 else {
            throw AgentError.message("Повреждённый или неподдерживаемый журнал плана")
        }
        return plan
    }

    /// Undo may finish immediately before the journal write is interrupted. Detect
    /// only the exact restored state; any unrelated edit still goes through undo's
    /// normal conflict checks rather than being overwritten.
    private func alreadyRestored(_ receipt: UndoRecord, tools: FileTools) throws -> Bool {
        let source = try tools.resolve(receipt.source, workingDirectory: nil)
        guard source.path == receipt.source else { return false }
        let exists = fm.fileExists(atPath: source.path)
        switch receipt.kind {
        case "write":
            guard let backup = receipt.backup else { return !exists }
            guard exists else { return false }
            let saved = URL(fileURLWithPath: backup).resolvingSymlinksInPath().standardizedFileURL
            let backupRoot = paths.backups.resolvingSymlinksInPath().standardizedFileURL.path
            guard saved.path.hasPrefix(backupRoot + "/"), fm.fileExists(atPath: saved.path) else { return false }
            return try tools.digest(source, checkCancellation: false) == tools.digest(saved, checkCancellation: false)
        case "move":
            guard exists, let destination = receipt.destination, let expected = receipt.expectedDigest else { return false }
            let target = try tools.resolve(destination, workingDirectory: nil)
            guard target.path == destination, !fm.fileExists(atPath: target.path) else { return false }
            return try tools.digest(source, checkCancellation: false) == expected
        case "trash":
            guard exists, let expected = receipt.expectedDigest else { return false }
            return try tools.digest(source, checkCancellation: false) == expected
        default: return false
        }
    }

    private func preflight(_ operation: Operation, tools: FileTools) throws {
        guard ["write", "move", "trash"].contains(operation.kind), operation.kind != "write" || operation.content != nil,
              operation.kind != "move" || operation.destination != nil,
              operation.kind == "write" || operation.expectedDigest != nil else { throw AgentError.message("Повреждённая операция плана") }
        let source = try tools.resolve(operation.source, workingDirectory: nil)
        guard source.path == operation.source else { throw AgentError.message("Путь плана заменён символической ссылкой") }
        let exists = fm.fileExists(atPath: source.path)
        if let expected = operation.expectedDigest {
            guard exists, try tools.digest(source) == expected else { throw AgentError.message("План устарел: исходный файл изменён: \(source.path)") }
        } else if exists { throw AgentError.message("План устарел: путь уже занят: \(source.path)") }
        if let destination = operation.destination {
            let target = try tools.resolve(destination, workingDirectory: nil)
            guard target.path == destination, !fm.fileExists(atPath: target.path) else { throw AgentError.message("План устарел: назначение изменилось: \(destination)") }
            var directory: ObjCBool = false
            guard fm.fileExists(atPath: target.deletingLastPathComponent().path, isDirectory: &directory), directory.boolValue else { throw AgentError.message("Каталог назначения недоступен") }
        }
    }
    private func overlaps(_ a: String, _ b: String) -> Bool { a == b || a == "/" || b == "/" || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") }
    private func planURL(_ id: String) -> URL { paths.backups.appendingPathComponent("plans", isDirectory: true).appendingPathComponent(id + ".json") }
    private func save(_ plan: Plan) throws {
        try paths.prepare()
        let url = planURL(plan.id)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(plan).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }
    private func diff(old: String, new: String) -> String {
        let before = old.components(separatedBy: "\n"), after = new.components(separatedBy: "\n")
        var prefix = 0
        while prefix < min(before.count, after.count), before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix, before[before.count - 1 - suffix] == after[after.count - 1 - suffix] { suffix += 1 }
        if old == new { return "<p>Содержимое не изменится.</p>" }
        func rows(_ lines: ArraySlice<String>, marker: String, css: String) -> String {
            lines.map { "<div class=\"\(css)\">\(marker)\(escape($0))</div>" }.joined()
        }
        return "<pre>" + rows(before.prefix(prefix), marker: " ", css: "context")
            + rows(before[prefix..<(before.count - suffix)], marker: "− ", css: "removed")
            + rows(after[prefix..<(after.count - suffix)], marker: "+ ", css: "added")
            + rows(before.suffix(suffix), marker: " ", css: "context") + "</pre>"
    }
}
