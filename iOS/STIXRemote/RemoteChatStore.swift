import Foundation
import SwiftUI
import Security
import Network
import Photos
import PhotosUI
import UniformTypeIdentifiers
import UserNotifications

struct MobileDraftUpload: Identifiable, Sendable {
    let id = UUID()
    let name: String
    let data: Data
    let isImage: Bool
}

@MainActor
final class RemoteChatStore: ObservableObject {
    @Published private(set) var isPaired = false
    @Published private(set) var snapshot: RemoteSnapshot?
    @Published private(set) var connected = false
    @Published private(set) var checkingConnection = false
    @Published private(set) var offlineMode = false
    @Published private(set) var localMessages: [RemoteMessage] = []
    @Published private(set) var localWorking = false
    @Published private(set) var localPartial = ""
    @Published private(set) var localImageProgress: Double?
    @Published private(set) var localModels: [LocalModelChoice] = []
    @Published private(set) var selectedLocalModelID: String?
    @Published private(set) var localImageModels: [LocalImageModelChoice] = []
    @Published private(set) var selectedLocalImageModelID: String?
    @Published private(set) var importingModel = false
    @Published private(set) var pendingUpload: MobileDraftUpload?
    @Published var error: String?
    @Published var draft = ""
    @Published private(set) var sending = false
    @Published private(set) var images: [UUID: UIImage] = [:]
    private var imageData: [UUID: Data] = [:]
    private var code: RemotePairingCode?
    private var polling: Task<Void, Never>?
    private var imageLoads: Set<UUID> = []
    private let cloud = RemoteCloudMailbox()
    private var preferCloud = false
    private var cloudBusy = false
    private var pendingSend: (text: String, uploadID: UUID?, id: UUID)?
    private var localGeneration: LocalGeneration?
    private var localImageGeneration: LocalImageGeneration?
    private var localImagePaths: [UUID: String] = [:]
    private var subscribedToCloud = false
    private var lastRemoteAssistantID: UUID?
    var selectedLocalModel: LocalModelChoice? {
        localModels.first(where: { $0.id == selectedLocalModelID }) ?? localModels.first
    }
    var selectedLocalImageModel: LocalImageModelChoice? {
        localImageModels.first(where: { $0.id == selectedLocalImageModelID }) ?? localImageModels.first
    }
    var displayMessages: [RemoteMessage] {
        offlineMode ? localMessages : (snapshot?.messages ?? [])
    }

