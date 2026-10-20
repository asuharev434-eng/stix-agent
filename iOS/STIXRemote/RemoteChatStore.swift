import Foundation
import SwiftUI
import Security
import Network
import Photos

@MainActor
final class RemoteChatStore: ObservableObject {
    @Published private(set) var isPaired = false
    @Published private(set) var snapshot: RemoteSnapshot?
    @Published private(set) var connected = false
    @Published private(set) var offlineMode = false
    @Published private(set) var localMessages: [RemoteMessage] = []
    @Published private(set) var localWorking = false
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
    private var pendingSend: (text: String, id: UUID)?
    var displayMessages: [RemoteMessage] {
        offlineMode ? localMessages : (snapshot?.messages ?? [])
    }

    init() {
        let saved = LocalMobileState.load()
        offlineMode = saved.offlineMode
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
            offlineMode = false; persistLocalState()
            await start()
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        guard !offlineMode, let code else { return }
        do {
            let response = try await perform(.init(operation: "snapshot"), with: code)
            if let snapshot = response.snapshot { self.snapshot = snapshot; loadImages(in: snapshot) }
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
        offlineMode = false; persistLocalState()
        await start()
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if offlineMode { await sendLocally(text); return }
        guard !text.isEmpty, let code, !sending else { return }
        let requestID: UUID
        if let pendingSend, pendingSend.text == text { requestID = pendingSend.id }
        else { requestID = UUID() }
        pendingSend = (text, requestID)
        sending = true
        defer { sending = false }
        do {
            let response = try await perform(.init(operation: "send", text: text), with: code, requestID: requestID)
            if let error = response.error { throw NSError(domain: "STIXRemote", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            draft = ""; pendingSend = nil
            if let snapshot = response.snapshot { self.snapshot = snapshot; loadImages(in: snapshot) }
            connected = true; error = nil
        } catch { self.error = "Не удалось отправить: \(error.localizedDescription)" }
    }

    private func sendLocally(_ text: String) async {
        guard !text.isEmpty, !sending else { return }
        if text.hasPrefix("/") && text != "/help" {
            error = "Команда \(text.split(separator: " ").first.map(String.init) ?? text) доступна на MacBook. Выберите MacBook над чатом; запрос остался в поле ввода."
            return
        }
        sending = true
        draft = ""
        localMessages.append(.init(id: UUID(), role: "user", text: text,
                                   status: "offline", createdAt: .now, attachments: []))
        if text == "/help" {
            localMessages.append(.init(id: UUID(), role: "assistant",
                text: "На iPhone доступны вопросы и генерация текста через локальную модель. Для /image и инструментов выберите MacBook над чатом. Команды не ставятся в очередь.",
                status: "offline", createdAt: .now, attachments: []))
            persistLocalState(); sending = false
            return
        }
        localWorking = true
        error = nil
        persistLocalState()
        defer { localWorking = false; sending = false }
        do {
            let answer = try await LocalLlamaEngine.respond(to: localMessages.filter { $0.status != "not_sent" })
            localMessages.append(.init(id: UUID(), role: "assistant", text: answer,
                                       status: "offline", createdAt: .now, attachments: []))
        } catch {
            localMessages.append(.init(id: UUID(), role: "assistant", text: error.localizedDescription,
                                       status: "error", createdAt: .now, attachments: []))
        }
        persistLocalState()
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
        isPaired = false; connected = false; error = nil
    }

    private func persistLocalState() {
        do {
            try LocalMobileState(offlineMode: offlineMode, messages: localMessages).save()
        } catch { self.error = "Не удалось сохранить локальную историю: \(error.localizedDescription)" }
    }

    func saveImage(_ attachmentID: UUID) async throws {
        guard let data = imageData[attachmentID] else {
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
