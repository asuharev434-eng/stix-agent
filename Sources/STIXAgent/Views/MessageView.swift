import SwiftUI
import AppKit
import QuickLook

struct MessageView: View {
    @EnvironmentObject var store: AppStore
    let message: ChatMessage
    let chatID: UUID
    @State private var preview: URL?
    @State private var editing = false
    @State private var editedText = ""
    @State private var editingImage: Attachment?
    @State private var diffRecord: UndoRecord?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if message.role == "feature_workflows" { WorkflowsCard(chatID:chatID) }
            else if message.role == "workflow_form", let id=UUID(uuidString:message.text) { WorkflowFormCard(workflowID:id,chatID:chatID) }
            else if message.role == "feature_automations" { AutomationsCard(chatID:chatID) }
            else if message.role == "feature_documents" { DocumentsCard() }
            else if message.role == "feature_gallery" { GalleryCard() }
            else if message.role == "feature_resources" { ResourcesCard() }
            else if message.role == "feature_backups" { BackupsCard(chatID:chatID) }
            else if message.role == "file_plan" { FilePlanCard(planID: message.text, chatID: chatID) }
            else if message.role == "model_settings" { ModelSettingsCard(chatID: chatID) }
            else if message.role == "memory" { MemoryCard(chatID: chatID) }
            else if message.role == "skills" { SkillsCard() }
            else if message.role == "plugins" { PluginsCard(chatID: chatID, initialURL: message.detail ?? "") }
            else if message.role == "chat_search" { ChatSearchCard(initialQuery: message.text) }
            else if message.role == "permissions" { PermissionsCard() }
            else if message.role == "tool" {
                DisclosureGroup {
                    if let detail = message.detail { Text(detail).font(.system(size: store.textSize(11), design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).padding(.vertical, 6) }
                    MarkdownMessageBody(text: message.text)
                } label: {
                    HStack(spacing: 8) {
                        if message.status == "running" { ProgressView().controlSize(.mini) }
                        else { Image(systemName: message.status == "error" ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(message.status == "error" ? Color.orange : Color.secondary) }
                        Text(store.displayToolName(message.toolName ?? "Действие")).font(.system(size: store.textSize(12), weight: .medium))
                        Spacer()
                        Text(["done": "Готово", "running": "Выполняется", "error": "Ошибка", "undone": "Отменено", "interrupted": "Прервано"][message.status ?? ""] ?? "").font(.system(size: store.textSize(11))).foregroundStyle(.secondary)
                    }
                }.padding(16).agentCard()
            } else if message.role == "user" {
                HStack {
                    Spacer(minLength: 45)
                    Text(message.text).font(.system(size: store.textSize(14))).textSelection(.enabled).padding(.horizontal, 17).padding(.vertical, 12)
                        .background(.primary.opacity(0.065), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
            } else { MarkdownMessageBody(text: message.text) }
            ForEach(message.attachments) { attachment in
                if ["html", "mermaid"].contains(attachment.kind) || ["html", "htm", "svg", "mmd", "mermaid"].contains(URL(fileURLWithPath: attachment.path).pathExtension.lowercased()) {
                    ArtifactView(attachment: attachment)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        if attachment.kind == "image", let image = NSImage(contentsOfFile: attachment.path) {
                            Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 620, maxHeight: 420).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous)).onTapGesture { preview = URL(fileURLWithPath: attachment.path) }
                        }
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: attachment.path)).resizable().frame(width: 30, height: 30)
                            Text(attachment.name).font(.system(size: store.textSize(12), weight: .medium)).lineLimit(1)
                            Spacer()
                            if attachment.kind == "image" {
                                Button { editingImage = attachment } label: { Label("Редактировать", systemImage: "slider.horizontal.3") }.help("Маска, сравнение и варианты изображения")
                            }
                            Button { preview = URL(fileURLWithPath: attachment.path) } label: { Image(systemName: "eye") }.help("Быстрый просмотр")
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: attachment.path)]) } label: { Image(systemName: "folder") }.help("Показать в Finder")
                            Button { NSWorkspace.shared.open(URL(fileURLWithPath: attachment.path)) } label: { Image(systemName: "arrow.up.forward.square") }.help("Открыть")
                        }.buttonStyle(.borderless).padding(14).agentCard(cornerRadius: 18)
                    }
                }
            }
            if let id = message.undoID {
                HStack {
                    if let record = store.undos[id], record.kind == "write" {
                        Button { diffRecord = record } label: { Label("Изменения файла", systemImage: "plus.forwardslash.minus") }
                    }
                    Button { store.undoAction(id, chatID: chatID, messageID: message.id) } label: { Label("Отменить действие", systemImage: "arrow.uturn.backward") }
                }.buttonStyle(.borderless).font(.system(size: store.textSize(12))).disabled(store.busy)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).quickLookPreview($preview)
            .sheet(item: $editingImage) { attachment in
                ImageEditorView(source: attachment, versions: store.chats.first(where: { $0.id == chatID })?.messages.flatMap(\.attachments).filter { $0.kind == "image" } ?? []) { command, files in
                    store.selectChat(chatID); store.draft = command; store.attachments = files; store.send()
                }
            }
            .sheet(item: $diffRecord) { record in FileDiffView(record: record, paths: store.storage.paths) }
            .contextMenu {
                Button("Копировать") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(message.text, forType: .string) }
                if message.role == "user" {
                    Button("Изменить и отправить в новой ветке…") { editedText = message.text; editing = true }
                        .disabled(store.activeChatID == chatID)
                    Button("Повторить в новой ветке") { store.branchMessage(chatID: chatID, messageID: message.id) }
                        .disabled(store.activeChatID == chatID)
                } else if message.role == "assistant", let user = previousUserMessage {
                    Button("Сгенерировать заново в новой ветке") { store.branchMessage(chatID: chatID, messageID: user.id) }
                        .disabled(store.activeChatID == chatID)
                }
            }
            .sheet(isPresented: $editing) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Изменить сообщение").font(.headline)
                    Text("Продолжение сохранится в новом чате. Исходная переписка останется в истории.").foregroundStyle(.secondary)
                    TextEditor(text: $editedText).font(.system(size: store.textSize(14))).frame(minHeight: 140).padding(8).agentCard(cornerRadius: 12)
                    HStack {
                        Button("Отмена") { editing = false }.keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Создать ветку и отправить") { store.branchMessage(chatID: chatID, messageID: message.id, replacement: editedText); editing = false }
                            .keyboardShortcut(.defaultAction).disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && message.attachments.isEmpty)
                    }
                }.padding(24).frame(width: 550)
            }
    }
    private var previousUserMessage: ChatMessage? {
        guard let messages = store.chats.first(where: { $0.id == chatID })?.messages,
              let index = messages.firstIndex(where: { $0.id == message.id }) else { return nil }
        return messages.prefix(index).last(where: { $0.role == "user" })
    }
}

