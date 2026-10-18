import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared transcript operations keep branches and exports independent of the running agent.
enum ChatTranscript {
    static func matches(_ chat: Chat, query: String) -> Bool {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || chat.title.localizedStandardContains(value) || chat.messages.contains { $0.text.localizedStandardContains(value) }
    }

    static func branch(_ chat: Chat, before messageID: UUID) -> Chat? {
        guard let target = chat.messages.firstIndex(where: { $0.id == messageID && $0.role == "user" }) else { return nil }
        var result = Chat(folder: chat.folder, model: chat.model, imageModel: chat.imageModel)
        result.title = String((chat.title + " · ветка").prefix(100))
        result.questionLevel = chat.questionLevel; result.imagePromptModel = chat.imagePromptModel; result.imagePromptLanguage = chat.imagePromptLanguage
        var copiedIDs: [UUID: UUID] = [:]
        result.messages = chat.messages.prefix(target).map { original in
            var copy = original
            copy.id = UUID(); copiedIDs[original.id] = copy.id
            // An existing file operation remains owned by the original transcript.
            copy.undoID = nil
            return copy
        }
        if let cutoff = chat.history.firstIndex(where: { $0.sourceMessageID == messageID }) {
            result.history = Array(chat.history.prefix(cutoff)).map { message in var copy = message; copy.sourceMessageID = message.sourceMessageID.flatMap { copiedIDs[$0] }; return copy }; return result
        }
        var visibleCursor = 0
        var cutoff = chat.history.count
        for (historyIndex, item) in chat.history.enumerated() where item.role == "user" {
            guard let visible = chat.messages.indices.dropFirst(visibleCursor).first(where: { index in
                let message = chat.messages[index]
                let attachmentText = message.attachments.map { "Вложение (\($0.kind)): \($0.path)" }.joined(separator: "\n")
                let input = [message.text, attachmentText].filter { !$0.isEmpty }.joined(separator: "\n\n")
                return message.role == "user" && input == item.content
            }) else { continue }
            if visible >= target { cutoff = historyIndex; break }
            visibleCursor = visible + 1
        }
        result.history = Array(chat.history.prefix(cutoff)).map { message in var copy = message; copy.sourceMessageID = message.sourceMessageID.flatMap { copiedIDs[$0] }; return copy }
        return result
    }

    static func markdown(_ chat: Chat) -> String {
        let labels = ["user": "Вы", "assistant": "STIX Agent", "tool": "Действие", "permissions": "Разрешения", "model_settings": "Модели для задач"]
        let messages = chat.messages.map { message in
            let attachments = message.attachments.map { "- \($0.name): \($0.path)" }.joined(separator: "\n")
            return "## \(labels[message.role] ?? message.role)\n\n\(message.text)" + (attachments.isEmpty ? "" : "\n\nВложения:\n\(attachments)")
        }.joined(separator: "\n\n---\n\n")
        return "# \(chat.title)\n\n\(messages)\n"
    }
}

extension AppStore {
    var textScale: Double { min(24, max(11, preferences.fontSize ?? 14)) / 14 }
    func textSize(_ base: Double) -> CGFloat { CGFloat(base * textScale) }
    var messageSpacing: CGFloat { CGFloat(min(48, max(12, preferences.spacing ?? 24))) }

    func renameChat(_ id: UUID, title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = index(id) else { return }
        chats[i].title = String(clean.prefix(120)); save()
    }
    func toggleChatPin(_ id: UUID) {
        guard let i = index(id) else { return }
        chats[i].pinned = !(chats[i].pinned ?? false); save()
    }
    func exportChat(_ id: UUID) {
        guard let chat = chats.first(where: { $0.id == id }) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = String(chat.title.map { "/:\n\r".contains($0) ? "-" : $0 }.prefix(80)) + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try vault.redact(ChatTranscript.markdown(chat)).write(to: url, atomically: true, encoding: .utf8) }
        catch { self.error = "Не удалось экспортировать чат: \(error.localizedDescription)" }
    }
    func branchMessage(chatID: UUID, messageID: UUID, replacement: String? = nil) {
        guard let original = chats.first(where: { $0.id == chatID }),
              let message = original.messages.first(where: { $0.id == messageID && $0.role == "user" }),
              let branch = ChatTranscript.branch(original, before: messageID) else { return }
        guard activeChatID != chatID else { error = "Сначала приостановите текущую задачу, чтобы создать ветку."; return }
        let text = (replacement ?? message.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !message.attachments.isEmpty else { return }
        guard vault.redact(text) == text else { error = "В сообщении обнаружен ключ. Используйте защищённую форму подключения API."; return }
        preserveDraft(); chats.insert(branch, at: 0); selectedID = branch.id
        draft = text; attachments = message.attachments; save(); send()
    }
}
