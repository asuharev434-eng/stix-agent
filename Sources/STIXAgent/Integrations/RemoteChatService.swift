import Foundation
import Network
import CryptoKit
import RemoteChatCore
import Security

private struct MobilePeer: Codable {
    let id: UUID
    let name: String
    var processedRequests: [UUID]
}

@MainActor
final class RemoteChatService {
    private weak var store: AppStore?
    private let root: URL
    private let vault: SecretVault
    private let serviceName: String
    private var listener: NWListener?
    private var port: UInt16?
    private var pendingCode: RemotePairingCode?
    private var peers: [MobilePeer] = []
    private var activeConnections = 0
    private let cloud = RemoteCloudMailbox()
    private var cloudPolling: Task<Void, Never>?
    private var lastCloudRequests: [UUID: UUID] = [:]

    init(store: AppStore, root: URL, vault: SecretVault) {
        self.store = store; self.root = root; self.vault = vault
        let machine = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        serviceName = "STIX-" + String(machine.prefix(24)).replacingOccurrences(of: " ", with: "-")
        let file = root.appendingPathComponent("RemoteChat/peers.json")
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([MobilePeer].self, from: data) { peers = saved }
    }

    func start() {
        if cloudPolling == nil, let cloud {
            cloudPolling = Task { [weak self] in
                guard let self else { return }
                guard await cloud.isAvailable() else { self.cloudPolling = nil; return }
                while !Task.isCancelled {
                    await self.pollCloud()
                    try? await Task.sleep(for: .seconds(self.pendingCode == nil ? 8 : 3))
                }
            }
        }
        guard listener == nil else { return }
        do {
            let listener = try NWListener(using: .tcp, on: .any)
            listener.service = .init(name: serviceName, type: "_stixagent._tcp")
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self else { return }
                    switch state {
                    case .ready: self.port = listener?.port?.rawValue
                    case .failed(let error):
                        self.listener = nil; self.port = nil
                        self.store?.error = "Подключение iPhone: \(error.localizedDescription)"
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in await self?.handle(connection) }
            }
            self.listener = listener
            listener.start(queue: DispatchQueue(label: "studio.stix.remote.listener"))
        } catch { store?.error = "Подключение iPhone: \(error.localizedDescription)" }
    }

    func pairingCode() async throws -> RemotePairingCode {
        start()
        for _ in 0..<30 where port == nil { try await Task.sleep(for: .milliseconds(100)) }
        guard let port else { throw AgentError.message("Не удалось открыть локальный канал для iPhone") }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else { throw AgentError.message("Не удалось создать ключ сопряжения") }
        let host = ProcessInfo.processInfo.hostName.hasSuffix(".local") ? ProcessInfo.processInfo.hostName : ProcessInfo.processInfo.hostName + ".local"
        let code = RemotePairingCode(serviceName: serviceName, host: host, port: port,
                                     key: Data(bytes), expiresAt: .now.addingTimeInterval(300))
        pendingCode = code
        return code
    }

    private func handle(_ connection: NWConnection) async {
        guard activeConnections < 8 else { connection.cancel(); return }
        activeConnections += 1
        defer { activeConnections -= 1; connection.cancel() }
        connection.start(queue: DispatchQueue(label: "studio.stix.remote.accepted"))
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) { [weak connection] in connection?.cancel() }
        do {
            let input = try await RemoteSocket.receive(connection)
            let envelope = try JSONDecoder().decode(RemoteEnvelope.self, from: input)
            let sealed = try response(to: envelope)
            try await RemoteSocket.send(JSONEncoder().encode(sealed), through: connection)
        } catch {
            // Authentication failures are deliberately silent on the wire.
        }
    }

    func cloudIssue() async -> String? {
        guard let cloud else { return "В подписи приложения нет доступа к iCloud" }
        return await cloud.availabilityIssue()
    }

    var connectedDeviceNames: [String] { peers.map(\.name) }

    func revokeAll() throws {
        for peer in peers { try vault.remove("mobile." + peer.id.uuidString) }
        peers.removeAll(); pendingCode = nil; store?.mobilePairing = nil
        try persistPeers()
    }

    private func pollCloud() async {
        guard let cloud else { return }
        let ids = peers.map(\.id) + (pendingCode.map { [$0.pairingID] } ?? [])
        for id in ids {
            do {
                guard let incoming = try await cloud.latestForMac(peerID: id),
                      lastCloudRequests[id] != incoming.requestID else { continue }
                let outgoing = try response(to: incoming)
                try await cloud.sendToPhone(outgoing)
                lastCloudRequests[id] = incoming.requestID
            } catch {
                // A failed CloudKit request is retried on the next cycle. Never log encrypted frames.
            }
        }
    }

    private func response(to envelope: RemoteEnvelope) throws -> RemoteEnvelope {
        guard abs(Date().timeIntervalSince(envelope.sentAt)) <= 120 else { throw RemoteChatError.staleRequest }
        let key: Data
        let isPairing: Bool
        if let peer = peers.first(where: { $0.id == envelope.peerID }) {
            guard let saved = try? vault.get("mobile." + peer.id.uuidString),
                  let data = Data(base64Encoded: saved) else { throw RemoteChatError.authentication }
            key = data; isPairing = false
        } else if let code = pendingCode, code.pairingID == envelope.peerID, code.expiresAt > .now {
            key = code.key; isPairing = true
        } else { throw RemoteChatError.authentication }
        let request: RemoteRequest = try envelope.open(RemoteRequest.self, key: key)
        let reply = try process(request, peerID: envelope.peerID, requestID: envelope.requestID,
                                key: key, isPairing: isPairing)
        return try RemoteEnvelope.seal(reply, peerID: envelope.peerID,
                                       requestID: envelope.requestID, key: key)
    }

    private func process(_ request: RemoteRequest, peerID: UUID, requestID: UUID,
                         key: Data, isPairing: Bool) throws -> RemoteResponse {
        guard let store, store.canPersist else { return .init(error: "Хранилище Mac недоступно") }
        if isPairing {
            guard request.operation == "pair" else { throw RemoteChatError.authentication }
            let name = String((request.deviceName ?? "iPhone").prefix(80))
            try vault.set(key.base64EncodedString(), for: "mobile." + peerID.uuidString)
            peers.append(.init(id: peerID, name: name, processedRequests: [requestID]))
            try persistPeers()
            pendingCode = nil; store.mobilePairing = nil
            return .init(snapshot: snapshot(in: store, chatID: mobileChat(in: store)))
        }
        guard let index = peers.firstIndex(where: { $0.id == peerID }) else { throw RemoteChatError.authentication }
        let chatID = mobileChat(in: store)
        if peers[index].processedRequests.contains(requestID) { return .init(snapshot: snapshot(in: store, chatID: chatID)) }
        switch request.operation {
        case "snapshot": break
        case "send":
            guard let text = request.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.utf8.count <= 16_384 else { return .init(error: "Сообщение пустое или слишком длинное") }
            guard store.sendRemote(text, chatID: chatID, requestID: requestID) else {
                return .init(error: "Не удалось сохранить сообщение на Mac")
            }
            try markProcessed(requestID, peerIndex: index)
        case "set-model":
            guard let model = request.text, store.models.contains(where: { $0.id == model }),
                  let chatIndex = store.index(chatID) else { return .init(error: "Модель недоступна") }
            store.chats[chatIndex].model = model; store.save()
            try markProcessed(requestID, peerIndex: index)
        case "set-image-model":
            guard let model = request.text, store.checkpoints.contains(model),
                  let chatIndex = store.index(chatID) else { return .init(error: "Модель изображений недоступна") }
            store.chats[chatIndex].imageModel = model; store.save()
            try markProcessed(requestID, peerIndex: index)
        case "set-image-prompt-model":
            guard let value = request.text, let chatIndex = store.index(chatID) else {
                return .init(error: "Текстовая модель недоступна")
            }
            if value == "automatic" { store.chats[chatIndex].imagePromptModel = nil }
            else {
                guard let model = store.models.first(where: { $0.id == value }),
                      !TinyTextPolicy.applies(model) else {
                    return .init(error: "Эта модель не подходит для подготовки изображений")
                }
                store.chats[chatIndex].imagePromptModel = model.id
            }
            store.save()
            try markProcessed(requestID, peerIndex: index)
        case "answer":
            guard let interactionID = request.interactionID, store.activeChatID == chatID,
                  store.pending?.id == interactionID, let answer = request.answer else {
                return .init(error: "Вопрос уже закрыт")
            }
            try markProcessed(requestID, peerIndex: index)
            switch answer {
            case "once": store.respond(.once)
            case "task": store.respond(.task)
            case "always": store.respond(.always)
            case "deny": store.respond(.deny)
            default: store.respond(.text(answer))
            }
        case "attachment":
            guard let messageID = request.messageID, let attachmentID = request.attachmentID,
                  let chat = store.chats.first(where: { $0.id == chatID }),
                  let path = chat.messages.first(where: { $0.id == messageID })?.attachments.first(where: { $0.id == attachmentID })?.path,
                  let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber,
                  size.intValue <= 16 * 1024 * 1024 else { return .init(error: "Вложение недоступно или слишком велико") }
            return .init(fileData: try Data(contentsOf: URL(fileURLWithPath: path)))
        default: return .init(error: "Неизвестная команда")
        }
        return .init(snapshot: snapshot(in: store, chatID: chatID))
    }

    private func markProcessed(_ requestID: UUID, peerIndex: Int) throws {
        peers[peerIndex].processedRequests.append(requestID)
        if peers[peerIndex].processedRequests.count > 256 {
            peers[peerIndex].processedRequests.removeFirst(peers[peerIndex].processedRequests.count - 256)
        }
        try persistPeers()
    }

    private func persistPeers() throws {
        let directory = root.appendingPathComponent("RemoteChat", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(peers).write(to: directory.appendingPathComponent("peers.json"), options: .atomic)
    }

    private func mobileChat(in store: AppStore) -> UUID {
        if let chat = store.chats.first(where: { $0.isMobile == true }) { return chat.id }
        let preferred = store.models.first(where: { $0.id == "builtin-text:qwen3-4b-q4_k_m" })?.id
            ?? store.models.first(where: { !TinyTextPolicy.applies($0) && $0.kind != "embedding" })?.id
            ?? store.preferences.defaultModel
        var chat = Chat(model: preferred)
        chat.title = "iPhone"
        chat.isMobile = true
        if let model = store.preferences.defaultImageModel { chat.imageModel = model }
        store.chats.insert(chat, at: 0)
        store.save()
        return chat.id
    }

    private func snapshot(in store: AppStore, chatID: UUID) -> RemoteSnapshot {
        let chat = store.chats.first(where: { $0.id == chatID })
        let messages = (chat?.messages ?? []).map { message in
            RemoteMessage(id: message.id, role: message.role, text: message.text, status: message.status,
                          createdAt: message.createdAt, attachments: message.attachments.map {
                RemoteAttachment(id: $0.id, name: $0.name, kind: $0.kind)
            })
        }
        let jobs = store.jobs.filter { $0.chatID == chatID && $0.hidden != true }.suffix(5).map {
            RemoteJob(id: $0.id, prompt: $0.displayPrompt ?? $0.prompt, status: $0.status,
                      phase: $0.phase, progress: $0.progress)
        }
        let interaction: RemoteInteraction?
        if store.activeChatID == chatID, let pending = store.pending {
            let kind: String
            switch pending.kind {
            case .question: kind = "question"
            case .approval: kind = "approval"
            case .secret: kind = "secret"
            case .permissions: kind = "permissions"
            }
            interaction = .init(id: pending.id, kind: kind, title: pending.title,
                                detail: pending.detail, choices: pending.choices)
        } else { interaction = nil }
        let commands = SlashCommands.items(plugins: store.preferences.plugins,
                                          canSteer: store.activeChatID == chatID,
                                          skills: store.skills).filter(\.enabled).map {
            RemoteCommand(command: $0.command, title: $0.title, detail: $0.detail)
        }
        let models = store.models.map {
            RemoteModel(id: $0.id, name: $0.name, selected: $0.id == chat?.model,
                        supportsImagePrompt: !TinyTextPolicy.applies($0) && $0.kind != "embedding")
        }
        let imageModels = store.checkpoints.map {
            RemoteModel(id: $0, name: store.imageModelName($0), selected: $0 == chat?.imageModel)
        }
        return .init(title: chat?.title ?? "iPhone", messages: messages, jobs: jobs,
                     interaction: interaction, commands: commands, models: models, imageModels: imageModels,
                     imagePromptModelID: chat?.imagePromptModel)
    }
}

