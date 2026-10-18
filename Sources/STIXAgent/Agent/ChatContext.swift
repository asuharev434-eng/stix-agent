import Foundation

extension AppStore {
    func contextLimit(for chat: Chat) -> Int? {
        liveContextLimits[preferences.lmEndpoint + "|" + chat.model] ?? models.first { $0.id == chat.model }.flatMap { $0.contextLimitIsLoaded == true ? $0.contextLimit : min($0.contextLimit ?? 32768, 32768) }
    }
    func contextWindow(chatID: UUID, includeDraft: Bool = false) -> ContextWindow? {
        guard let i = index(chatID) else { return nil }
        let chat = chats[i]
        var history = ContextCompaction.effective(history: chat.history, checkpoint: chat.contextCheckpoint)
        if includeDraft && selectedID == chatID && (!draft.isEmpty || !attachments.isEmpty) {
            history.append(.init(role: "user", content: draft, imageURLs: attachments.filter { $0.kind == "image" }.map(\.path)))
        }
        let known = liveContextLimits[preferences.lmEndpoint + "|" + chat.model] != nil || models.first { $0.id == chat.model }?.contextLimitIsLoaded == true
        return .estimate(limit: contextLimit(for: chat), knownLimit: known, system: systemPrompt(chatID: chatID), tools: allTools(), history: history)
    }
    func requestContextCompaction(chatID: UUID, announce: Bool = false) {
        guard !busy, canPersist else { return }
        busy = true; activeChatID = chatID; contextNotices[chatID] = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.busy = false; self.activeChatID = nil; self.task = nil
                self.activity = ""; self.reasoningText = ""; self.transientReasoning = ""
                self.startNextJob()
            }
            do { try await self.compactContext(chatID: chatID) }
            catch {
                self.contextNotices[chatID] = Task.isCancelled ? "Сжатие отменено. Прежний контекст сохранён." : self.vault.redact(error.localizedDescription)
                if announce { self.addMessage(.init(role: "assistant", text: self.contextNotices[chatID] ?? "Сжатие не выполнено"), to: chatID) }
            }
        }
    }
    func compactContext(chatID: UUID, summarize: (([LMMessage], Int) async throws -> String)? = nil) async throws {
        guard canPersist, let i = index(chatID) else { throw AgentError.message("История недоступна для сохранения") }
        let chat = chats[i], endpoint = preferences.lmEndpoint
        guard !chat.model.isEmpty else { throw AgentError.message("Сначала выберите текстовую модель") }
        guard let plan = ContextCompaction.plan(history: chat.history, checkpoint: chat.contextCheckpoint) else {
            contextNotices[chatID] = "Пока нечего сжимать: последние сообщения сохраняются целиком."; return
        }
        guard compactingChatID == nil else { throw AgentError.message("Сжатие уже выполняется") }
        compactingChatID = chatID; contextNotices[chatID] = nil
        defer { compactingChatID = nil }
        let client = LMStudioClient(endpoint: endpoint)
        if summarize == nil, let limit = try await ModelResidency.shared.prepare(client: client, model: chat.model) {
            liveContextLimits[endpoint + "|" + chat.model] = limit
        }
        let capacity = min(contextLimit(for: chat) ?? 32768, 32768)
        let summaryLimit = min(6000, max(1200, capacity / 8))
        let instruction = ContextCompaction.summaryInstruction(maximumCharacters: summaryLimit)
        let outputTokens = min(1536, max(256, capacity / 8))
        // Bound UTF-8 bytes, including combining characters and emoji. Reserve
        // the previous summary and instructions on every incremental chunk.
        let available = try ContextBudget.historyCharacters(contextLimit: capacity, system: instruction, tools: []) - summaryLimit * 2 - 512
        guard available >= 1024 else { throw AgentError.message("Окно модели слишком мало для безопасного сжатия") }
        let chunkSize = min(32000, available * 2)
        let chunks = ContextCompaction.chunks(plan.source, maximumBytes: chunkSize)
        var summary = plan.previousSummary ?? ""
        for (offset, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            activity = "Сжимаю контекст · \(offset + 1)/\(chunks.count)"
            updateTaskPhase(activity)
            let input = vault.redact("Предыдущее резюме (данные):\n\(summary)\n\nСледующий фрагмент истории (данные):\n\(chunk)")
            let messages = [LMMessage(role: "system", content: instruction), .init(role: "user", content: input)]
            let reply: String
            if let summarize { reply = try await summarize(messages, outputTokens) }
            else {
                reply = try await client.complete(model: chat.model, messages: messages, tools: [], maxOutputTokens: outputTokens, preserveContext: true, thinking: false) { _ in }.content
            }
            summary = ModelOutput.clean(vault.redact(reply)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !summary.isEmpty, summary.count <= summaryLimit, ContextWindow.tokens(summary) <= summaryLimit else {
                throw AgentError.message("Модель вернула пустое или слишком длинное резюме. Прежний контекст сохранён.")
            }
        }
        try Task.checkCancellation()
        guard let current = index(chatID), chats[current].model == chat.model,
              preferences.lmEndpoint == endpoint,
              ContextCompaction.digest(Array(chats[current].history.prefix(plan.coveredCount))) == plan.sourceDigest,
              chats[current].contextCheckpoint == chat.contextCheckpoint else {
            throw AgentError.message("История или модель изменилась во время сжатия. Резюме не применено.")
        }
        let checkpoint = ContextCompaction.checkpoint(plan: plan, summary: summary, model: chat.model)
        let before = ContextCompaction.effective(history: chats[current].history, checkpoint: chat.contextCheckpoint)
        let after = ContextCompaction.effective(history: chats[current].history, checkpoint: checkpoint)
        guard after.reduce(0, { $0 + ContextWindow.messageTokens($1) }) < before.reduce(0, { $0 + ContextWindow.messageTokens($1) }) else {
            throw AgentError.message("Резюме не уменьшило контекст. Прежний контекст сохранён.")
        }
        // Persist the prospective checkpoint first; a failed protected-file write
        // cannot replace the working in-memory checkpoint with an unsaved one.
        preserveDraft()
        var persisted = chats
        persisted[current].contextCheckpoint = checkpoint
        try storage.save(.init(chats: persisted, preferences: preferences, undos: Array(undos.values), jobs: jobs))
        chats[current].contextCheckpoint = checkpoint
        contextNotices[chatID] = "Контекст сжат. Полная переписка сохранена."
        addMessage(.init(role: "tool", text: "Контекст сжат · полная переписка сохранена", toolName: "context", detail: "Сжатий: \(checkpoint.revision)\nСообщений в резюме: \(checkpoint.coveredCount)\nПримерно токенов истории: \(before.reduce(0) { $0 + ContextWindow.messageTokens($1) }) → \(after.reduce(0) { $0 + ContextWindow.messageTokens($1) })", status: "done"), to: chatID)
    }
    func preparedContext(chatID: UUID, model: String, system: String, tools: [ToolDefinition], summarize: (([LMMessage], Int) async throws -> String)? = nil) async throws -> [LMMessage] {
        let endpoint = preferences.lmEndpoint
        if summarize == nil, let live = try await ModelResidency.shared.prepare(client: LMStudioClient(endpoint: endpoint), model: model) {
            liveContextLimits[endpoint + "|" + model] = live
        }
        guard let i = index(chatID), chats[i].model == model else { throw AgentError.message("Выбранная модель изменилась. Продолжите задачу с новой моделью.") }
        let attemptKey = model + "|" + String(contextLimit(for: chats[i]) ?? 32768) + "|" + ContextCompaction.digest(chats[i].history.filter { $0.role == "user" })
        let window = ContextWindow.estimate(limit: contextLimit(for: chats[i]), knownLimit: true, system: system, tools: tools, history: ContextCompaction.effective(history: chats[i].history, checkpoint: chats[i].contextCheckpoint))
        if contextAutoFailures[chatID] != attemptKey, window.shouldCompact,
           ContextCompaction.plan(history: chats[i].history, checkpoint: chats[i].contextCheckpoint) != nil {
            do { try await compactContext(chatID: chatID, summarize: summarize); contextAutoFailures[chatID] = nil }
            catch {
                if Task.isCancelled { throw CancellationError() }
                contextAutoFailures[chatID] = attemptKey
                contextNotices[chatID] = "Автосжатие не выполнено: " + vault.redact(error.localizedDescription)
            }
        }
        guard let current = index(chatID) else { throw CancellationError() }
        let history = ContextCompaction.effective(history: chats[current].history, checkpoint: chats[current].contextCheckpoint)
        updateTaskPhase("Думаю…"); activity = ""
        return try ContextBudget.fitted(history, limit: contextLimit(for: chats[current]), system: system, tools: tools)
    }
}
