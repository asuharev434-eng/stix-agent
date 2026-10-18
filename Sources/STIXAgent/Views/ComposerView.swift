import SwiftUI

struct ComposerView: View {
    @EnvironmentObject var store: AppStore
    @FocusState private var focused: Bool
    var imageMode: Bool { store.draft.hasPrefix("/image") }
    var modelName: String {
        if imageMode {
            let id = store.currentChat?.imageModel ?? "SDXL"
            return store.preferences.imageProfiles.first(where: { "workflow:" + $0.id == id })?.name ?? id
        }
        let id = store.currentChat?.model ?? ""
        return id.isEmpty ? "Выбрать модель" : id.split(separator: "/").last.map(String.init) ?? id
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            attachmentsRow
            editor
            footer
        }.padding(18).agentGlass(cornerRadius: 28)
            .onAppear { focused = true }
    }
    @ViewBuilder private var attachmentsRow: some View {
            if !store.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(store.attachments) { item in
                            HStack(spacing: 6) {
                                Image(systemName: item.kind == "folder" ? "folder" : item.kind == "image" ? "photo" : "doc")
                                Text(item.name).lineLimit(1)
                                Button { store.attachments.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain).accessibilityLabel("Убрать \(item.name)")
                            }.font(.system(size: 12)).padding(8).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }.frame(height: 38)
            }
    }
    private var editor: some View {
            ZStack(alignment: .topLeading) {
                if store.draft.isEmpty {
                    Text(store.pendingHere && store.pending?.kind == .question ? "Ответ агенту…" : "Задача, вопрос или /image…").foregroundStyle(.tertiary).font(.system(size: 15)).padding(.leading, 5).allowsHitTesting(false)
                }
                TextEditor(text: $store.draft).font(.system(size: 15)).scrollContentBackground(.hidden)
                    .frame(height: min(150, max(48, CGFloat(store.draft.components(separatedBy: "\n").count + store.draft.count / 85) * 22))).focused($focused)
                    .disabled(store.pendingHere && store.pending?.kind == .secret)
                    .onKeyPress(.return, phases: .down) { key in
                        if key.modifiers.contains(.shift) { return .ignored }
                        if !store.busy || (store.pendingHere && store.pending?.kind == .question) { store.send() }
                        return .handled
                    }
            }
    }
    private var footer: some View {
            HStack(spacing: 12) {
                Menu {
                    if imageMode {
                        ForEach(store.preferences.imageProfiles) { profile in Button(profile.name) { store.setModel("workflow:" + profile.id, image: true) } }
                        ForEach(store.checkpoints, id: \.self) { name in Button(name) { store.setModel(name, image: true) } }
                        if store.checkpoints.isEmpty { Text("ComfyUI недоступен") }
                    } else {
                        ForEach(store.models) { model in Button(model.id) { store.setModel(model.id, image: false) } }
                        if store.models.isEmpty { Text("Запустите локальный API LM Studio") }
                    }
                    Divider()
                    Button("Обновить модели") { Task { await store.refreshServices() } }
                } label: {
                    HStack(spacing: 5) { Image(systemName: imageMode ? "photo" : "circle.hexagongrid"); Text(modelName).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }.font(.system(size: 12, weight: .medium))
                }.menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.primary.opacity(0.045), in: Capsule()).frame(maxWidth: 330, alignment: .leading).help("Модель")
                Spacer(minLength: 5)
                Button { store.chooseFiles() } label: { Image(systemName: "plus").font(.system(size: 17)).frame(width: 30, height: 30).contentShape(Circle()) }.buttonStyle(.plain).help("Добавить файлы или папку").accessibilityLabel("Добавить файлы")
                Menu {
                    Button("Показать плагины") { store.draft = "/plugins"; store.send() }
                    Button("Добавить MCP-плагин") { store.draft = "Хочу добавить MCP-плагин. Спроси команду запуска или URL."; focused = true }
                    Button("Подключить API") { store.draft = "Хочу подключить API внешнего сервиса. Спроси название и адрес, затем запроси ключ через защищённую форму."; focused = true }
                } label: { Image(systemName: "puzzlepiece.extension").font(.system(size: 15)) }.menuStyle(.borderlessButton).fixedSize().help("Плагины и API")
                if store.busy && !(store.pendingHere && store.pending?.kind == .question) {
                    Button { store.stop() } label: { Image(systemName: "stop.fill").font(.system(size: 12)).frame(width: 34, height: 34) }.buttonStyle(.plain).background(.primary.opacity(0.09), in: Circle()).help("Остановить · ⌘.").accessibilityLabel("Остановить")
                } else {
                    Button { store.send() } label: { Image(systemName: "arrow.up").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(nsColor: .textBackgroundColor)).frame(width: 34, height: 34) }.buttonStyle(.plain).background(Color.primary, in: Circle()).disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.attachments.isEmpty).help("Отправить · Return").accessibilityLabel("Отправить")
                }
            }
    }
}
