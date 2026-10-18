import Foundation
import ImageIO

struct TaskVerification: Codable, Identifiable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var subject: String
    var passed: Bool
    var detail: String
}

enum ResultVerifier {
    /// Checks the persisted receipt against current bytes without repeating any mutation.
    static func receipt(_ record: UndoRecord, paths: AppStoragePaths) throws -> TaskVerification {
        let tools = FileTools(paths: paths), fm = FileManager.default
        let source = try tools.resolve(record.source, workingDirectory: nil)
        let sourceExists = fm.fileExists(atPath: source.path)
        let target: URL?
        switch record.kind {
        case "write": target = source
        case "move": target = try record.destination.map { try tools.resolve($0, workingDirectory: nil) }
        case "trash":
            // The protected backup is the recoverable source of truth if Trash was emptied externally.
            target = record.backup.map { URL(fileURLWithPath: $0) }
        default: throw AgentError.message("Неизвестный тип квитанции")
        }
        var valid = false
        if let target, fm.fileExists(atPath: target.path), let digest = record.expectedDigest {
            valid = try tools.digest(target) == digest && (record.kind == "write" || !sourceExists)
        }
        return .init(subject: record.source, passed: valid, detail: valid ? "Состояние и контрольная сумма совпадают с квитанцией" : "Состояние изменилось или файл недоступен. Действие не повторялось")
    }

    static func image(_ path: String, paths: AppStoragePaths) throws -> TaskVerification {
        let url = try FileTools(paths: paths).resolve(path, workingDirectory: nil)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString:Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else {
            return .init(subject: path, passed: false, detail: "Изображение отсутствует, повреждено или имеет недопустимый размер")
        }
        return .init(subject: path, passed: true, detail: "Файл декодирован: \(width) × \(height)")
    }

    static func syntax(path: String, paths: AppStoragePaths, runner: ProcessRunner) async throws -> TaskVerification {
        let url = try FileTools(paths: paths).resolve(path, workingDirectory: nil)
        let attributes = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= 2_000_000 else { throw AgentError.message("Проверка синтаксиса: нужен файл до 2 МБ") }
        let ext = url.pathExtension.lowercased()
        if ext == "json" {
            let data = try Data(contentsOf: url)
            do { _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]); return .init(subject: path, passed: true, detail: "Синтаксис JSON корректен") }
            catch { return .init(subject: path, passed: false, detail: "Некорректный JSON: " + error.localizedDescription) }
        }
        let command: String
        switch ext {
        case "py": command = "python3 -I -c " + quote("import pathlib,sys; p=pathlib.Path(sys.argv[1]); compile(p.read_bytes(), str(p), 'exec'); print('Python syntax OK')") + " " + quote(url.path)
        case "js", "mjs", "cjs": command = "node --check " + quote(url.path)
        case "sh": command = "/bin/bash -n " + quote(url.path)
        case "zsh": command = "/bin/zsh -n " + quote(url.path)
        default: throw AgentError.message("Проверка синтаксиса поддерживает Python, JavaScript, JSON, sh и zsh. Для остальных языков запусти подходящую проверку через run_shell")
        }
        let result = try await runner.run(command: command, directory: url.deletingLastPathComponent().path, timeout: 20)
        return .init(subject: path, passed: result.exitCode == 0 && !result.timedOut, detail: result.exitCode == 127 ? "Интерпретатор не установлен; синтаксис не проверен" : "Проверка синтаксиса, exit \(result.exitCode): " + String(result.output.prefix(3000)))
    }
    private static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

extension AppStore {
    func recordVerification(_ value: TaskVerification) {
        guard let id = activeJobID, let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        var safe = value; safe.subject = vault.redact(safe.subject); safe.detail = vault.redact(safe.detail)
        var values = jobs[i].verifications ?? []; values.append(safe); jobs[i].verifications = values; save()
    }
    func verifyMutation(_ receipt: UndoRecord) async throws -> [TaskVerification] {
        let paths = storage.paths
        let check: TaskVerification
        do { check = try await fileWork { try ResultVerifier.receipt(receipt, paths: paths) } }
        catch {
            if Task.isCancelled { throw CancellationError() }
            let failure = TaskVerification(subject: receipt.source, passed: false, detail: "Проверка состояния недоступна: " + vault.redact(error.localizedDescription))
            recordVerification(failure); return [failure]
        }
        var checks = [check]
        if check.passed, receipt.kind == "write", ["py", "js", "mjs", "cjs", "json", "sh", "zsh"].contains(URL(fileURLWithPath: receipt.source).pathExtension.lowercased()) {
            do { checks.append(try await ResultVerifier.syntax(path: receipt.source, paths: paths, runner: processRunner)) }
            catch {
                if Task.isCancelled { throw CancellationError() }
                checks.append(.init(subject: receipt.source, passed: false, detail: "Синтаксис не проверен: " + vault.redact(error.localizedDescription)))
            }
        }
        checks.forEach(recordVerification)
        return checks
    }
    func verifiedOutcome(_ outcome: ToolOutcome, call: ToolCall) async throws -> ToolOutcome {
        var result = outcome
        if let undo = outcome.undo {
            let checks = try await verifyMutation(undo)
            result.text += "\n" + checks.map { "\($0.passed ? "✓" : "⚠") Проверка: " + vault.redact($0.detail) }.joined(separator: "\n")
        }
        return result
    }
}