extension AppStore {
    func showMobilePairing(in chatID: UUID) async {
        do {
            let code = try await remoteChat.pairingCode()
            mobilePairing = code
            addMessage(.init(role: "mobile_pairing", text: "Подключить iPhone", detail: code.pairingID.uuidString), to: chatID)
            if await remoteChat.cloudIssue() != nil {
                try? await Task.sleep(for: .seconds(2))
                if let issue = await remoteChat.cloudIssue() {
                    addMessage(.init(role: "assistant", text: "Связь через iCloud пока недоступна: \(issue). Подключение в одной сети работает."), to: chatID)
                }
            }
        } catch { addMessage(.init(role: "assistant", text: error.localizedDescription, status: "error"), to: chatID) }
    }

    @discardableResult
    func sendRemote(_ raw: String, chatID: UUID, requestID: UUID) -> Bool {
        reloadSkills()
        guard canPersist, let i = index(chatID) else { return false }
        if jobs.contains(where: { $0.sourceMessageID == requestID }) ||
            chats[i].messages.contains(where: { $0.id == requestID }) { return true }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let redacted = vault.redact(text)
        guard redacted == text else {
            addMessage(.init(role: "assistant", text: "Обнаружен ключ. Вводите его через защищённый вопрос агента."), to: chatID)
            return true
        }
        if handleTaskControlMessage(text, chatID: chatID) { return true }
        if busy, activeChatID == chatID {
            for prefix in ["/steer ", "Уточнение:", "Корректировка:"] where text.lowercased().hasPrefix(prefix.lowercased()) {
                if steerCurrentTask(String(text.dropFirst(prefix.count))) { return true }
            }
        }
        let executionPrompt: String
        do { executionPrompt = chats[i].isClean ? text : (try skillPrompt(text) ?? SlashCommands.pluginPrompt(text, plugins: preferences.plugins) ?? text) }
        catch { addMessage(.init(role: "assistant", text: error.localizedDescription, status: "error"), to: chatID); return true }
        let count = chats[i].messages.count
        if !chats[i].isClean && handleLocalCommand(text, chatID: chatID) {
            if let index = index(chatID) { chats[index].messages.insert(.init(id: requestID, role: "user", text: text), at: min(count, chats[index].messages.count)); save() }
            return true
        }
        enqueue(prompt: executionPrompt, attachments: [], chatID: chatID,
                sourceMessageID: requestID, displayPrompt: text)
        return true
    }
}
