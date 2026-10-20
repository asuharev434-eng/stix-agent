import SwiftUI

struct RemoteChatView: View {
    @EnvironmentObject private var store: RemoteChatStore
    @State private var showCommands = false
    @State private var imageSaveAlert: String?
    @FocusState private var composerFocused: Bool

    private var commandMatches: [RemoteCommand] {
        guard store.draft.hasPrefix("/"), !store.draft.contains("\n"), store.draft.count < 100 else { return [] }
        let search = store.draft.lowercased()
        let available = store.offlineMode ? [
            RemoteCommand(command: "/help", title: "Локальные возможности", detail: "Что работает на iPhone")
        ] : (store.snapshot?.commands ?? [])
        return available.filter {
            $0.command.lowercased().hasPrefix(search) || $0.title.lowercased().contains(String(search.dropFirst()))
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                deviceSelector
                if store.offlineMode {
                    HStack(spacing: 8) {
                        Image(systemName: "iphone")
                        Text("Локально на iPhone · \(LocalLlamaEngine.modelName)")
                        Spacer()
                    }.font(.caption).padding(12).background(.blue.opacity(0.08))
                } else if !store.connected {
                    Button {
                        store.useOfflineMode()
                    } label: {
                        Label("Mac не в сети · работать на iPhone", systemImage: "iphone")
                    }.font(.caption).padding(12).frame(maxWidth: .infinity)
                }
                if let error = store.error {
                    HStack(spacing: 8) {
                        Image(systemName: "wifi.exclamationmark")
                        Text(error).lineLimit(2)
                        Spacer()
                        if !store.offlineMode {
                            Button("Повторить") { Task { await store.refresh() } }
                        }
                    }.font(.caption).padding(12).background(.orange.opacity(0.12))
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            if store.displayMessages.isEmpty {
                                emptyState
                            }
                            ForEach(store.displayMessages) { message in
                                messageView(message).id(message.id)
                            }
                            if !store.offlineMode, let interaction = store.snapshot?.interaction {
                                interactionView(interaction).id(interaction.id)
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }.padding(.horizontal, 16).padding(.vertical, 24)
                    }
                    .onChange(of: store.displayMessages.count) { _, _ in
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    .onChange(of: store.snapshot?.interaction?.id) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }
                if store.localWorking {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Локальная модель отвечает…", systemImage: "iphone")
                            .font(.caption).foregroundStyle(.secondary)
                        ProgressView()
                    }.padding(.horizontal, 18).padding(.vertical, 10)
                } else if !store.offlineMode,
                          let job = store.snapshot?.jobs.last(where: { ["running", "queued"].contains($0.status) }) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "sparkles")
                            Text(job.phase ?? (job.status == "queued" ? "В очереди" : "Работает"))
                            Spacer()
                            if let progress = job.progress { Text(progress, format: .percent.precision(.fractionLength(0))) }
                        }.font(.caption).foregroundStyle(.secondary)
                        if let progress = job.progress { ProgressView(value: progress) }
                        else { ProgressView().tint(.blue) }
                    }.padding(.horizontal, 18).padding(.vertical, 10)
                }
                if !commandMatches.isEmpty {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(commandMatches) { command in
                                Button {
                                    store.draft = command.command + (command.command == "/image" || command.command.hasPrefix("/plugin/") ? " " : "")
                                    if !store.draft.hasSuffix(" ") { Task { await store.send() } }
                                    composerFocused = true
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(command.title).font(.subheadline.weight(.medium))
                                            Text(command.detail).font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Text(command.command).font(.caption.monospaced()).foregroundStyle(.secondary)
                                    }.padding(12)
                                }.buttonStyle(.plain)
                            }
                        }
                    }.frame(maxHeight: 230).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 14)
                }
                composer
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("STIX")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if store.isPaired && !store.offlineMode {
                            Button("Обновить Mac", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                        }
                        if store.isPaired {
                            Button("Отключить Mac", systemImage: "iphone.slash", role: .destructive) { store.disconnect() }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .alert("Сохранение изображения", isPresented: Binding(
                get: { imageSaveAlert != nil },
                set: { if !$0 { imageSaveAlert = nil } }
            )) {
                Button("Понятно", role: .cancel) { imageSaveAlert = nil }
            } message: {
                Text(imageSaveAlert ?? "")
            }
        }
    }

    private var deviceSelector: some View {
        HStack(spacing: 4) {
            deviceButton("iPhone", icon: "iphone", selected: store.offlineMode) {
                store.useOfflineMode()
            }
            deviceButton("MacBook", icon: "laptopcomputer", selected: !store.offlineMode) {
                Task { await store.useMacMode() }
            }
        }
        .padding(4)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .accessibilityLabel("Выбор устройства для ответа")
    }

    private func deviceButton(_ title: String, icon: String, selected: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(selected ? Color(uiColor: .secondarySystemGroupedBackground) : .clear,
                            in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "sparkle").font(.largeTitle).padding(.bottom, 10)
            Text("Что сделаем?").font(.largeTitle.weight(.medium))
            Text(store.offlineMode ? "Локальная модель отвечает без Mac и интернета. Для команд и изображений выберите MacBook." : "Чат с вашим Mac. Попросите агента выполнить задачу или введите / для команд.")
                .foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 80)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if store.offlineMode {
                    Label(LocalLlamaEngine.modelName, systemImage: "iphone")
                        .font(.caption.weight(.medium)).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Label("Фото — через Mac", systemImage: "photo")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    modelMenu(image: false).frame(maxWidth: .infinity)
                    modelMenu(image: true).frame(maxWidth: .infinity)
                }
            }
            if !store.offlineMode && store.draft.hasPrefix("/image") { imagePromptMenu }
            HStack(alignment: .bottom, spacing: 10) {
                TextField(store.offlineMode ? "Вопрос для iPhone…" : "Задача, вопрос или /image…", text: $store.draft, axis: .vertical)
                    .lineLimit(1...6).focused($composerFocused).submitLabel(.send)
                    .onSubmit { Task { await store.send() } }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
                Button { Task { await store.send() } } label: {
                    Image(systemName: "arrow.up").font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white).frame(width: 42, height: 42)
                        .background(.black, in: Circle())
                }.disabled(store.sending || store.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(.horizontal, 14).padding(.vertical, 10)
            .background(.regularMaterial)
    }

    private func modelMenu(image: Bool) -> some View {
        let choices = image ? (store.snapshot?.imageModels ?? []) : (store.snapshot?.models ?? [])
        let name = choices.first(where: \.selected)?.name ?? (image ? "Модель фото" : "Модель текста")
        return Menu {
            ForEach(choices) { model in
                Button(model.name, systemImage: model.selected ? "checkmark" : "circle") {
                    Task { await store.selectModel(model.id, image: image) }
                }
            }
            if choices.isEmpty { Text("Модели на Mac не найдены") }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: image ? "photo" : "circle.hexagongrid")
                Text(name).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }.font(.caption.weight(.medium)).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
        }.accessibilityLabel(image ? "Модель изображений" : "Текстовая модель")
    }

    private var imagePromptMenu: some View {
        Menu {
            Button("Автоматически", systemImage: store.snapshot?.imagePromptModelID == nil ? "checkmark" : "circle") {
                Task { await store.selectImagePromptModel(nil) }
            }
            ForEach((store.snapshot?.models ?? []).filter { $0.supportsImagePrompt != false }) { model in
                Button(model.name, systemImage: store.snapshot?.imagePromptModelID == model.id ? "checkmark" : "circle") {
                    Task { await store.selectImagePromptModel(model.id) }
                }
            }
        } label: {
            Label("Промпт: " + (store.snapshot?.models.first(where: { $0.id == store.snapshot?.imagePromptModelID })?.name ?? "Авто"),
                  systemImage: "text.bubble")
                .lineLimit(1).font(.caption.weight(.medium))
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
        }.accessibilityLabel("Текстовая модель для изображения")
    }

    private func messageView(_ message: RemoteMessage) -> some View {
        VStack(alignment: message.role == "user" ? .trailing : .leading, spacing: 8) {
            if message.role == "model_settings" {
                modelSelector
            } else if message.role == "tool" {
                Label(message.text, systemImage: message.status == "running" ? "hourglass" : "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            } else if message.role == "user" {
                Text(message.text).font(.body).padding(13)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 19))
            } else {
                Text(.init(message.text)).font(.body).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(message.attachments) { attachment in
                if let image = store.images[attachment.id] {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(maxWidth: 340, maxHeight: 360).clipShape(RoundedRectangle(cornerRadius: 16))
                        Button {
                            Task {
                                do {
                                    try await store.saveImage(attachment.id)
                                    imageSaveAlert = "Изображение добавлено в приложение «Фото»."
                                } catch {
                                    imageSaveAlert = error.localizedDescription
                                }
                            }
                        } label: {
                            Label("Сохранить в Фото", systemImage: "square.and.arrow.down")
                        }.buttonStyle(.bordered)
                    }
                } else {
                    Label(attachment.name, systemImage: attachment.kind == "image" ? "photo" : "doc")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if message.status == "offline" {
                Label("На iPhone", systemImage: "iphone")
                    .font(.caption2).foregroundStyle(.secondary)
            } else if message.status == "not_sent" {
                Label("Не отправлено · выберите MacBook и отправьте заново", systemImage: "exclamationmark.circle")
                    .font(.caption2).foregroundStyle(.orange)
            }
        }.frame(maxWidth: .infinity, alignment: message.role == "user" ? .trailing : .leading)
    }

    private var modelSelector: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Модели этого чата", systemImage: "square.stack.3d.up").font(.headline)
            Menu {
                ForEach(store.snapshot?.models ?? []) { model in
                    Button(model.name, systemImage: model.selected ? "checkmark" : "circle") {
                        Task { await store.selectModel(model.id, image: false) }
                    }
                }
            } label: {
                Label(store.snapshot?.models.first(where: \.selected)?.name ?? "Текстовая модель", systemImage: "text.bubble")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Menu {
                ForEach(store.snapshot?.imageModels ?? []) { model in
                    Button(model.name, systemImage: model.selected ? "checkmark" : "circle") {
                        Task { await store.selectModel(model.id, image: true) }
                    }
                }
            } label: {
                Label(store.snapshot?.imageModels.first(where: \.selected)?.name ?? "Модель изображений", systemImage: "photo")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            imagePromptMenu
        }.padding(16).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func interactionView(_ interaction: RemoteInteraction) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(interaction.title, systemImage: interaction.kind == "secret" ? "lock.shield" : "bubble.left.and.bubble.right")
                .font(.headline)
            if !interaction.detail.isEmpty { Text(interaction.detail).font(.subheadline).foregroundStyle(.secondary) }
            if interaction.kind == "approval" {
                ForEach([("Выполнить", "once"), ("Для этой задачи", "task"),
                         ("Всегда для действия", "always"), ("Отменить", "deny")], id: \.1) { title, value in
                    Button(title) { Task { await store.answer(value, interaction: interaction) } }
                        .buttonStyle(.borderedProminent)
                }
            } else if interaction.kind == "secret" {
                SecretAnswerView(interaction: interaction)
            } else {
                ForEach(interaction.choices, id: \.self) { option in
                    Button(option) { Task { await store.answer(option, interaction: interaction) } }.buttonStyle(.bordered)
                }
                QuestionAnswerView(interaction: interaction)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }
}

private struct QuestionAnswerView: View {
    @EnvironmentObject private var store: RemoteChatStore
    let interaction: RemoteInteraction
    @State private var answer = ""
    var body: some View {
        HStack {
            TextField("Ответ агенту", text: $answer)
            Button("Ответить") { let text = answer; answer = ""; Task { await store.answer(text, interaction: interaction) } }
                .disabled(answer.isEmpty)
        }
    }
}

private struct SecretAnswerView: View {
    @EnvironmentObject private var store: RemoteChatStore
    let interaction: RemoteInteraction
    @State private var secret = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField("Ключ или пароль", text: $secret).textContentType(.password).privacySensitive()
            Button("Сохранить в Keychain Mac") {
                let value = secret; secret = ""
                Task { await store.answer(value, interaction: interaction) }
            }.disabled(secret.isEmpty).buttonStyle(.borderedProminent)
            Text("Ключ не появится в переписке.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
