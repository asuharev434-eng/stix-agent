import SwiftUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var store: AppStore
    @State private var visibility: NavigationSplitViewVisibility = .all
    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("STIX").font(.system(size: 16, weight: .semibold)).tracking(2)
                    Spacer()
                    Button { store.newChat() } label: { Image(systemName: "square.and.pencil").font(.system(size: 16)) }
                        .buttonStyle(.plain).help("Новый чат · ⌘N").accessibilityLabel("Новый чат")
                }.padding(.horizontal, 18).padding(.top, 25)
                Button { store.chooseFiles(folderOnly: true, createChat: true) } label: {
                    Label("Чат с папкой", systemImage: "folder.badge.plus").font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }.buttonStyle(.plain).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9)).padding(.horizontal, 10)
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(store.chats) { chat in
                            SidebarChatRow(chat: chat)
                        }
                    }.padding(.horizontal, 10)
                }
                HStack(spacing: 7) {
                    Image(systemName: "desktopcomputer")
                    Text("Локально на этом Mac")
                }.font(.system(size: 11)).tracking(0.2).foregroundStyle(.secondary).padding(18)
            }.background(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Text(store.currentChat?.title ?? "Новый чат").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if let folder = store.currentChat?.folder {
                        Button { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) } label: { Label(URL(fileURLWithPath: folder).lastPathComponent, systemImage: "folder").lineLimit(1) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 28).frame(height: 50)
                if let chat = store.currentChat {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 24) {
                                if chat.messages.isEmpty { emptyState }
                                ForEach(chat.messages) { message in
                                    MessageView(message: message, chatID: chat.id).id(message.id)
                                }
                                if store.pendingHere, let request = store.pending { InteractionView(request: request).id(request.id) }
                                Color.clear.frame(height: 1).id("bottom")
                            }.frame(maxWidth: 780).frame(maxWidth: .infinity).padding(.horizontal, 30).padding(.top, 30).padding(.bottom, 20)
                        }
                        .onChange(of: chat.messages.count) { _, _ in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                        .onChange(of: store.pending?.id) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                        .onChange(of: store.selectedID) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                if store.busy, store.activeChatID == store.selectedID {
                    HStack(spacing: 8) { ProgressView().controlSize(.mini); Text(store.activity).font(.system(size: 12)).foregroundStyle(.secondary); Spacer() }.frame(maxWidth: 750).padding(.horizontal, 30).padding(.bottom, 10)
                }
                ComposerView().frame(maxWidth: 820).padding(.horizontal, 25).padding(.bottom, 20)
            }.background(Color(nsColor: .textBackgroundColor))
                .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                    for provider in providers {
                        _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in store.addFiles([url]) } } }
                    }; return true
                }
        }.alert("STIX Agent", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("Понятно") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "asterisk").font(.system(size: 30, weight: .medium)).padding(.bottom, 8)
            Text("Что сделаем?").font(.system(size: 30, weight: .medium))
            Text("Файлы, небольшой код, повседневные задачи.\nВсё начинается с сообщения.").font(.system(size: 15)).foregroundStyle(.secondary).lineSpacing(5)
            HStack(spacing: 8) {
                suggestion("Разобрать папку", icon: "folder", prompt: "Помоги рассортировать файлы в папке")
                suggestion("Написать скрипт", icon: "chevron.left.forwardslash.chevron.right", prompt: "Помоги написать небольшой скрипт")
                suggestion("Создать картинку", icon: "photo", prompt: "/image ")
            }.padding(.top, 12)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 70)
    }
    private func suggestion(_ label: String, icon: String, prompt: String) -> some View {
        Button { store.draft = prompt } label: { Label(label, systemImage: icon).font(.system(size: 12)).padding(.horizontal, 11).padding(.vertical, 9) }
            .buttonStyle(.plain).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct SidebarChatRow: View {
    @EnvironmentObject var store: AppStore
    let chat: Chat
    var body: some View {
        Button { store.selectChat(chat.id) } label: {
            HStack(spacing: 9) {
                Image(systemName: chat.folder == nil ? "bubble.left" : "folder").font(.system(size: 12)).foregroundStyle(.secondary)
                Text(chat.title).font(.system(size: 13)).lineLimit(1)
                Spacer(minLength: 0)
                if chat.id == store.activeChatID { ProgressView().controlSize(.mini) }
            }.padding(.horizontal, 10).padding(.vertical, 11).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .background(store.selectedID == chat.id ? Color.primary.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
            .contextMenu {
                Button("Удалить чат", role: .destructive) { store.deleteChat(chat.id) }
                if let folder = chat.folder { Button("Показать папку") { NSWorkspace.shared.open(URL(fileURLWithPath: folder)) } }
            }
    }
}