struct MarkdownMessageBody: View {
    @EnvironmentObject var store: AppStore
    let text: String
    @Environment(\.colorScheme) private var colorScheme
    private struct Block: Identifiable { let id: Int; let code: Bool; let language: String; let text: String }
    private var blocks: [Block] {
        var result: [Block] = []; var lines: [String] = []; var code = false; var language = ""
        func flush() { if !lines.isEmpty { result.append(Block(id: result.count, code: code, language: language, text: lines.joined(separator: "\n"))); lines = [] } }
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flush(); code.toggle(); language = code ? String(line.trimmingCharacters(in: .whitespaces).dropFirst(3)) : ""
            } else { lines.append(line) }
        }
        flush(); return result
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(blocks) { block in
                if block.code && block.language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "mermaid" {
                    IsolatedArtifactWebView(source: block.text, mermaid: true, dark: colorScheme == .dark).frame(height: 340).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else if block.code {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack { Text(block.language.isEmpty ? "Код" : block.language).foregroundStyle(.secondary); Spacer(); Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(block.text, forType: .string) } label: { Label("Копировать", systemImage: "doc.on.doc") }.buttonStyle(.borderless) }.font(.system(size: store.textSize(11))).padding(10)
                        Divider()
                        ScrollView(.horizontal) { Text(block.text).font(.system(size: store.textSize(12), design: .monospaced)).textSelection(.enabled).padding(13).frame(maxWidth: .infinity, alignment: .leading) }
                    }.agentCard(cornerRadius: 18).clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(block.text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                            markdownLine(line)
                        }
                    }.textSelection(.enabled)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    @ViewBuilder private func markdownLine(_ line: String) -> some View {
        let hashes = line.prefix { $0 == "#" }.count
        if (1...6).contains(hashes), line.dropFirst(hashes).hasPrefix(" ") {
            rich(String(line.dropFirst(hashes + 1))).font(.system(size: store.textSize(hashes == 1 ? 24 : hashes == 2 ? 20 : 16), weight: .semibold)).padding(.top, 7)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 9) { Text("•"); rich(String(line.dropFirst(2))) }.font(.system(size: store.textSize(14))).padding(.leading, 4)
        } else if line.hasPrefix("> ") {
            HStack { Rectangle().fill(.secondary.opacity(0.3)).frame(width: 3); rich(String(line.dropFirst(2))).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
        } else { rich(line.isEmpty ? " " : line).font(.system(size: store.textSize(14))).lineSpacing(4) }
    }
    private func rich(_ value: String) -> Text {
        Text((try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value))
    }
}
