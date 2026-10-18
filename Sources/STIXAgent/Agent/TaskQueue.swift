import Foundation

struct AgentJob: Codable, Identifiable {
    var id = UUID()
    var chatID: UUID
    var prompt: String
    var attachments: [Attachment] = []
    var status = "queued"
    var createdAt = Date()
    var hidden: Bool? = nil
    var started: Bool? = nil
    var inputRecorded: Bool? = nil
    var sourceMessageID: UUID? = nil
    var undoIDs: [UUID]? = nil
    var questionsAsked: Int? = nil
    var progress: Double? = nil
    var phase: String? = nil
    var completedSteps: Int? = nil
    var startedAt: Date? = nil
    var pendingCorrections: [String]? = nil
    var pendingCorrectionIDs: [UUID]? = nil
    var skipNextAction: Bool? = nil
    var recoveryReport: String? = nil
    var verifications: [TaskVerification]? = nil
    var imageSubmissionStarted: Bool? = nil
    var imageReplayBlocked: Bool? = nil
}

extension AppStore {
    func enqueue(prompt: String, attachments: [Attachment], chatID: UUID, sourceMessageID: UUID? = nil) {
        jobs.append(.init(chatID: chatID, prompt: prompt, attachments: attachments, sourceMessageID: sourceMessageID))
        save(); startNextJob()
    }
    func startNextJob() {
        guard canPersist, !busy, let job = jobs.first(where: { $0.status == "queued" && index($0.chatID) != nil }) else { return }
        busy = true; activeChatID = job.chatID; activeJobID = job.id; taskApprovals = []
        let resuming = job.inputRecorded == true
        updateJob(job.id, status: "running")
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i].started = true; jobs[i].startedAt = jobs[i].startedAt ?? Date(); jobs[i].phase = resuming ? (job.phase ?? "Восстановление") : "Начинаю задачу"; jobs[i].progress = nil }; save()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                if !resuming && (job.prompt == "/image" || job.prompt.hasPrefix("/image ") || job.prompt.hasPrefix("/image\n")) {
                    if let i = self.jobs.firstIndex(where: { $0.id == job.id }) { self.jobs[i].inputRecorded = true }; self.save()
                    guard self.canPersist else { throw AgentError.message("Не удалось сохранить начало генерации") }
                    try await self.generateImage(prompt: String(job.prompt.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines), chatID: job.chatID, attachments: job.attachments)
                    if self.hasPendingCorrections(chatID: job.chatID) {
                        try await self.runAgent(text: "Учти последующие уточнения к генерации изображения. Последняя готовая картинка доступна через generate_image input_image=last.", attachments: [], chatID: job.chatID)
                    }
                } else {
                    var text = job.prompt
                    if resuming, let chat = self.chats.first(where: { $0.id == job.chatID }) {
                        self.updateTaskPhase("Проверяю выполненные действия…")
                        let receipts = (job.undoIDs ?? []).compactMap { self.undos[$0] }, paths = self.storage.paths
                        let report = try await fileWork { try TaskRecovery.report(job: job, chat: chat, receipts: receipts, paths: paths) }
                        if let i = self.jobs.firstIndex(where: { $0.id == job.id }) { self.jobs[i].recoveryReport = self.vault.redact(report) }
                        text = "Продолжи прерванную задачу: " + job.prompt + "\n\n" + self.vault.redact(report)
                        self.addMessage(.init(role: "tool", text: "Проверка перед продолжением", toolName: "recovery", detail: self.vault.redact(report), status: "done"), to: job.chatID)
                    }
                    self.repairChatHistory(job.chatID)
                    try await self.runAgent(text: text, attachments: resuming ? [] : job.attachments, chatID: job.chatID, sourceMessageID: resuming ? nil : job.sourceMessageID)
                }
                if self.jobs.first(where: { $0.id == job.id })?.status == "running" { self.updateJob(job.id, status: "done") }
            } catch {
                self.repairChatHistory(job.chatID)
                let status = self.jobs.first(where: { $0.id == job.id })?.status
                let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                if status == "running" { self.updateJob(job.id, status: cancelled ? "interrupted" : "failed") }
                if error is TaskNeedsContinuation { self.updateJob(job.id, status: "paused") }
                let text = error is TaskNeedsContinuation ? "Достигнут лимит шагов. Задача сохранена; нажмите «Продолжить»." : status == "paused" ? "Задача приостановлена. Продолжение доступно в карточке задачи." : cancelled ? "Задача остановлена. Выполненные действия сохранены." : self.vault.redact(error.localizedDescription)
                self.addMessage(.init(role: "assistant", text: text, status: cancelled ? "interrupted" : "error"), to: job.chatID)
            }
            self.busy = false; self.activeChatID = nil; self.activeJobID = nil; self.pending = nil; self.continuation = nil; self.activity = ""; self.reasoningText = ""; self.transientReasoning = ""; self.task = nil
            self.save(); self.startNextJob()
        }
    }
    func updateJob(_ id: UUID, status: String) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].status = status; if status == "done" { jobs[i].progress = 1; jobs[i].phase = jobs[i].verifications?.contains(where: { !$0.passed }) == true ? "Готово · проверки требуют внимания" : "Готово" } }; save()
    }
    func pauseTask() {
        guard let id = activeJobID else { return }; updateJob(id, status: "paused"); stop()
    }
    func resumeJob(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), ["paused", "interrupted", "failed"].contains(jobs[i].status) else { return }
        jobs[i].imageReplayBlocked = jobs[i].imageSubmissionStarted == true
        jobs[i].status = "queued"; save(); startNextJob()
    }
    func cancelJob(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), !["done", "cancelled"].contains(job.status) else { return }
        updateJob(id, status: "cancelled"); if activeJobID == id { stop() }
    }
    func registerUndo(_ record: UndoRecord) {
        undos[record.id] = record
        if let id = activeJobID, let i = jobs.firstIndex(where: { $0.id == id }) {
            var ids = jobs[i].undoIDs ?? []; if !ids.contains(record.id) { ids.append(record.id) }; jobs[i].undoIDs = ids
        }; save()
    }
    func undoJob(_ id: UUID) {
        guard canPersist, !busy, let job = jobs.first(where: { $0.id == id }) else { return }
        recordHumanActionRequest("Отменить файловые изменения задачи " + id.uuidString, chatID: job.chatID)
        guard canPersist else { return }
        busy = true
        Task {
            defer { busy = false; save(); startNextJob() }
            var failures: [String] = []
            for receipt in (job.undoIDs ?? []).reversed() {
                guard canPersist else { failures.append("Запись недоступна; отмена остановлена"); break }
                guard let record = undos[receipt] else { continue }
                do {
                    let paths = storage.paths
                    _ = try await fileWork { try FileChangePlanner(paths: paths).undo(record) }
                    undos.removeValue(forKey: receipt)
                    if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].undoIDs?.removeAll { $0 == receipt } }
                    if let i = index(job.chatID) { for j in chats[i].messages.indices where chats[i].messages[j].undoID == receipt { chats[i].messages[j].undoID = nil; chats[i].messages[j].status = "undone" } }
                    save()
                } catch { failures.append(vault.redact(error.localizedDescription)); break }
            }
            recordHumanActionResult(failures.isEmpty ? "Доступные файловые изменения задачи " + id.uuidString + " отменены. Терминал и внешние действия не откатывались." : "Отмена задачи " + id.uuidString + " остановлена: " + failures.joined(separator: "\n"), chatID: job.chatID)
            addMessage(.init(role: "assistant", text: failures.isEmpty ? "Доступные файловые изменения задачи отменены. Команды терминала и внешние действия не откатываются автоматически." : "Откат остановлен из-за конфликта: " + failures.joined(separator: "\n")), to: job.chatID)
        }
    }
}

struct TaskNeedsContinuation: Error {}
