import SwiftUI
import AppKit
import ApplicationServices

@MainActor
final class AppStore: ObservableObject {
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
    @Published var skills: [LocalSkill] = []
    @Published var focusedMessageID: UUID?
    @Published var checkpoints: [String] = []
    @Published var draft = ""
    @Published var attachments: [Attachment] = []
    @Published var busy = false
    @Published var compactingChatID: UUID?
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
    var activeChatID: UUID?
    var task: Task<Void, Never>?
    var continuation: CheckedContinuation<InteractionAnswer, Never>?
    var taskApprovals: Set<String> = []
    var undos: [UUID: UndoRecord] = [:]
    var streamedText: [UUID: String] = [:]
    var undoing: Set<UUID> = []
    var canPersist = true

    init(storage: StateStorage = StateStorage()) {
        self.storage = storage
        do {
            if let state = try storage.load() {
                jobs = state.jobs ?? []
                for i in jobs.indices where ["running", "queued"].contains(jobs[i].status) { jobs[i].status = "interrupted" }
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
    func newChat(folder: URL? = nil) {
        preserveDraft()
        let chat = Chat(folder: folder?.path, model: preferences.defaultModel)
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
    func refreshServices() async {
        async let modelResult: Result<[ModelDescriptor], Error> = capture { try await LMStudioClient(endpoint: self.preferences.lmEndpoint).models() }
        async let imageResult: Result<[String], Error> = capture { try await ComfyClient(endpoint: self.preferences.comfyEndpoint).checkpoints() }
        let (m, c) = await (modelResult, imageResult)
        if case .success(let list) = m {
            models = list
            if preferences.defaultModel.isEmpty, let model = list.first { preferences.defaultModel = model.id; if let id = selectedID, let i = index(id) { chats[i].model = model.id } }
        }
        if case .success(let list) = c { checkpoints = list }
        save()
    }
    func boot() async {
        if !NSWorkspace.shared.runningApplications.contains(where: { ["Bionic", "LM Studio"].contains($0.localizedName ?? "") }) { LocalServices.openModelApp() }
        await refreshServices()
        if models.isEmpty {
            for endpoint in LocalServices.lmCandidates() where endpoint != preferences.lmEndpoint {
                if let list = try? await LMStudioClient(endpoint: endpoint).models(), !list.isEmpty {
                    preferences.lmEndpoint = endpoint; models = list
                    let preferred = list.first(where: { $0.id.lowercased().contains("qwen3.5-9b") }) ?? list.first(where: { $0.id.lowercased().contains("qwen3-coder") }) ?? list.first(where: { !$0.id.contains("embedding") }) ?? list[0]
                    if preferences.defaultModel.isEmpty { preferences.defaultModel = preferred.id }
                    if let id = selectedID, let i = index(id), chats[i].model.isEmpty { chats[i].model = preferences.defaultModel }
                    save(); break
                }
            }
        }
        if checkpoints.isEmpty && preferences.comfyEndpoint == "http://127.0.0.1:8188" {
            do {
                if try LocalServices.startInstalledComfy(paths: storage.paths) {
                    for _ in 0..<30 {
                        try Task.checkCancellation()
                        if let list = try? await ComfyClient(endpoint: preferences.comfyEndpoint).checkpoints(), !list.isEmpty { checkpoints = list; break }
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    }
                }
            } catch { self.error = "ComfyUI: \(error.localizedDescription)" }
        }
        for config in preferences.plugins where config.enabled {
            do { try await activatePlugin(config) }
            catch { self.error = "Плагин \(config.name): \(vault.redact(error.localizedDescription))" }
        }
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
        if let old = plugins[config.id] { await old.close() }
        let references = preferences.pluginEnvironment?[config.id] ?? [:]
        let environment = try CredentialEnvironment.resolve(references, vault: vault)
        let client = MCPClient(config: config, environment: environment)
        let tools = try await client.tools()
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
