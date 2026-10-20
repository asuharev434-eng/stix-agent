import Foundation

/// Tiny character models use the ordinary imported-GGUF engine with a bounded request.
enum TinyTextPolicy {
    static func applies(_ model: ModelDescriptor) -> Bool {
        model.id.hasPrefix("builtin-text:") && (128...256).contains(model.contextLimit ?? 0)
    }

    static func outputLimit(question: String, context: Int) throws -> Int {
        let count = question.unicodeScalars.count
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              count <= context - 34 else {
            throw AgentError.message("Учебная модель принимает короткий вопрос: до \(context - 34) символов. Она не использует историю, память, файлы и инструменты.")
        }
        return context - 17 - count
    }
}

extension AppStore {
    func runTinyText(text: String, attachments: [Attachment], chatID: UUID,
                     sourceMessageID: UUID?, descriptor: ModelDescriptor) async throws {
        guard attachments.isEmpty else {
            throw AgentError.message("Учебная модель работает только с коротким текстом. Уберите вложения или выберите другую модель.")
        }
        let limit = try TinyTextPolicy.outputLimit(question: text, context: descriptor.contextLimit ?? 128)
        guard let i = index(chatID) else { throw CancellationError() }
        let input = LMMessage(role: "user", content: text, sourceMessageID: sourceMessageID)
        if let id = activeJobID, let job = jobs.firstIndex(where: { $0.id == id }) { jobs[job].inputRecorded = true }
        chats[i].history.append(input)
        requestSnapshots[chatID] = .init(model: descriptor.id, system: "", history: [input], tools: [])
        let message = ChatMessage(role: "assistant", text: "", status: "running")
        addMessage(message, to: chatID)
        save()
        do {
            let (ref, engine) = try inferenceRegistry.text(for: descriptor.id)
            let store = self
            let reply = try await engine.complete(model: ref.id, messages: [input], tools: [],
                maxOutputTokens: min(limit, 80), preserveContext: false, thinking: false,
                onPhase: { phase in await store.updateTaskPhase(phase) },
                onRequest: { _ in }, onReasoning: { _ in }, onText: { token in
                    await store.receiveToken(token, messageID: message.id, chatID: chatID)
                })
            try Task.checkCancellation()
            guard reply.toolCalls.isEmpty else { throw AgentError.message("Учебная модель не поддерживает инструменты") }
            streamedText.removeValue(forKey: message.id)
            let content = ModelOutput.clean(vault.redact(reply.content))
            editMessage(message.id, chatID: chatID) { $0.text = content; $0.status = "done" }
            if let i = index(chatID) { chats[i].history.append(.init(role: "assistant", content: content)) }
            save()
        } catch {
            streamedText.removeValue(forKey: message.id)
            editMessage(message.id, chatID: chatID) { $0.status = "interrupted" }
            throw error
        }
    }
}
