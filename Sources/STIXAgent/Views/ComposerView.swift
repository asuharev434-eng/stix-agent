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
            if imageMode { imagePromptModelControl }
            footer
            HStack(spacing: 14) {
                questionControl
                Divider().frame(height: 14)
                Toggle("Thinking", isOn: thinkingBinding).toggleStyle(.switch).controlSize(.mini)
                    .font(.system(size: store.textSize(11)))
                    .help("Показывать рассуждения модели во время ответа")
            }
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
                            }.font(.system(size: store.textSize(12))).padding(8).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                }.frame(height: 38)
            }
    }
    private var editor: some View {
            ZStack(alignment: .topLeading) {
                if store.draft.isEmpty {
                    Text(store.pendingHere && store.pending?.kind == .question ? "Ответ агенту…" : "Задача, вопрос или /image…").foregroundStyle(.tertiary).font(.system(size: store.textSize(15))).padding(.leading, 5).padding(.top, 1).allowsHitTesting(false)
                }
                TextEditor(text: $store.draft).font(.system(size: store.textSize(15))).scrollContentBackground(.hidden)
                    .frame(height: min(150, max(48, CGFloat(store.draft.components(separatedBy: "\n").count + store.draft.count / 85) * store.textSize(22)))).focused($focused)
                    .disabled(store.pendingHere && store.pending?.kind == .secret)
                    .onKeyPress(.return, phases: .down) { key in
                        if key.modifiers.contains(.shift) { return .ignored }
                        store.send()
                        return .handled
                    }
            }
    }
    private var imagePromptModelControl: some View {
        HStack(spacing: 9) {
            Text("Текстовая модель").font(.system(size: store.textSize(11))).foregroundStyle(.secondary)
            Menu {
                Button("Как в чате") {
                    guard let id = store.selectedID, let index = store.index(id) else { return }
                    store.chats[index].imagePromptModel = nil; store.save()
                }
                ForEach(store.models) { model in
                    Button(model.id) {
                        guard let id = store.selectedID, let index = store.index(id) else { return }
                        store.chats[index].imagePromptModel = model.id; store.save()
                    }
                }
                if store.models.isEmpty { Text("Запустите локальный API LM Studio") }
            } label: {
                let selected = store.currentChat?.imagePromptModel ?? store.currentChat?.model ?? ""
                HStack(spacing: 6) {
                    Image(systemName: "text.bubble")
                    Text(selected.isEmpty ? "Выбрать модель" : selected.split(separator: "/").last.map(String.init) ?? selected).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: store.textSize(8), weight: .semibold))
                }.font(.system(size: store.textSize(12), weight: .medium))
            }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.primary.opacity(0.045), in: Capsule()).frame(maxWidth: 360, alignment: .leading)
                .help("Локальная языковая модель переводит и адаптирует описание перед генерацией изображения")
            Spacer(minLength: 0)
        }
    }
    private var thinkingBinding: Binding<Bool> {
        Binding(get: { store.preferences.thinking ?? false }, set: { enabled in
            store.preferences.thinking = enabled
            if !enabled { store.reasoningText = "" }
            store.save()
        })
    }
    private var questionLabels: [String] {
        ["Без доп. вопросов", "Минимум", "По необходимости", "Уточнить детали", "Подробное интервью"]
    }
    private var questionLevel: Int {
        min(4, max(0, store.currentChat?.questionLevel ?? store.preferences.questionLevel ?? 1))
    }
    private var questionBinding: Binding<Double> {
        Binding(get: { Double(questionLevel) }, set: { value in
            guard value.isFinite else { return }
            let level = Int(min(4, max(0, value.rounded())))
            store.preferences.questionLevel = level
            if let id = store.selectedID, let index = store.index(id) { store.chats[index].questionLevel = level }
            store.save()
        })
    }
    private var questionControl: some View {
        HStack(spacing: 9) {
            Image(systemName: "bubble.left.and.bubble.right").accessibilityHidden(true)
            Text("Уточнения: \(questionLabels[questionLevel])").lineLimit(1)
            Spacer(minLength: 6)
            Slider(value: questionBinding, in: 0...4, step: 1)
                .controlSize(.mini).frame(width: 120)
                .accessibilityLabel("Дополнительные вопросы")
                .accessibilityValue(questionLabels[questionLevel])
        }.font(.system(size: store.textSize(11))).foregroundStyle(.secondary)
            .help("От «Без доп. вопросов» до «Подробное интервью». Задаёт количество уточнений для новых задач; разрешения и защищённый ввод остаются отдельными.")
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
                    HStack(spacing: 5) { Image(systemName: imageMode ? "photo" : "circle.hexagongrid"); Text(imageMode ? "Изображение · " + modelName : modelName).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: store.textSize(8), weight: .semibold)) }.font(.system(size: store.textSize(12), weight: .medium))
                }.menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 10).padding(.vertical, 7)
                    .background(.primary.opacity(0.045), in: Capsule()).frame(maxWidth: 330, alignment: .leading).help("Модель")
                Spacer(minLength: 5)
                Button { store.chooseFiles() } label: { Image(systemName: "plus").font(.system(size: store.textSize(17))).frame(width: 30, height: 30).contentShape(Circle()) }.buttonStyle(.plain).help("Добавить файлы или папку").accessibilityLabel("Добавить файлы")
                Menu {
                    Button("Показать плагины") { store.draft = "/plugins"; store.send() }
                    Button("Добавить MCP-плагин") { store.draft = "Хочу добавить MCP-плагин. Спроси команду запуска или URL."; focused = true }
                    Button("Подключить API") { store.draft = "Хочу подключить API внешнего сервиса. Спроси название и адрес, затем запроси ключ через защищённую форму."; focused = true }
                } label: { Image(systemName: "puzzlepiece.extension").font(.system(size: store.textSize(15))) }.menuStyle(.borderlessButton).fixedSize().help("Плагины и API")
                if store.busy && !(store.pendingHere && store.pending?.kind == .question) {
                    Button { store.stop() } label: { Image(systemName: "stop.fill").font(.system(size: store.textSize(12))).frame(width: 34, height: 34) }.buttonStyle(.plain).background(.primary.opacity(0.09), in: Circle()).help("Остановить · ⌘.").accessibilityLabel("Остановить")
                }
                Button { store.send() } label: { Image(systemName: "arrow.up").font(.system(size: store.textSize(15), weight: .semibold)).foregroundStyle(Color(nsColor: .textBackgroundColor)).frame(width: 34, height: 34) }.buttonStyle(.plain).background(Color.primary, in: Circle()).disabled(store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && store.attachments.isEmpty).help("Отправить · Return").accessibilityLabel(store.busy ? "Добавить в очередь" : "Отправить")
            }
    }
}
