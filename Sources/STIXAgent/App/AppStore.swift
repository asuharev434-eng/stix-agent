import SwiftUI
import AppKit
import ApplicationServices
import UniformTypeIdentifiers

@MainActor
final class AppStore: ObservableObject {
    @Published var features = FeatureConfiguration()
    @Published var jobs: [AgentJob] = []
    var activeJobID: UUID?
    @Published var chats: [Chat] = []
    @Published var selectedID: UUID?
    @Published var preferences = AppPreferences()
    @Published var memoryEntries: [MemoryEntry] = []
    @Published var memoryRevisions: [MemoryRevision] = []
    @Published var requestSnapshots: [UUID: ContextRequestSnapshot] = [:]
    @Published var projects: [MemoryProject] = []
    @Published var models: [ModelDescriptor] = []
    @Published var importedModels: [ImportedGGUF] = []
    @Published var importedMLXModels: [ImportedMLXModel] = []
    @Published var importedImageModels: [ImportedImageCheckpoint] = []
    @Published var skills: [LocalSkill] = []
    @Published var focusedMessageID: UUID?
    @Published var checkpoints: [String] = []
    @Published var draft = ""
    @Published var attachments: [Attachment] = []
    @Published var busy = false
    @Published var compactingChatID: UUID?
    @Published var pendingCompactionChatID: UUID?
    @Published var contextNotices: [UUID: String] = [:]
    var contextAutoFailures: [UUID: String] = [:]
    @Published var liveContextLimits: [String: Int] = [:]
    @Published var activity = ""
    @Published var reasoningText = ""
    var transientReasoning = ""
    @Published var pending: PendingInteraction?
    @Published var error: String?
    @Published var pluginTools: [String: [ToolDefinition]] = [:]
    let storage: StateStorage
    let vault = SecretVault()
    let processRunner = ProcessRunner()
    lazy var computerTools = ComputerTools(captureDirectory: storage.paths.attachments)
    var plugins: [String: MCPClient] = [:]
    lazy var builtInTextEngine = LocalModelLibrary.live(paths: storage.paths)
    lazy var localMLXEngine = LocalMLXTextEngine.bundled(paths: storage.paths)
    lazy var builtInImageEngine = CoreMLImageEngine.bundled()
    lazy var localImageEngine = LocalCheckpointImageEngine.bundled(paths: storage.paths)
    var inferenceRegistry: InferenceRegistry {
        InferenceRegistry(lmEndpoint: preferences.lmEndpoint, comfyEndpoint: preferences.comfyEndpoint,
                          builtInText: builtInTextEngine, builtInImage: builtInImageEngine,
                          localCheckpoint: localImageEngine, localMLX: localMLXEngine)
    }
    var activeChatID: UUID?
    var task: Task<Void, Never>?
    var continuation: CheckedContinuation<InteractionAnswer, Never>?
    var taskApprovals: Set<String> = []
    var exposedToolNames: Set<String> = []
    var undos: [UUID: UndoRecord] = [:]
    var streamedText: [UUID: String] = [:]
    var undoing: Set<UUID> = []
    @Published var needsFeatureRelaunch = false
    @Published var featureNotice: String?
    var featureMonitor: Task<Void,Never>?
    var featureMaintenanceBusy = false
    var booting = false
    lazy var documentIndex = LocalDocumentIndex(paths: storage.paths)
    var canPersist = true

