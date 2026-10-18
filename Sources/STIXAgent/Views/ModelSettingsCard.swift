import SwiftUI

/// A live view of saved preferences: reopening an old card never restores stale values.
struct ModelSettingsCard: View {
    @EnvironmentObject var store: AppStore
    let chatID: UUID
    @State private var refreshing = false
    private let tasks = [
        ("writing", "Текст", "text.alignleft"),
        ("coding", "Код", "chevron.left.forwardslash.chevron.right"),
        ("reasoning", "Анализ текста и кода", "brain"),
        ("vision", "Анализ изображений", "eye"),
        ("general", "Другие задачи", "sparkles")
    ]
    private var chat: Chat? { store.chats.first { $0.id == chatID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Модели для задач", systemImage: "square.stack.3d.up").font(.headline)
                Spacer()
                Button {
                    refreshing = true
                    Task { await store.refreshServices(); refreshing = false }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(refreshing)
                    .help("Обновить модели LM Studio и ComfyUI")
            }
            Text("Основная модель управляет задачей и обращается к выбранным специалистам при необходимости. Назначения действуют во всех чатах.")
                .foregroundStyle(.secondary).font(.subheadline)
            ForEach(tasks, id: \.0) { role, title, icon in
                VStack(alignment: .leading, spacing: 5) {
                    Picker(selection: Binding(get: { store.preferences.modelRoles?[role] ?? "auto" }, set: { value in
                        do { _ = try store.configureModelRole(.object(["role": .string(role), "model_id": .string(value)])) }
                        catch { store.error = error.localizedDescription }
                    })) {
                        Text("Автоматически").tag("auto")
                        modelOptions(selected: store.preferences.modelRoles?[role])
                    } label: { Label(title, systemImage: icon).frame(width: 185, alignment: .leading) }
                    if store.preferences.modelRoles?[role] == nil {
                        Text("Сейчас: \(store.specialistAssignments(configured: [:])[role] ?? "нет доступной модели")")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            Divider()
            Text("Изображения · этот чат").font(.subheadline.weight(.medium))
            Picker(selection: Binding(get: { chat?.imagePromptModel ?? "" }, set: { store.setTaskImageModel($0, prompt: true, chatID: chatID) })) {
                Text("Основная модель чата").tag("")
                modelOptions(selected: chat?.imagePromptModel)
            } label: { Label("Подготовка промпта", systemImage: "text.bubble").frame(width: 185, alignment: .leading) }
            Picker(selection: Binding(get: { chat?.imageModel ?? "" }, set: { store.setTaskImageModel($0, prompt: false, chatID: chatID) })) {
                if let selected = chat?.imageModel, !store.checkpoints.contains(selected),
                   !store.preferences.imageProfiles.contains(where: { "workflow:" + $0.id == selected }) {
                    Text("\(selected) · недоступна").tag(selected)
                }
                ForEach(store.preferences.imageProfiles) { profile in Text(profile.name).tag("workflow:" + profile.id) }
                ForEach(store.checkpoints, id: \.self) { Text($0).tag($0) }
            } label: { Label("Генерация и правки", systemImage: "photo").frame(width: 185, alignment: .leading) }
            Text("Для точных правок используются выбранная модель ComfyUI, исходная картинка и при необходимости маска. Терминал, приложения, браузер и очередь — инструменты основной модели.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 5) {
                Image(systemName: "checkmark.circle")
                Text("Изменения сохраняются сразу на этом Mac")
            }.font(.caption).foregroundStyle(.secondary)
        }.padding(20).agentCard(cornerRadius: 22)
    }
    @ViewBuilder private func modelOptions(selected: String?) -> some View {
        if let selected, !selected.isEmpty, !store.models.contains(where: { $0.id == selected }) {
            Text("\(selected) · недоступна").tag(selected)
        }
        ForEach(store.models) { model in Text(model.id).tag(model.id) }
    }
}

extension AppStore {
    func showModelSettings(chatID: UUID) {
        guard index(chatID) != nil else { return }
        addMessage(.init(role: "model_settings", text: "Модели для задач · назначения специалистов и модели изображений"), to: chatID)
    }
    func setTaskImageModel(_ model: String, prompt: Bool, chatID: UUID) {
        guard let i = index(chatID) else { return }
        let valid = prompt ? (model.isEmpty || models.contains { $0.id == model })
            : (checkpoints.contains(model) || preferences.imageProfiles.contains { "workflow:" + $0.id == model })
        guard valid else {
            error = "Модель отсутствует в текущем списке. Обновите список моделей."; return
        }
        if prompt { chats[i].imagePromptModel = model.isEmpty ? nil : model }
        else { chats[i].imageModel = model }
        save()
    }
}