    init() {
        let saved = LocalMobileState.load()
        offlineMode = saved.offlineMode
        localModels = LocalModelLibrary.available()
        selectedLocalModelID = saved.selectedModelID
        localImageModels = LocalImageModelLibrary.available()
        selectedLocalImageModelID = saved.selectedImageModelID
        localImagePaths = saved.imagePaths ?? [:]
        lastRemoteAssistantID = saved.lastRemoteAssistantID
        let recentImageIDs = Set(saved.messages.suffix(24).flatMap { $0.attachments.map(\.id) })
        for (id, path) in localImagePaths where recentImageIDs.contains(id) {
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)), let image = UIImage(data: data) {
                imageData[id] = data; images[id] = image
            }
        }
        localMessages = saved.messages.map { message in
            guard message.status == "queued" else { return message }
            return RemoteMessage(id: message.id, role: message.role, text: message.text,
                                 status: "not_sent", createdAt: message.createdAt,
                                 attachments: message.attachments)
        }
        if localMessages.contains(where: { $0.status == "not_sent" }) { persistLocalState() }
        if let stored = RemoteKeychain.read(), let decoded = try? JSONDecoder().decode(RemotePairingCode.self, from: stored) {
            code = decoded; isPaired = true
        }
    }

    func start() async {
        guard isPaired, !offlineMode else { return }
        await refresh()
        if !subscribedToCloud, let cloud {
            do {
                try await cloud.installChangeSubscription(id: "stix-remote-phone-v1")
                UIApplication.shared.registerForRemoteNotifications()
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                subscribedToCloud = true
            } catch { self.error = "Уведомления iPhone: \(error.localizedDescription)" }
        }
        if polling == nil {
            polling = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(self?.preferCloud == true ? 8 : 3))
                    guard !Task.isCancelled else { return }
                    await self?.refresh()
                }
            }
        }
    }

    func pair(_ value: String) async {
        do {
            let code = try RemotePairingCode.parse(value)
            let response = try await perform(.init(operation: "pair", deviceName: UIDevice.current.name), with: code)
            guard let snapshot = response.snapshot else { throw RemoteChatError.invalidFrame }
            try RemoteKeychain.save(JSONEncoder().encode(code))
            self.code = code; self.snapshot = snapshot; isPaired = true; connected = true; error = nil
            lastRemoteAssistantID = snapshot.messages.last(where: { $0.role == "assistant" })?.id
            offlineMode = false; persistLocalState()
            await start()
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        guard !offlineMode, let code, !checkingConnection else { return }
        checkingConnection = true
        defer { checkingConnection = false }
        do {
            let knownAssistantID = lastRemoteAssistantID
            let response = try await perform(.init(operation: "snapshot"), with: code)
            if let error = response.error {
                throw NSError(domain: "STIXRemote", code: 8,
                              userInfo: [NSLocalizedDescriptionKey: error])
            }
            guard let snapshot = response.snapshot else { throw RemoteChatError.invalidFrame }
            self.snapshot = snapshot; loadImages(in: snapshot)
            let latest = snapshot.messages.last(where: { $0.role == "assistant" })
            if let knownAssistantID, knownAssistantID != latest?.id,
               UIApplication.shared.applicationState != .active, let latest {
                let content = UNMutableNotificationContent()
                content.title = "STIX Agent · MacBook"
                content.body = String(latest.text.prefix(180))
                content.sound = .default
                try? await UNUserNotificationCenter.current().add(
                    UNNotificationRequest(identifier: latest.id.uuidString, content: content, trigger: nil))
            }
            if lastRemoteAssistantID != latest?.id {
                lastRemoteAssistantID = latest?.id
                persistLocalState()
            }
            connected = true; error = nil
        } catch { connected = false; self.error = "Mac недоступен: \(error.localizedDescription)" }
    }

    func useOfflineMode() {
        polling?.cancel(); polling = nil
        offlineMode = true; error = nil
        persistLocalState()
    }

    func useMacMode() async {
        guard isPaired else {
            offlineMode = false; persistLocalState()
            return
        }
        offlineMode = false; connected = false; persistLocalState()
        await start()
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if offlineMode { await sendLocally(text); return }
        guard !text.isEmpty || pendingUpload != nil, let code, !sending else { return }
        if pendingUpload?.isImage == true,
           snapshot?.models.first(where: { $0.selected })?.supportsImagePrompt == false {
            error = "Выбранная модель принимает только короткий текст. Для анализа фото выберите другую текстовую модель MacBook; фото останется прикреплённым."
            return
        }
        let requestID: UUID
        if let pendingSend, pendingSend.text == text, pendingSend.uploadID == pendingUpload?.id { requestID = pendingSend.id }
        else { requestID = UUID() }
        pendingSend = (text, pendingUpload?.id, requestID)
        sending = true
        defer { sending = false }
        do {
            let response = try await perform(.init(operation: "send", text: text,
                                                   uploadName: pendingUpload?.name,
                                                   uploadData: pendingUpload?.data), with: code, requestID: requestID)
            if let error = response.error { throw NSError(domain: "STIXRemote", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            draft = ""; pendingUpload = nil; pendingSend = nil
            if let snapshot = response.snapshot {
                self.snapshot = snapshot; loadImages(in: snapshot)
                lastRemoteAssistantID = snapshot.messages.last(where: { $0.role == "assistant" })?.id
                persistLocalState()
            }
            connected = true; error = nil
        } catch { self.error = "Не удалось отправить: \(error.localizedDescription)" }
    }

    func attachFile(_ source: URL) async {
        guard !sending else { return }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size > 0, size <= 8 * 1024 * 1024 else { throw LocalUploadError.invalidSize }
            let name = source.lastPathComponent
            let data = try Data(contentsOf: source)
            guard data.count == size else { throw LocalUploadError.invalidSize }
            pendingUpload = .init(name: name, data: data,
                                  isImage: ["png", "jpg", "jpeg", "webp", "heic", "gif"].contains(source.pathExtension.lowercased()))
            error = nil
        } catch { self.error = "Вложение: \(error.localizedDescription)" }
    }

    func attachPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  !data.isEmpty, data.count <= 8 * 1024 * 1024 else { throw LocalUploadError.invalidSize }
            let suffix = item.supportedContentTypes.first(where: { ["png", "jpg", "jpeg", "heic", "webp"].contains($0.preferredFilenameExtension ?? "") })?.preferredFilenameExtension ?? "jpg"
            pendingUpload = .init(name: "Фото-\(UUID().uuidString.prefix(8)).\(suffix)", data: data, isImage: true)
            error = nil
        } catch { self.error = "Фото: \(error.localizedDescription)" }
    }

    func clearUpload() { pendingUpload = nil; pendingSend = nil }

    private func sendLocally(_ text: String) async {
        guard !text.isEmpty || pendingUpload != nil, !sending else { return }
        let localCommands = text == "/help" || text == "/models" || text == "/time" ||
            text.hasPrefix("/calc ") || text.hasPrefix("/image ")
        if text.hasPrefix("/") && !localCommands {
            error = "Команда \(text.split(separator: " ").first.map(String.init) ?? text) доступна на MacBook. Выберите MacBook над чатом; запрос остался в поле ввода."
            return
        }
        let upload = pendingUpload
        sending = true
        draft = ""
        pendingUpload = nil
        let input = upload.map { text + (text.isEmpty ? "" : "\n") + "📎 \($0.name)" } ?? text
        localMessages.append(.init(id: UUID(), role: "user", text: input,
                                   status: "offline", createdAt: .now, attachments: []))
        if text == "/help" {
            localMessages.append(.init(id: UUID(), role: "assistant",
                text: "На iPhone работают текст, /image, /calc, /time и анализ выбранного файла или фото. /models выбирает и добавляет GGUF. Для инструментов Mac выберите MacBook над чатом.",
                status: "offline", createdAt: .now, attachments: []))
            persistLocalState(); sending = false
            return
        }
        if text == "/models" {
            localMessages.append(.init(id: UUID(), role: "assistant",
                text: "Модели выбираются над полем ввода. Можно добавить GGUF до 3 ГБ и совместимую папку Core ML до 4 ГБ. Текст: \(localModels.map(\.name).joined(separator: ", ")). Изображения: \(localImageModels.map(\.name).joined(separator: ", ")).",
                status: "offline", createdAt: .now, attachments: []))
            persistLocalState(); sending = false
            return
        }
        if text == "/time" || text.hasPrefix("/calc ") {
            do {
                let answer = try LocalPhoneTools.answer(text) ?? "Команда не найдена"
                localMessages.append(.init(id: UUID(), role: "assistant", text: answer,
                    status: "offline", createdAt: .now, attachments: []))
            } catch {
                localMessages.append(.init(id: UUID(), role: "assistant", text: error.localizedDescription,
                    status: "error", createdAt: .now, attachments: []))
            }
            persistLocalState(); sending = false
            return
        }
        localWorking = true
        localPartial = ""
        localImageProgress = nil
        error = nil
        persistLocalState()
        defer { localWorking = false; sending = false; localGeneration = nil; localImageGeneration = nil;
                localPartial = ""; localImageProgress = nil }
        do {
            if text.hasPrefix("/image ") {
                try await generateLocalImage(prompt: String(text.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines),
                                             sourceImage: upload?.isImage == true ? upload?.data : nil)
                persistLocalState()
                return
            }
            guard let model = selectedLocalModel else { throw LocalLlamaError.modelMissing }
            var inputMessages = localMessages.filter { $0.status != "not_sent" }
            if let upload, let last = inputMessages.last {
                let description = try await LocalPhoneTools.describe(upload)
                inputMessages[inputMessages.count - 1] = .init(id: last.id, role: last.role,
                    text: last.text + "\n\nСодержимое вложения:\n" + description,
                    status: last.status, createdAt: last.createdAt, attachments: [])
            }
            let generation = LocalLlamaEngine.start(messages: inputMessages,
                                                    modelURL: model.url)
            localGeneration = generation
            for try await partial in generation.stream { localPartial = partial }
            guard !localPartial.isEmpty else { throw LocalLlamaError.emptyResponse }
            localMessages.append(.init(id: UUID(), role: "assistant", text: localPartial,
                                       status: "offline", createdAt: .now, attachments: []))
        } catch is CancellationError {
            if !localPartial.isEmpty {
                localMessages.append(.init(id: UUID(), role: "assistant", text: localPartial,
                                           status: "stopped", createdAt: .now, attachments: []))
            }
        } catch {
            localMessages.append(.init(id: UUID(), role: "assistant", text: error.localizedDescription,
                                       status: "error", createdAt: .now, attachments: []))
        }
        persistLocalState()
    }

    private func generateLocalImage(prompt: String, sourceImage: Data?) async throws {
        guard !prompt.isEmpty else { throw LocalImageError.rejected }
        guard let imageModel = selectedLocalImageModel else { throw LocalImageError.modelMissing }
        if sourceImage != nil && !imageModel.supportsEditing { throw LocalImageError.rejected }
        var adapted = prompt
        if let model = selectedLocalModel {
            let request = RemoteMessage(id: UUID(), role: "user",
                text: "Translate this image prompt into concise, vivid English for Stable Diffusion. Output only the English prompt: \(prompt)",
                status: nil, createdAt: .now, attachments: [])
            let generation = LocalLlamaEngine.start(messages: [request], modelURL: model.url,
                                                    imagePrompt: true)
            localGeneration = generation
            for try await partial in generation.stream { adapted = partial }
            localGeneration = nil
        }
        let imageGeneration = LocalImageEngine.start(prompt: adapted, resources: imageModel.url,
                                                     sourceImage: sourceImage)
        localImageGeneration = imageGeneration
        for try await event in imageGeneration.stream {
            switch event {
            case .progress(let step, let total): localImageProgress = Double(step) / Double(max(1, total))
            case .image(let url):
                let id = UUID()
                let data = try Data(contentsOf: url)
                guard let image = UIImage(data: data) else { throw LocalImageError.saveFailed }
                localImagePaths[id] = url.path
                imageData[id] = data; images[id] = image
                localMessages.append(.init(id: UUID(), role: "assistant", text: "Изображение создано на iPhone.",
                    status: "offline", createdAt: .now,
                    attachments: [.init(id: id, name: url.lastPathComponent, kind: "image")]))
            }
        }
    }

    func stopLocalGeneration() { localGeneration?.cancel(); localImageGeneration?.cancel() }

    func selectLocalModel(_ id: String) {
        guard !localWorking, localModels.contains(where: { $0.id == id }) else { return }
        selectedLocalModelID = id
        persistLocalState()
    }

    func importLocalModel(_ url: URL) async {
        guard !importingModel, !localWorking else { return }
        importingModel = true
        defer { importingModel = false }
        do {
            let model = try await Task.detached(priority: .userInitiated) {
                try LocalModelLibrary.importGGUF(from: url)
            }.value
            localModels = LocalModelLibrary.available()
            selectedLocalModelID = model.id
            persistLocalState()
            error = nil
        } catch { self.error = "Импорт модели: \(error.localizedDescription)" }
    }

    func selectLocalImageModel(_ id: String) {
        guard !localWorking, localImageModels.contains(where: { $0.id == id }) else { return }
        selectedLocalImageModelID = id
        persistLocalState()
    }

    func importLocalImageModel(_ url: URL) async {
        guard !importingModel, !localWorking else { return }
        importingModel = true
        defer { importingModel = false }
        do {
            let model = try await Task.detached(priority: .userInitiated) {
                try LocalImageModelLibrary.importCoreML(from: url)
            }.value
            localImageModels = LocalImageModelLibrary.available()
            selectedLocalImageModelID = model.id
            persistLocalState()
            error = nil
        } catch { self.error = "Импорт модели изображений: \(error.localizedDescription)" }
    }

    func answer(_ answer: String, interaction: RemoteInteraction) async {
        guard let code else { return }
        do {
            let response = try await perform(.init(operation: "answer", interactionID: interaction.id, answer: answer), with: code)
            if let error = response.error { throw NSError(domain: "STIXRemote", code: 2, userInfo: [NSLocalizedDescriptionKey: error]) }
            snapshot = response.snapshot; self.error = nil
        } catch { self.error = error.localizedDescription }
    }

    func selectModel(_ id: String, image: Bool) async {
        guard let code else { return }
        do {
            let response = try await perform(.init(operation: image ? "set-image-model" : "set-model", text: id), with: code)
            if let error = response.error { throw NSError(domain: "STIXRemote", code: 4, userInfo: [NSLocalizedDescriptionKey: error]) }
            snapshot = response.snapshot; self.error = nil
        } catch { self.error = error.localizedDescription }
    }

    func selectImagePromptModel(_ id: String?) async {
        guard let code else { return }
        do {
            let response = try await perform(.init(operation: "set-image-prompt-model", text: id ?? "automatic"), with: code)
            if let error = response.error { throw NSError(domain: "STIXRemote", code: 5, userInfo: [NSLocalizedDescriptionKey: error]) }
            snapshot = response.snapshot; self.error = nil
        } catch { self.error = error.localizedDescription }
    }

    func disconnect() {
        polling?.cancel(); polling = nil
        RemoteKeychain.remove(); code = nil; snapshot = nil; images = [:]
        imageData = [:]
        pendingSend = nil
        lastRemoteAssistantID = nil; persistLocalState()
        isPaired = false; connected = false; checkingConnection = false; error = nil
    }

    private func persistLocalState() {
        do {
            try LocalMobileState(offlineMode: offlineMode, messages: localMessages,
                                 selectedModelID: selectedLocalModelID,
                                 selectedImageModelID: selectedLocalImageModelID,
                                 imagePaths: localImagePaths,
                                 lastRemoteAssistantID: lastRemoteAssistantID).save()
        } catch { self.error = "Не удалось сохранить локальную историю: \(error.localizedDescription)" }
    }

    func saveImage(_ attachmentID: UUID) async throws {
        let data = imageData[attachmentID] ?? localImagePaths[attachmentID].flatMap {
            try? Data(contentsOf: URL(fileURLWithPath: $0))
        }
        guard let data else {
            throw NSError(domain: "STIXRemote", code: 6, userInfo: [NSLocalizedDescriptionKey:
                "Изображение ещё загружается. Попробуйте снова через несколько секунд."])
        }
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized else {
            throw NSError(domain: "STIXRemote", code: 7, userInfo: [NSLocalizedDescriptionKey:
                "Разрешите STIX Agent добавлять фотографии в Настройках iPhone."])
        }
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: .photo, data: data, options: nil)
        }
    }

    func loadLocalImage(_ attachmentID: UUID) {
        guard images[attachmentID] == nil,
              let path = localImagePaths[attachmentID],
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let image = UIImage(data: data) else { return }
        imageData[attachmentID] = data
        images[attachmentID] = image
    }

    private func loadImages(in snapshot: RemoteSnapshot) {
        for message in snapshot.messages {
            for attachment in message.attachments where attachment.kind == "image" {
                guard images[attachment.id] == nil, !imageLoads.contains(attachment.id) else { continue }
                imageLoads.insert(attachment.id)
                Task { [weak self] in
                    guard let self, let code = self.code else { return }
                    defer { self.imageLoads.remove(attachment.id) }
                    guard let response = try? await self.perform(.init(operation: "attachment", messageID: message.id,
                                                                       attachmentID: attachment.id), with: code),
                          let data = response.fileData, let image = UIImage(data: data) else { return }
                    self.imageData[attachment.id] = data
                    self.images[attachment.id] = image
                }
            }
        }
    }

    private func perform(_ request: RemoteRequest, with code: RemotePairingCode,
                         requestID id: UUID = UUID()) async throws -> RemoteResponse {
        let envelope = try RemoteEnvelope.seal(request, peerID: code.pairingID, requestID: id, key: code.key)
        if !preferCloud {
            do {
                let response = try await performNearby(envelope, code: code)
                return try decode(response, requestID: id, code: code)
            } catch { preferCloud = true }
        }
        guard let cloud, await cloud.isAvailable() else {
            throw NSError(domain: "STIXRemote", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "Для связи из другой сети войдите в один Apple Account на iPhone и Mac"])
        }
        while cloudBusy { try await Task.sleep(for: .milliseconds(100)) }
        cloudBusy = true
        defer { cloudBusy = false }
        try await cloud.sendToMac(envelope)
        let deadline = Date().addingTimeInterval(65)
        while Date() < deadline {
            if let reply = try await cloud.latestForPhone(peerID: code.pairingID), reply.requestID == id {
                return try decode(reply, requestID: id, code: code)
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw URLError(.timedOut)
    }

    private func performNearby(_ envelope: RemoteEnvelope, code: RemotePairingCode) async throws -> RemoteEnvelope {
        let connection: NWConnection
        do { connection = try await RemoteSocket.connect(to: code) }
        catch { connection = try await RemoteSocket.connect(host: code.host, port: code.port) }
        defer { connection.cancel() }
        try await RemoteSocket.send(JSONEncoder().encode(envelope), through: connection)
        let data = try await RemoteSocket.receive(connection)
        return try JSONDecoder().decode(RemoteEnvelope.self, from: data)
    }

    private func decode(_ reply: RemoteEnvelope, requestID: UUID, code: RemotePairingCode) throws -> RemoteResponse {
        guard reply.peerID == code.pairingID, reply.requestID == requestID else { throw RemoteChatError.authentication }
        return try reply.open(RemoteResponse.self, key: code.key)
    }
}

private struct LocalMobileState: Codable {
    var offlineMode: Bool = false
    var messages: [RemoteMessage] = []
    var selectedModelID: String?
    var selectedImageModelID: String?
    var imagePaths: [UUID: String]?
    var lastRemoteAssistantID: UUID?

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("STIXRemote", isDirectory: true)
            .appendingPathComponent("local-chat.json")
    }

    static func load() -> Self {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return state
    }

    func save() throws {
        let file = Self.url
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                              ofItemAtPath: file.path)
    }
}

private enum LocalUploadError: LocalizedError {
    case invalidSize
    var errorDescription: String? { "Файл должен быть от 1 байта до 8 МБ." }
}

private enum RemoteKeychain {
    private static let service = "studio.stix.agent.remote"
    private static let account = "paired-mac"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    static func read() -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
    static func save(_ data: Data) throws {
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    static func remove() { SecItemDelete(query as CFDictionary) }
}
