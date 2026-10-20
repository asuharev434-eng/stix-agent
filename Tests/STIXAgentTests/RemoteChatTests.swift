import XCTest
import RemoteChatCore
@testable import STIXAgent

final class RemoteChatTests: XCTestCase {
    func testPairingCodeAndEncryptedEnvelope() throws {
        let key = Data((0..<32).map(UInt8.init))
        let code = RemotePairingCode(serviceName: "STIX-Test", host: "test.local", port: 1234,
                                     key: key, expiresAt: .now.addingTimeInterval(300))
        let decoded = try RemotePairingCode.parse(code.encoded())
        XCTAssertEqual(decoded, code)
        let request = RemoteRequest(operation: "send", text: "/image ночной город")
        let envelope = try RemoteEnvelope.seal(request, peerID: code.pairingID, key: key)
        let wire = try JSONEncoder().encode(envelope)
        let framed = try RemoteFraming.encode(wire)
        XCTAssertEqual(try RemoteFraming.payloadLength(framed.prefix(4)), wire.count)
        let opened = try JSONDecoder().decode(RemoteEnvelope.self, from: framed.dropFirst(4))
        XCTAssertEqual(try opened.open(RemoteRequest.self, key: key).text, request.text)
        XCTAssertThrowsError(try opened.open(RemoteRequest.self, key: Data(repeating: 7, count: 32)))
        XCTAssertThrowsError(try RemotePairingCode.parse(code.encoded(), now: .now.addingTimeInterval(301)))
    }

    @MainActor
    func testImagePromptSkipsTinyDefaultAndHonorsCapableSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stix-remote-model-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: StateStorage(paths: AppStoragePaths(root: root)))
        let tiny = ModelDescriptor(id: "builtin-text:tiny", contextLimit: 128)
        let capable = ModelDescriptor(id: "builtin-text:qwen3-4b-q4_k_m", contextLimit: 32768)
        store.models = [tiny, capable]
        var chat = Chat(model: tiny.id)
        XCTAssertEqual(store.imagePromptModel(for: chat), capable.id)
        chat.imagePromptModel = capable.id
        XCTAssertEqual(store.imagePromptModel(for: chat), capable.id)
    }

    @MainActor
    func testLocalPairingAndCommandUseDedicatedChat() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stix-remote-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: StateStorage(paths: AppStoragePaths(root: root)))
        let originalSelection = store.selectedID
        let code = try await store.remoteChat.pairingCode()
        let pairing = RemoteRequest(operation: "pair", deviceName: "Test iPhone")
        let first = try await exchange(pairing, with: code)
        XCTAssertEqual(first.snapshot?.title, "iPhone")
        XCTAssertEqual(store.selectedID, originalSelection)
        XCTAssertEqual(store.chats.filter { $0.isMobile == true }.count, 1)
        let requestID = UUID()
        let command = RemoteRequest(operation: "send", text: "/theme dark")
        let result = try await exchange(command, with: code, requestID: requestID)
        XCTAssertEqual(store.preferences.theme, "dark")
        XCTAssertTrue(result.snapshot?.messages.contains(where: { $0.role == "user" && $0.text == "/theme dark" }) == true)
        _ = try await exchange(command, with: code, requestID: requestID)
        XCTAssertEqual(store.chats.first(where: { $0.isMobile == true })?.messages.filter { $0.text == "/theme dark" }.count, 1)
        if let chatID = store.chats.first(where: { $0.isMobile == true })?.id {
            XCTAssertTrue(store.sendRemote("/theme dark", chatID: chatID, requestID: requestID))
            XCTAssertEqual(store.chats.first(where: { $0.id == chatID })?.messages.filter { $0.id == requestID }.count, 1)
        }
        try? store.vault.remove("mobile." + code.pairingID.uuidString)
    }

    @MainActor private func exchange(_ request: RemoteRequest, with code: RemotePairingCode,
                          requestID: UUID = UUID()) async throws -> RemoteResponse {
        let connection = try await RemoteSocket.connect(host: "127.0.0.1", port: code.port)
        defer { connection.cancel() }
        let sealed = try RemoteEnvelope.seal(request, peerID: code.pairingID, requestID: requestID, key: code.key)
        try await RemoteSocket.send(JSONEncoder().encode(sealed), through: connection)
        let response = try JSONDecoder().decode(RemoteEnvelope.self, from: try await RemoteSocket.receive(connection))
        XCTAssertEqual(response.requestID, requestID)
        return try response.open(RemoteResponse.self, key: code.key)
    }
}
