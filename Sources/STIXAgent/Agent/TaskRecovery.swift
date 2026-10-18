import Foundation

enum TaskRecovery {
    static func history(for job: AgentJob, chat: Chat) -> [LMMessage] {
        let source = job.sourceMessageID ?? job.id
        guard let start = chat.history.firstIndex(where: { $0.sourceMessageID == source }) else { return [] }
        return Array(chat.history.dropFirst(start))
    }
    static func report(job: AgentJob, chat: Chat, receipts: [UndoRecord], paths: AppStoragePaths) throws -> String {
        var lines = ["Восстановление задачи", "Последняя фаза: \(job.phase ?? "не сохранена"). Завершённых шагов: \(job.completedSteps ?? 0)."]
        var pending: [String: ToolCall] = [:], completed = 0, unknown = 0
        for message in history(for: job, chat: chat) {
            for call in message.toolCalls where !ToolExecutionLedger.isRead(call) { pending[call.id] = call }
            if message.role == "tool", let id = message.toolCallID, let call = pending.removeValue(forKey: id) {
                let text = message.content ?? ""
                if text.hasPrefix("Не выполнено:") { continue }
                if text.hasPrefix("Ошибка:") || text.hasPrefix("Операция прервана") {
                    unknown += 1; lines.append("\(call.name): результат неизвестен; автоматический повтор запрещён.")
                } else { completed += 1 }
            }
        }
        for call in pending.values.sorted(by: { $0.id < $1.id }) { unknown += 1; lines.append("\(call.name): нет сохранённого результата; автоматический повтор запрещён.") }
        lines.append("Сохранённых результатов действий: \(completed); неизвестных: \(unknown). Сохранённый ответ API или exit команды сам по себе не доказывает конечный результат.")
        for receipt in receipts {
            do {
                let check = try ResultVerifier.receipt(receipt, paths: paths)
                lines.append("\(check.passed ? "✓" : "⚠") \(check.subject): \(check.detail)")
            } catch { lines.append("⚠ \(receipt.source): проверка недоступна; действие не повторялось.") }
        }
        if job.prompt == "/image" || job.prompt.hasPrefix("/image ") || job.prompt.hasPrefix("/image\n") {
            let images = chat.messages.flatMap(\.attachments).filter { $0.kind == "image" }
            lines.append("Генерация могла быть передана ComfyUI. Не отправляй прежнюю генерацию повторно автоматически. Сначала проверь /queue и сохранённые изображения.")
            if let image = images.last { lines.append("Последнее сохранённое изображение этого чата: " + image.path) }
        }
        lines.append("Продолжай только оставшиеся шаги. При изменённых файлах прочитай текущее содержимое; не перезаписывай внешние изменения. Повтор команды с неизвестным результатом требует явного решения пользователя.")
        return lines.joined(separator: "\n")
    }
}

extension AppStore {
    func inspectRecovery(_ id: UUID) {
        guard !busy, let job = jobs.first(where: { $0.id == id }), let chat = chats.first(where: { $0.id == job.chatID }) else { return }
        let receipts = (job.undoIDs ?? []).compactMap { undos[$0] }, paths = storage.paths
        busy = true
        Task {
            defer { busy = false; startNextJob() }
            do {
                let report = try await fileWork { try TaskRecovery.report(job: job, chat: chat, receipts: receipts, paths: paths) }
                if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].recoveryReport = vault.redact(report) }
                addMessage(.init(role: "assistant", text: vault.redact(report)), to: job.chatID)
            } catch { self.error = vault.redact(error.localizedDescription) }
        }
    }
}
