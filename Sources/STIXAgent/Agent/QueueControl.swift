import Foundation

enum TaskControlTools {
    static let definitions: [ToolDefinition] = [
        .init(name: "list_tasks", description: "List local chat task queue including current IDs/status/phase/steps. Does not run any task.", parameters: ToolCatalog.schema([:], required: [])),
        .init(name: "manage_task", description: "pause/resume/cancel a local task. job_id UUID or current. Pausing/cancelling current ends this agent turn; user can resume paused task. No scheduled wake-up while app closed.", parameters: ToolCatalog.schema(["job_id": "string", "action": "string"], required: ["job_id", "action"])),
        .init(name: "queue_task", description: "Queue a clearly requested separate follow-up task in this chat while current completes. Do not queue yourself recursively or create background goals. Returns job_id.", parameters: ToolCatalog.schema(["prompt": "string"], required: ["prompt"]))
    ]
}

extension AppStore {
    func toggleTaskPanel(chatID: UUID) {
        guard let i = index(chatID) else { return }
        chats[i].tasksCollapsed = !(chats[i].tasksCollapsed ?? false); save()
    }
    func dismissTask(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }), ["done", "cancelled", "failed"].contains(jobs[i].status) else { return }
        jobs[i].hidden = true; save()
    }
    func dismissCompletedTasks(chatID: UUID) {
        for i in jobs.indices where jobs[i].chatID == chatID && ["done", "cancelled", "failed"].contains(jobs[i].status) { jobs[i].hidden = true }; save()
    }
    func revealTasks(chatID: UUID) {
        for i in jobs.indices where jobs[i].chatID == chatID { jobs[i].hidden = false }
        if let i = index(chatID) { chats[i].tasksCollapsed = false }; save()
    }

    func updateTaskPhase(_ phase: String, progress: Double? = nil) {
        activity = phase
        if let id = activeJobID, let i = jobs.firstIndex(where: { $0.id == id }) {
            jobs[i].phase = phase
            jobs[i].progress = progress.flatMap { $0.isFinite ? min(1, max(0, $0)) : nil }
        }
    }
    func updateImageStep(_ value: Int, total: Int) {
        guard total > 0, (0...total).contains(value) else { return }
        updateTaskPhase("Генерация изображения · шаг \(value) из \(total)", progress: Double(value) / Double(total))
    }
    func completedTaskStep() {
        if let id = activeJobID, let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].completedSteps = (jobs[i].completedSteps ?? 0) + 1 }; save()
    }
    @discardableResult func steerCurrentTask(_ raw: String) -> Bool {
        guard busy, let id = activeJobID, let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].status == "running", jobs[i].chatID == selectedID, pending?.kind != .secret else { return false }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 16000 else { error = "Корректировка: от 1 до 16000 символов"; return false }
        guard vault.redact(text) == text else { error = "Секреты вводятся через защищённую форму"; return false }
        if pendingHere, pending?.kind == .question { respond(.text(text)); return true }
        let replacesApproval = pendingHere && pending?.kind == .approval
        var corrections = jobs[i].pendingCorrections ?? []
        guard corrections.count < 20 else { error = "Дождитесь применения предыдущих корректировок"; return false }
        let message = ChatMessage(role: "user", text: text, status: "steering")
        corrections.append(text); jobs[i].pendingCorrections = corrections
        var ids = jobs[i].pendingCorrectionIDs ?? []; ids.append(message.id); jobs[i].pendingCorrectionIDs = ids
        addMessage(message, to: jobs[i].chatID); if replacesApproval { respond(.deny) }; save(); return true
    }
    func applyPendingCorrections(chatID: UUID) -> Bool {
        guard let id = activeJobID, let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].chatID == chatID,
              let corrections = jobs[i].pendingCorrections, !corrections.isEmpty, let chat = index(chatID) else { return false }
        let ids = jobs[i].pendingCorrectionIDs ?? []
        for (offset, text) in corrections.enumerated() {
            chats[chat].history.append(.init(role: "user", content: "Уточнение пользователя к текущей задаче. Применяй к следующим шагам; уже выполненные действия сначала проверь:\n" + vault.redact(text), sourceMessageID: offset < ids.count ? ids[offset] : nil))
        }
        jobs[i].pendingCorrections = []; jobs[i].pendingCorrectionIDs = []; save(); return true
    }
    func hasPendingCorrections(chatID: UUID) -> Bool {
        guard let id = activeJobID else { return false }
        return jobs.first(where: { $0.id == id && $0.chatID == chatID })?.pendingCorrections?.isEmpty == false
    }
    @discardableResult func editQueuedJob(_ id: UUID, prompt raw: String) -> Bool {
        guard let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].status == "queued" else { error = "Задача уже запущена. Передайте изменение как уточнение текущей задачи."; return false }
        let prompt = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (!prompt.isEmpty || !jobs[i].attachments.isEmpty), prompt.count <= 64000, vault.redact(prompt) == prompt else { error = "Недопустимое сообщение; секреты вводятся отдельно"; return false }
        jobs[i].prompt = prompt
        if let messageID = jobs[i].sourceMessageID { editMessage(messageID, chatID: jobs[i].chatID) { $0.text = prompt } }; save(); return true
    }
    func moveQueuedJob(_ id: UUID, offset: Int) {
        guard offset == -1 || offset == 1, let i = jobs.firstIndex(where: { $0.id == id }), jobs[i].status == "queued" else { return }
        let queued = jobs.indices.filter { jobs[$0].status == "queued" && jobs[$0].chatID == jobs[i].chatID }
        guard let at = queued.firstIndex(of: i), queued.indices.contains(at + offset) else { return }
        jobs.swapAt(i, queued[at + offset]); save()
    }
    func steerQueuedJob(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.status == "queued", job.attachments.isEmpty else { error = "Для корректировки передайте текст без новых вложений"; return }
        // The queued user message already exists: remove its duplicate only after steering succeeded.
        if steerCurrentTask(job.prompt) {
            updateJob(id, status: "cancelled")
            if let source = job.sourceMessageID, let i = index(job.chatID) { chats[i].messages.removeAll { $0.id == source } }; save()
        }
    }
    func executeTaskControl(_ name: String, args: JSONValue, chatID: UUID) async throws -> ToolOutcome {
        if name == "list_tasks" {
            return .init(text: jobs.filter { $0.chatID == chatID }.map { "\($0.id) | \($0.status) | \($0.phase ?? "") | шагов: \($0.completedSteps ?? 0) | \(String($0.prompt.prefix(300)))" }.joined(separator: "\n"))
        }
        if name == "queue_task" {
            let prompt = vault.redact(try args.requiredString("prompt"))
            guard prompt.count <= 16000, jobs.filter({ $0.chatID == chatID && $0.status == "queued" }).count < 20 else { throw AgentError.message("Слишком много задач или длинный запрос") }
            let message = ChatMessage(role: "user", text: prompt, status: "queued")
            addMessage(message, to: chatID); enqueue(prompt: prompt, attachments: [], chatID: chatID, sourceMessageID: message.id)
            return .init(text: "В очереди: \(jobs.last!.id)")
        }
        let raw = try args.requiredString("job_id"), action = try args.requiredString("action")
        let id = raw == "current" ? activeJobID : UUID(uuidString: raw)
        guard let id, let job = jobs.first(where: { $0.id == id }), job.chatID == chatID else { throw AgentError.message("Задача этого чата не найдена") }
        switch action {
        case "pause":
            guard id == activeJobID, job.status == "running" else { throw AgentError.message("Приостановить можно текущую выполняемую задачу") }; pauseTask()
        case "resume":
            guard ["paused", "interrupted", "failed"].contains(job.status) else { throw AgentError.message("Задача не ожидает продолжения") }; resumeJob(id)
        case "cancel": cancelJob(id)
        default: throw AgentError.message("Действие: pause/resume/cancel")
        }
        return .init(text: "Задача \(id): \(action)")
    }
}
