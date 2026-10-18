import AVFoundation
import Darwin
import Foundation
import Speech

/// Read-only checks. No model loads, inference, process startup, permission prompts or chat contents.
enum Diagnostics {
    typealias Fetch = @Sendable (URL) async throws -> JSONValue

    @MainActor
    static func run(preferences: AppPreferences, selectedModel: String = "", jobs: [AgentJob] = [], fetch: @escaping Fetch = { url in try await fetchJSON(url) }) async -> String {
        let selected = selectedModel.isEmpty ? preferences.defaultModel : selectedModel
        async let lm = inspectLM(endpoint: preferences.lmEndpoint, selected: selected, fetch: fetch)
        async let comfy = inspectComfy(endpoint: preferences.comfyEndpoint, fetch: fetch)
        let permissions = NativeCapabilities.status()
        let statuses = Dictionary(grouping: jobs, by: \.status).mapValues(\.count)
        var lines = ["Диагностика STIX Agent (только чтение)", memoryReport(), diskReport(availableBytes: diskAvailable()),
                     "Память агента: \(preferences.memory?.count ?? 0) записей; содержимое не читается.",
                     "Очередь агента: выполняются \(statuses["running", default: 0]), ожидают \(statuses["queued", default: 0]), приостановлены \(statuses["paused", default: 0]), прерваны \(statuses["interrupted", default: 0])."]
        lines += await [lm, comfy]
        lines.append("Разрешения macOS: Accessibility — \(permission(permissions["accessibility"])); запись экрана — \(permission(permissions["screen_recording"])); микрофон — \(microphoneStatus()); речь — \(speechStatus()).")
        if permissions["accessibility"] != .bool(true) || permissions["screen_recording"] != .bool(true) {
            lines.append("Для управления Mac разрешите STIX Agent Универсальный доступ и Запись экрана в Системные настройки → Конфиденциальность и безопасность. После изменения записи экрана может потребоваться перезапуск приложения.")
        }
        let automation = ["safari", "chrome", "textedit"].compactMap { name -> String? in
            guard let value = permissions[name], let code = value["automation_status"].int else { return nil }
            return "\(name): \(code == 0 ? "разрешено" : code == -1744 ? "ещё не запрошено" : code == -1743 ? "запрещено" : "статус \(code)")"
        }
        lines.append("Автоматизация: " + automation.joined(separator: "; ") + ". Проверка разрешений не показывает системных запросов.")
        return lines.joined(separator: "\n\n")
    }

    static func inspectLM(endpoint: String, selected: String, fetch: Fetch) async -> String {
        do {
            let data = try await fetch(localURL(endpoint: endpoint, path: "/v1/models", lm: true))
            guard let entries = data["data"].array else { return "LM Studio: неожиданный формат списка моделей. Проверьте адрес OpenAI-совместимого локального сервера." }
            let ids = entries.compactMap { $0["id"].string }.filter { !$0.lowercased().contains("embed") }
            guard !ids.isEmpty else { return "LM Studio: сервер доступен, текстовых моделей нет. Загрузите модель в LM Studio и включите Local Server." }
            if selected.isEmpty { return "LM Studio: сервер доступен, текстовых моделей \(ids.count). Выберите модель в чате. Доступность инференса не проверялась." }
            return ids.contains(selected)
                ? "LM Studio: сервер доступен; выбранная модель есть в /v1/models. Доступность инференса и загрузка в память не проверялись."
                : "LM Studio: сервер доступен; выбранная модель отсутствует в /v1/models. Обновите список моделей и выберите доступную."
        } catch { return failure("LM Studio", error: error, action: "Запустите Local Server в LM Studio и проверьте локальный адрес в настройках.") }
    }

    static func inspectComfy(endpoint: String, fetch: Fetch) async -> String {
        do {
            let queueURL = try localURL(endpoint: endpoint, path: "/queue")
            let modelsURL = try localURL(endpoint: endpoint, path: "/object_info/CheckpointLoaderSimple")
            async let queueResult = capture(fetch: fetch, url: queueURL)
            async let modelsResult = capture(fetch: fetch, url: modelsURL)
            let queue = await queueResult, models = await modelsResult
            var parts: [String] = []
            switch queue {
            case .success(let data):
                if let running = data["queue_running"].array, let pending = data["queue_pending"].array {
                    parts.append("сервер доступен; очередь: выполняются \(running.count), ожидают \(pending.count)")
                } else { parts.append("неожиданный формат очереди; проверьте API ComfyUI") }
            case .failure(let error): parts.append(failure("очередь", error: error, action: "Запустите ComfyUI и проверьте адрес."))
            }
            switch models {
            case .success(let data):
                if let names = data["CheckpointLoaderSimple"]["input"]["required"]["ckpt_name"].array?.first?.array {
                    parts.append(names.isEmpty ? "checkpoint-моделей нет: добавьте совместимую модель в ComfyUI/models/checkpoints" : "checkpoint-моделей: \(names.count); генерация и загрузка в память не проверялись")
                } else { parts.append("CheckpointLoaderSimple недоступен: проверьте установленный ComfyUI и совместимый checkpoint") }
            case .failure(let error): parts.append(failure("модели", error: error, action: "Проверьте API и checkpoint-модели ComfyUI."))
            }
            return "ComfyUI: " + parts.joined(separator: "; ") + "."
        } catch { return failure("ComfyUI", error: error, action: "Укажите локальный адрес ComfyUI в настройках.") }
    }

