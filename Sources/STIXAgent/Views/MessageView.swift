import SwiftUI
import AppKit
import QuickLook

struct MessageView: View {
    @EnvironmentObject var store: AppStore
    let message: ChatMessage
    let chatID: UUID
    @State private var preview: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if message.role == "permissions" { PermissionsCard() }
            else if message.role == "tool" {
                DisclosureGroup {
                    if let detail = message.detail { Text(detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).padding(.vertical, 6) }
                    MarkdownMessageBody(text: message.text)
                } label: {
                    HStack(spacing: 8) {
                        if message.status == "running" { ProgressView().controlSize(.mini) }
                        else { Image(systemName: message.status == "error" ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(message.status == "error" ? Color.orange : Color.secondary) }
                        Text(store.displayToolName(message.toolName ?? "Действие")).font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text(["done": "Готово", "running": "Выполняется", "error": "Ошибка", "undone": "Отменено", "interrupted": "Прервано"][message.status ?? ""] ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }.padding(16).agentCard()
            } else if message.role == "user" {
                HStack {
                    Spacer(minLength: 45)
                    Text(message.text).font(.system(size: 14)).textSelection(.enabled).padding(.horizontal, 17).padding(.vertical, 12)
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
                            Text(attachment.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer()
                            Button { preview = URL(fileURLWithPath: attachment.path) } label: { Image(systemName: "eye") }.help("Быстрый просмотр")
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: attachment.path)]) } label: { Image(systemName: "folder") }.help("Показать в Finder")
                            Button { NSWorkspace.shared.open(URL(fileURLWithPath: attachment.path)) } label: { Image(systemName: "arrow.up.forward.square") }.help("Открыть")
                        }.buttonStyle(.borderless).padding(14).agentCard(cornerRadius: 18)
                    }
                }
            }
            if let id = message.undoID {
                Button { store.undoAction(id, chatID: chatID, messageID: message.id) } label: { Label("Отменить действие", systemImage: "arrow.uturn.backward") }.buttonStyle(.borderless).font(.system(size: 12)).disabled(store.busy)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).quickLookPreview($preview)
    }
}

struct MarkdownMessageBody: View {
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
                        HStack { Text(block.language.isEmpty ? "Код" : block.language).foregroundStyle(.secondary); Spacer(); Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(block.text, forType: .string) } label: { Label("Копировать", systemImage: "doc.on.doc") }.buttonStyle(.borderless) }.font(.system(size: 11)).padding(10)
                        Divider()
                        ScrollView(.horizontal) { Text(block.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(13).frame(maxWidth: .infinity, alignment: .leading) }
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
            rich(String(line.dropFirst(hashes + 1))).font(.system(size: hashes == 1 ? 24 : hashes == 2 ? 20 : 16, weight: .semibold)).padding(.top, 7)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 9) { Text("•"); rich(String(line.dropFirst(2))) }.font(.system(size: 14)).padding(.leading, 4)
        } else if line.hasPrefix("> ") {
            HStack { Rectangle().fill(.secondary.opacity(0.3)).frame(width: 3); rich(String(line.dropFirst(2))).foregroundStyle(.secondary) }.fixedSize(horizontal: false, vertical: true)
        } else { rich(line.isEmpty ? " " : line).font(.system(size: 14)).lineSpacing(4) }
    }
    private func rich(_ value: String) -> Text {
        Text((try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(value))
    }
}