    init(storage: StateStorage = StateStorage()) {
        self.storage = storage
        do {
            if let state = try storage.load() {
                features = state.features ?? FeatureConfiguration()
                jobs = state.jobs ?? []
                for i in jobs.indices where jobs[i].status == "running" || (jobs[i].status == "queued" && jobs[i].started == true) { jobs[i].status = "interrupted" }
                chats = state.chats; preferences = state.preferences; memoryEntries = state.memoryEntries ?? []; projects = state.projects ?? []; memoryRevisions = state.memoryRevisions ?? []; undos = Dictionary(uniqueKeysWithValues: state.undos.map { ($0.id, $0) })
                for i in chats.indices {
                    let legacyInterrupted = chats[i].messages.contains(where: { $0.status == "running" })
                    if legacyInterrupted, !jobs.contains(where: { $0.chatID == chats[i].id && ["interrupted", "paused", "running", "queued"].contains($0.status) }), let input = chats[i].messages.last(where: { $0.role == "user" }) {
                        jobs.append(.init(chatID: chats[i].id, prompt: input.text, attachments: input.attachments, status: "interrupted", started: true, inputRecorded: !chats[i].history.isEmpty, sourceMessageID: input.id))
                    }
                    for j in chats[i].messages.indices where chats[i].messages[j].status == "running" {
                        chats[i].messages[j].status = "interrupted"
                        chats[i].messages[j].text += "\nПрервано при закрытии приложения."
                    }
                    for j in chats[i].messages.indices where chats[i].messages[j].role == "assistant" {
                        chats[i].messages[j].text = ModelOutput.clean(chats[i].messages[j].text)
                    }
                    for j in chats[i].history.indices where chats[i].history[j].role == "assistant" {
                        chats[i].history[j].content = chats[i].history[j].content.map(ModelOutput.clean)
                    }
                    // Incomplete tool groups are repaired rather than replayed on next startup.
                    repairHistory(&chats[i].history)
                }
            }
        } catch { self.error = "Не удалось прочитать историю: \(error.localizedDescription). Файл сохранён, запись остановлена."; canPersist = false }
        selectedID = chats.first?.id
        if chats.isEmpty { newChat() }
        draft = currentChat?.savedDraft ?? ""; attachments = currentChat?.draftAttachments ?? []
        do { try SkillLibrary(paths: storage.paths).seed(); reloadSkills() }
        catch { self.error = "Скиллы: \(error.localizedDescription)" }
        if canPersist { try? ChatSearchIndex(paths: storage.paths).synchronize(in: chats) }
        for connection in preferences.connections { if let value = try? vault.get(connection.id), connection.auth == "basic", let colon = value.firstIndex(of: ":") { vault.remember(String(value[value.index(after: colon)...])) } }
        for secret in preferences.secrets { _ = try? vault.get(secret.id) }
    }
    var currentChat: Chat? { chats.first { $0.id == selectedID } }
    var pendingHere: Bool { pending != nil && selectedID == activeChatID }
    var colorScheme: ColorScheme? { preferences.theme == "dark" ? .dark : preferences.theme == "light" ? .light : nil }
    func index(_ id: UUID) -> Int? { chats.firstIndex { $0.id == id } }
    func save() {
        guard canPersist else { return }
        if let id = selectedID, let i = index(id) { chats[i].savedDraft = vault.redact(draft); chats[i].draftAttachments = attachments }
        do { try synchronizeProjects(); try storage.save(persistedState()) }
        catch { self.error = "История не сохранена: \(error.localizedDescription). Запись остановлена; перезапустите приложение для восстановления журнала."; canPersist = false; task?.cancel() }
    }
    func newChat(folder: URL? = nil, mode: ChatMode = .agent) {
        preserveDraft()
        var chat = Chat(folder: folder?.path, model: preferences.defaultModel, mode: mode)
        if let imageModel = preferences.defaultImageModel { chat.imageModel = imageModel }
        chat.title = folder?.lastPathComponent ?? (mode == .clean ? "Чистый чат" : "Новый чат")
        chats.insert(chat, at: 0); selectedID = chat.id; draft = ""; attachments = []; save()
    }
    func preserveDraft() {
        if let id = selectedID, let i = index(id) { chats[i].savedDraft = vault.redact(draft); chats[i].draftAttachments = attachments }
    }
    func selectChat(_ id: UUID) {
        preserveDraft(); selectedID = id; draft = currentChat?.savedDraft ?? ""; attachments = currentChat?.draftAttachments ?? []; save()
    }
    func deleteChat(_ id: UUID) {
        guard id != activeChatID else { error = "Сначала остановите текущую задачу"; return }
        if pendingCompactionChatID == id { pendingCompactionChatID = nil }
        for i in jobs.indices where jobs[i].chatID == id { jobs[i].status = "cancelled" }
        chats.removeAll { $0.id == id }
        memoryEntries.removeAll { $0.scope == .chat && $0.ownerID == id }
        if selectedID == id { selectedID = chats.first?.id; draft = currentChat?.savedDraft ?? ""; attachments = currentChat?.draftAttachments ?? [] }
        if chats.isEmpty { newChat() }; save()
    }
    func setModel(_ model: String, image: Bool) {
        guard let id = selectedID, let i = index(id) else { return }
        if image { chats[i].imageModel = model }
        else { chats[i].model = model; preferences.defaultModel = model }
        save()
    }
    func imageModelName(_ id: String) -> String {
        if id.hasPrefix("builtin-image:") { return "Stable Diffusion 1.5 · встроенная" }
        if id.hasPrefix("local-image:") {
            return importedImageModels.first(where: { "local-image:" + $0.id == id })
                .map { $0.name + " · локальная" } ?? "Локальная модель недоступна"
        }
        return URL(fileURLWithPath: id).deletingPathExtension().lastPathComponent + " · ComfyUI"
    }
    private func externalImageChoices(_ choices: [String]) -> [String] {
        let importedNames = Set(importedImageModels.map { $0.name + ".safetensors" })
        return choices.filter { !importedNames.contains($0) }
    }
    func migrateInstalledModelSelections() {
        func textID(_ old: String) -> String? {
            guard !old.hasPrefix("builtin-text:"), !old.hasPrefix("mlx-text:") else { return nil }
            func normalized(_ value: String) -> String { value.lowercased().filter { $0.isLetter || $0.isNumber } }
            let name = normalized(old)
            if name.contains("qwen359b"), let model = importedMLXModels.first(where: { normalized($0.name).contains("qwen359b") }) {
                return "mlx-text:" + model.id
            }
            if name.contains("gptoss20b"), let model = importedMLXModels.first(where: { normalized($0.name).contains("gptoss20b") }) {
                return "mlx-text:" + model.id
            }
            if name.contains("qwen3coder30b"), let model = importedModels.first(where: { normalized($0.name).contains("qwen3coder30b") }) {
                return "builtin-text:" + model.id
            }
            if name.contains("qwen38babliterated"), let model = importedModels.first(where: { normalized($0.name).contains("qwen38babliterated") }) {
                return "builtin-text:" + model.id
            }
            if name.contains("gemma412b"), let model = importedModels.first(where: { normalized($0.name).contains("gemma412b") }) {
                return "builtin-text:" + model.id
            }
            return nil
        }
        func imageID(_ old: String) -> String? {
            guard !old.hasPrefix("local-image:"), !old.hasPrefix("builtin-image:"), !old.hasPrefix("workflow:") else { return nil }
            let name = URL(fileURLWithPath: old).deletingPathExtension().lastPathComponent
            return importedImageModels.first(where: { $0.name == name }).map { "local-image:" + $0.id }
        }
        if let migrated = textID(preferences.defaultModel) { preferences.defaultModel = migrated }
        if let old = preferences.defaultImageModel, let migrated = imageID(old) { preferences.defaultImageModel = migrated }
        if var roles = preferences.modelRoles {
            for (role, old) in roles { if let migrated = textID(old) { roles[role] = migrated } }
            preferences.modelRoles = roles
        }
        for index in chats.indices {
            if let migrated = textID(chats[index].model) { chats[index].model = migrated }
            if let old = chats[index].imagePromptModel, let migrated = textID(old) { chats[index].imagePromptModel = migrated }
            if let migrated = imageID(chats[index].imageModel) { chats[index].imageModel = migrated }
        }
    }
    func addMessage(_ message: ChatMessage, to id: UUID) {
        guard let i = index(id) else { return }
        var safe = message
        safe.text = vault.redact(safe.text)
        safe.detail = safe.detail.map(vault.redact)
        chats[i].messages.append(safe); chats[i].updatedAt = Date(); save()
    }
    func editMessage(_ messageID: UUID, chatID: UUID, _ edit: (inout ChatMessage) -> Void) {
        guard let i = index(chatID), let j = chats[i].messages.firstIndex(where: { $0.id == messageID }) else { return }
        edit(&chats[i].messages[j])
    }
    func addFiles(_ urls: [URL]) {
        for url in urls {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) else { continue }
            if directory.boolValue, let id = selectedID, let i = index(id) { chats[i].folder = url.path }
            let kind = directory.boolValue ? "folder" : ["png", "jpg", "jpeg", "webp", "gif", "heic"].contains(url.pathExtension.lowercased()) ? "image" : "file"
            if !attachments.contains(where: { $0.path == url.path }) { attachments.append(.init(path: url.path, kind: kind)) }
        }; save()
    }
    func chooseFiles(folderOnly: Bool = false, createChat: Bool = false) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = !folderOnly; panel.allowsMultipleSelection = !folderOnly
        guard panel.runModal() == .OK else { return }
        if createChat, let url = panel.url { newChat(folder: url) } else { addFiles(panel.urls) }
    }
    func importTextModel() {
        let panel = NSOpenPanel()
        if let type = UTType(filenameExtension: "gguf") { panel.allowedContentTypes = [type] }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Добавить модель"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let record = try await builtInTextEngine.importFile(url)
                await refreshServices()
                setModel("builtin-text:" + record.id, image: false)
                if let chatID = selectedID {
                    addMessage(.init(role: "assistant", text: "Добавлена локальная модель \(record.name). Она скопирована в хранилище приложения и выбрана для этого чата."), to: chatID)
                }
            } catch { self.error = "Импорт модели: \(error.localizedDescription)" }
        }
    }
    func importMLXModel() {
        guard let localMLXEngine else { error = "Локальный MLX-движок отсутствует в этой сборке"; return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Добавить MLX-модель"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let record = try await localMLXEngine.importDirectory(url)
                await refreshServices()
                setModel("mlx-text:" + record.id, image: false)
                if let chatID = selectedID {
                    addMessage(.init(role: "assistant", text: "Добавлена модель \(record.name). Её файлы находятся в хранилище STIX Agent; LM Studio для запуска не нужен."), to: chatID)
                }
            } catch { self.error = "Импорт MLX-модели: \(error.localizedDescription)" }
        }
    }
    func removeImportedMLXModel(_ record: ImportedMLXModel) {
        let storedID = "mlx-text:" + record.id
        guard preferences.defaultModel != storedID,
              !chats.contains(where: { $0.model == storedID || $0.imagePromptModel == storedID }),
              !(preferences.modelRoles?.values.contains(storedID) ?? false) else {
            error = "Сначала переключите чаты и назначения с этой модели."; return
        }
        Task {
            do { try await localMLXEngine?.remove(record.id); await refreshServices() }
            catch { self.error = "Удаление MLX-модели: \(error.localizedDescription)" }
        }
    }
    func importImageModel() {
        guard let localImageEngine else { error = "Локальный движок изображений отсутствует в этой сборке"; return }
        let panel = NSOpenPanel()
        if let type = UTType(filenameExtension: "safetensors") { panel.allowedContentTypes = [type] }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Добавить модель"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let sources = panel.urls
        Task {
            do {
                var names: [String] = []
                var selected: String?
                for url in sources {
                    let record = try await localImageEngine.importFile(url)
                    let modelID = "local-image:" + record.id
                    for index in chats.indices where chats[index].imageModel == url.lastPathComponent {
                        chats[index].imageModel = modelID
                    }
                    if preferences.defaultImageModel == url.lastPathComponent { preferences.defaultImageModel = modelID }
                    names.append(record.name)
                    selected = modelID
                }
                await refreshServices()
                if let selected { setModel(selected, image: true) }
                if let chatID = selectedID {
                    addMessage(.init(role: "assistant", text: "Добавлены локальные модели: \(names.joined(separator: ", ")). Checkpoint-файлы скопированы в хранилище STIX и запускаются без ComfyUI."), to: chatID)
                }
            } catch { await refreshServices(); self.error = "Импорт изображения: \(error.localizedDescription)" }
        }
    }
    func removeImportedImageModel(_ record: ImportedImageCheckpoint) {
        let modelID = "local-image:" + record.id
        guard preferences.defaultImageModel != modelID,
              !chats.contains(where: { $0.imageModel == modelID }) else {
            error = "Сначала переключите чаты с этой модели, затем удалите её копию."; return
        }
        Task {
            do { try await localImageEngine?.remove(record.id); await refreshServices() }
            catch { self.error = "Удаление модели изображения: \(error.localizedDescription)" }
        }
    }
    func removeImportedTextModel(_ record: ImportedGGUF) {
        let storedID = "builtin-text:" + record.id
        guard preferences.defaultModel != storedID,
              !chats.contains(where: { $0.model == storedID || $0.imagePromptModel == storedID }),
              !(preferences.modelRoles?.values.contains(storedID) ?? false) else {
            error = "Сначала переключите чаты и назначения с этой модели, затем удалите её копию."; return
        }
        Task {
            do { try await builtInTextEngine.remove(record.id); await refreshServices() }
            catch { self.error = "Удаление модели: \(error.localizedDescription)" }
        }
    }
    func refreshServices() async {
        let builtInModels: [ModelDescriptor]
        do { builtInModels = try await builtInTextEngine.models() }
        catch { self.error = error.localizedDescription; builtInModels = [] }
        importedModels = (try? await builtInTextEngine.importedModels()) ?? []
        let mlxModels = (try? await localMLXEngine?.models()) ?? []
        importedMLXModels = (try? await localMLXEngine?.importedModels()) ?? []
        let builtInImages: [ModelDescriptor]
        do { builtInImages = try await builtInImageEngine?.models() ?? [] }
        catch { self.error = error.localizedDescription; builtInImages = [] }
        let localImages = (try? await localImageEngine?.models()) ?? []
        importedImageModels = (try? await localImageEngine?.importedModels()) ?? []
        migrateInstalledModelSelections()
        async let modelResult: Result<[ModelDescriptor], Error> = capture { try await self.inferenceRegistry.externalText.models() }
        async let imageResult: Result<[String], Error> = capture { try await self.inferenceRegistry.externalImage.models().map(\.id) }
        let (m, c) = await (modelResult, imageResult)
        if case .success(let list) = m {
            models = builtInModels + mlxModels + list
        }
        else { models = builtInModels + mlxModels }
        if preferences.defaultModel.isEmpty, let model = models.first {
            preferences.defaultModel = model.id
            if let id = selectedID, let i = index(id), chats[i].model.isEmpty { chats[i].model = model.id }
        }
        checkpoints = LocalServices.mergedImageCheckpoints([builtInImages.map(\.id), localImages.map(\.id),
                                                            externalImageChoices(LocalServices.installedImageCheckpoints()),
                                                            externalImageChoices((try? c.get()) ?? [])])
        save()
    }
    func boot() async {
        guard !booting else { return }
        booting = true; defer { booting = false }
        let initialLM = preferences.lmEndpoint, initialComfy = preferences.comfyEndpoint
        let builtInModels: [ModelDescriptor]
        do { builtInModels = try await builtInTextEngine.models() }
        catch { self.error = "Встроенная модель: \(error.localizedDescription)"; builtInModels = [] }
        importedModels = (try? await builtInTextEngine.importedModels()) ?? []
        let mlxModels = (try? await localMLXEngine?.models()) ?? []
        importedMLXModels = (try? await localMLXEngine?.importedModels()) ?? []
        models = builtInModels + mlxModels
        let builtInImages: [ModelDescriptor]
        do { builtInImages = try await builtInImageEngine?.models() ?? [] }
        catch { self.error = "Встроенная модель изображений: \(error.localizedDescription)"; builtInImages = [] }
        let localImages = (try? await localImageEngine?.models()) ?? []
        importedImageModels = (try? await localImageEngine?.importedModels()) ?? []
        migrateInstalledModelSelections()
        checkpoints = LocalServices.mergedImageCheckpoints([builtInImages.map(\.id), localImages.map(\.id),
                                                            externalImageChoices(LocalServices.installedImageCheckpoints())])
        if preferences.defaultImageModel == nil, let first = builtInImages.first {
            preferences.defaultImageModel = first.id
            if let id = selectedID, let i = index(id), chats[i].messages.isEmpty,
               chats[i].imageModel == "sd_xl_base_1.0.safetensors" { chats[i].imageModel = first.id }
        }
        if preferences.defaultModel.isEmpty, let first = builtInModels.first { preferences.defaultModel = first.id }
        if let id = selectedID, let i = index(id), chats[i].model.isEmpty { chats[i].model = preferences.defaultModel }
        let selectedText = currentChat?.model ?? preferences.defaultModel
        let selectedPrompt = currentChat?.imagePromptModel ?? selectedText
        let requiresExternalText = builtInModels.isEmpty && mlxModels.isEmpty || [selectedText, selectedPrompt].contains(where: {
            !$0.isEmpty && !$0.hasPrefix("builtin-text:") && !$0.hasPrefix("mlx-text:")
        })
        let selectedImage = currentChat?.imageModel ?? preferences.defaultImageModel ?? ""
        let requiresComfy = builtInImages.isEmpty && localImages.isEmpty ||
            (!selectedImage.isEmpty && !selectedImage.hasPrefix("builtin-image:") && !selectedImage.hasPrefix("local-image:"))
        async let comfyResult: Result<Bool, Error> = capture {
            requiresComfy ? try await LocalServices.ensureComfyServer(endpoint: initialComfy, paths: storage.paths) : true
        }
        let modelEndpoint = requiresExternalText ? await LocalServices.ensureModelServer(preferred: initialLM) : nil
        if let modelEndpoint {
            var chosenEndpoint = modelEndpoint
            var available = (try? await LMStudioClient(endpoint: modelEndpoint).models()) ?? []
            if available.isEmpty {
                for candidate in LocalServices.lmCandidates() where candidate != modelEndpoint {
                    if let other = try? await LMStudioClient(endpoint: candidate).models(), !other.isEmpty {
                        chosenEndpoint = candidate; available = other; break
                    }
                }
            }
            if preferences.lmEndpoint == initialLM { preferences.lmEndpoint = chosenEndpoint }
            models = builtInModels + mlxModels + available
            if !available.isEmpty {
                let list = available
                if preferences.defaultModel.isEmpty {
                    let preferred = list.first(where: { $0.id.lowercased().contains("qwen3.5-9b") }) ?? list.first(where: { $0.id.lowercased().contains("qwen3-coder") }) ?? list.first(where: { !$0.id.contains("embedding") })
                    if let preferred { preferences.defaultModel = preferred.id }
                }
                if let id = selectedID, let i = index(id), chats[i].model.isEmpty { chats[i].model = preferences.defaultModel }
            }
            save()
        } else if requiresExternalText {
            if let fallback = builtInModels.first {
                if !preferences.defaultModel.hasPrefix("builtin-text:") && !preferences.defaultModel.hasPrefix("mlx-text:") { preferences.defaultModel = fallback.id }
                for index in chats.indices {
                    if !chats[index].model.hasPrefix("builtin-text:") && !chats[index].model.hasPrefix("mlx-text:") { chats[index].model = fallback.id }
                    if let prompt = chats[index].imagePromptModel, !prompt.hasPrefix("builtin-text:") && !prompt.hasPrefix("mlx-text:") {
                        chats[index].imagePromptModel = fallback.id
                    }
                }
                error = "LM Studio недоступна: чаты переключены на локальную \(fallback.name). История сохранена."
                save()
            } else { error = "Выбранная модель LM Studio / Bionic недоступна. Проверьте /models или /diagnostics." }
        }
        switch await comfyResult {
        case .success(true):
            if requiresComfy, let list = try? await inferenceRegistry.externalImage.models() {
                checkpoints = LocalServices.mergedImageCheckpoints([checkpoints, externalImageChoices(list.map(\.id))])
            }
        case .success(false):
            if requiresComfy { selectOfflineImageFallback(builtInImages: builtInImages, localImages: localImages) }
        case .failure(let failure): if requiresComfy { error = "ComfyUI: \(failure.localizedDescription)"; selectOfflineImageFallback(builtInImages: builtInImages, localImages: localImages) }
        }
        for config in preferences.plugins where config.enabled {
            do { try await activatePlugin(config) }
            catch { self.error = "Плагин \(config.name): \(vault.redact(error.localizedDescription))" }
        }
        startNextJob()
        startFeatureMonitor()
    }
    private func selectOfflineImageFallback(builtInImages: [ModelDescriptor], localImages: [ModelDescriptor]) {
        guard let fallback = localImages.first ?? builtInImages.first else {
            error = "ComfyUI недоступна, автономной модели изображений нет."; return
        }
        if let value = preferences.defaultImageModel, !value.hasPrefix("builtin-image:") && !value.hasPrefix("local-image:") && !value.hasPrefix("workflow:") {
            preferences.defaultImageModel = fallback.id
        }
        for index in chats.indices {
            let value = chats[index].imageModel
            if !value.hasPrefix("builtin-image:") && !value.hasPrefix("local-image:") && !value.hasPrefix("workflow:") {
                chats[index].imageModel = fallback.id
            }
        }
        error = "ComfyUI недоступна: обычные чаты изображений переключены на \(fallback.name). Workflow требуют ComfyUI."
        save()
    }
    func capture<T>(_ operation: () async throws -> T) async -> Result<T, Error> { do { return .success(try await operation()) } catch { return .failure(error) } }
    func stop() {
        task?.cancel()
        continuation?.resume(returning: .deny); continuation = nil; pending = nil
    }
    func respond(_ answer: InteractionAnswer) {
        guard let continuation else { return }
        self.continuation = nil; pending = nil
        continuation.resume(returning: answer)
    }
    func interact(_ request: PendingInteraction, chatID: UUID) async -> InteractionAnswer {
        if Task.isCancelled { return .deny }
        pending = request
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { self.pending = nil; continuation.resume(returning: .deny) }
                else { self.continuation = continuation }
            }
        }, onCancel: { Task { @MainActor in self.respond(.deny) } })
    }
    func approve(tool: String, arguments: JSONValue, title: String, detail: String, chatID: UUID, taskScope: String? = nil) async throws {
        let scope = ApprovalPolicy.scope(tool: tool, arguments: arguments)
        if preferences.alwaysApprovals.contains(scope) || taskApprovals.contains(taskScope ?? scope) { return }
        let answer = await interact(.init(kind: .approval, title: title, detail: vault.redact(detail), scope: scope), chatID: chatID)
        try Task.checkCancellation()
        switch answer {
        case .once: return
        case .task: taskApprovals.insert(taskScope ?? scope)
        case .always: preferences.alwaysApprovals.insert(scope); save()
        default: throw ActionDenied()
        }
    }
    func showPermissions() {
        guard let id = selectedID else { return }
        addMessage(.init(role: "permissions", text: "Доступ к этому Mac", detail: "Выберите рабочую папку, откройте полный доступ к диску и разрешите управление приложениями. Системные права выдаются в macOS; повторно спрашивать их в каждой задаче не нужно."), to: id)
        preferences.onboardingComplete = true; save()
    }
    func requestAccessibility() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    func openDiskAccess() { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) } }
    func openScreenAccess() { if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) } }
    func activatePlugin(_ config: PluginConfig) async throws {
        let references = preferences.pluginEnvironment?[config.id] ?? [:]
        let environment = try CredentialEnvironment.resolve(references, vault: vault)
        let client = MCPClient(config: config, environment: environment, vault: vault)
        let tools: [ToolDefinition]
        do { tools = try await client.tools() }
        catch { await client.close(); throw error }
        if let old = plugins[config.id] { await old.close() }
        plugins[config.id] = client; pluginTools[config.id] = tools
    }
    func repairHistory(_ messages: inout [LMMessage]) {
        var i = 0
        while i < messages.count {
            if !messages[i].toolCalls.isEmpty {
                let calls = messages[i].toolCalls
                let after = i + 1
                let existing = Set(messages.dropFirst(after).prefix { $0.role == "tool" }.compactMap(\.toolCallID))
                var insertAt = after + existing.count
                for call in calls where !existing.contains(call.id) {
                    messages.insert(.init(role: "tool", content: "Операция прервана. Не повторяй без проверки состояния.", toolCallID: call.id), at: insertAt); insertAt += 1
                }
            }; i += 1
        }
    }
}