    static func localURL(endpoint: String, path: String, lm: Bool = false) throws -> URL {
        guard var parts = URLComponents(string: endpoint), ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host?.lowercased(), ["localhost", "127.0.0.1", "[::1]", "::1"].contains(host),
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else {
            throw DiagnosticError.nonLocal
        }
        var base = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if lm, base == "v1" || base.hasSuffix("/v1") { base = String(base.dropLast(2)).trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        parts.path = (base.isEmpty ? "" : "/" + base) + path
        guard let url = parts.url else { throw DiagnosticError.nonLocal }
        return url
    }

    static func fetchJSON(_ url: URL) async throws -> JSONValue {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4; config.timeoutIntervalForResource = 6
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.timeoutInterval = 4
        return try await withTaskCancellationHandler {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else { throw DiagnosticError.http }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < 2_000_000 else { throw DiagnosticError.responseTooLarge }
                data.append(byte)
            }
            return try JSONDecoder().decode(JSONValue.self, from: data)
        } onCancel: { session.invalidateAndCancel() }
    }
    private static func capture(fetch: Fetch, url: URL) async -> Result<JSONValue, Error> {
        do { return .success(try await fetch(url)) } catch { return .failure(error) }
    }
    private static func failure(_ service: String, error: Error, action: String) -> String {
        if case DiagnosticError.nonLocal = error { return "\(service): проверка пропущена — разрешён только loopback-адрес без логина, пароля и параметров. \(action)" }
        if (error as? URLError)?.code == .timedOut { return "\(service): превышено время ожидания (до 6 с). \(action)" }
        // Never include server bodies, endpoint strings, filenames, credentials or raw errors.
        return "\(service): локальный API не ответил корректно. \(action)"
    }
    private static func permission(_ value: JSONValue?) -> String { value == .bool(true) ? "разрешено" : "не разрешено" }
    private static func microphoneStatus() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return "разрешено"
        case .notDetermined: return "ещё не запрошено"
        case .denied: return "запрещено; разрешите в настройках конфиденциальности"
        case .restricted: return "ограничено системой"
        @unknown default: return "неизвестно"
        }
    }
    private static func speechStatus() -> String {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return "разрешено (диктовка только на устройстве)"
        case .notDetermined: return "ещё не запрошено"
        case .denied: return "запрещено; разрешите в настройках конфиденциальности"
        case .restricted: return "ограничено системой"
        @unknown default: return "неизвестно"
        }
    }
    private static func memoryReport() -> String {
        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        var info = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self(); defer { mach_port_deallocate(mach_task_self_, host) }
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard status == KERN_SUCCESS else { return String(format: "Память Mac: %.1f ГБ физической памяти; свободная память недоступна.", total) }
        let free = Double(UInt64(info.free_count) + UInt64(info.inactive_count)) * Double(vm_kernel_page_size) / 1_073_741_824
        return String(format: "Память Mac: %.1f ГБ физической; свободная + неактивная ≈ %.1f ГБ. Это оценка, не гарантия места для загрузки модели.", total, free)
    }
    static func diskAvailable(at url: URL = FileManager.default.homeDirectoryForCurrentUser) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }
    static func diskReport(availableBytes: Int64?) -> String {
        guard let availableBytes else { return "Диск: свободное место недоступно для оценки." }
        let text = "Диск: доступно " + ByteCountFormatter.string(fromByteCount: max(0, availableBytes), countStyle: .file) + "."
        return text + (availableBytes < 5_000_000_000 ? " Освободите не менее 5 ГБ перед генерацией и загрузкой моделей; приложение ничего не удаляет автоматически." : "")
    }
    enum DiagnosticError: Error { case nonLocal, http, responseTooLarge }
}
