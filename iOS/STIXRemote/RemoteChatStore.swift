import Foundation
import SwiftUI
import Security
import Network

@MainActor
final class RemoteChatStore: ObservableObject {
    @Published private(set) var isPaired = false
    @Published private(set) var snapshot: RemoteSnapshot?
    @Published private(set) var connected = false
    @Published var error: String?
    @Published var draft = ""
    @Published private(set) var sending = false
    @Published private(set) var images: [UUID: UIImage] = [:]
    private var code: RemotePairingCode?
    private var polling: Task<Void, Never>?
    private var imageLoads: Set<UUID> = []
    private let cloud = RemoteCloudMailbox()
    private var preferCloud = false
    private var cloudBusy = false
    private var pendingSend: (text: String, id: UUID)?

    init() {
        if let stored = RemoteKeychain.read(), let decoded = try? JSONDecoder().decode(RemotePairingCode.self, from: stored) {
            code = decoded; isPaired = true
        }
    }

    func start() async {
        guard isPaired else { return }
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
            await start()
        } catch { self.error = error.localizedDescription }
    }

    func refresh() async {
        guard let code else { return }
        do {
            let response = try await perform(.init(operation: "snapshot"), with: code)
            if let snapshot = response.snapshot { self.snapshot = snapshot; loadImages(in: snapshot) }
            connected = true; error = nil
        } catch { connected = false; self.error = "Mac недоступен: \(error.localizedDescription)" }
    }

    func send() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
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
        pendingSend = nil
        isPaired = false; connected = false; error = nil
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
