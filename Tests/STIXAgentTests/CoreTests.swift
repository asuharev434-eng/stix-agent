import XCTest
@testable import STIXAgent

final class CoreTests: XCTestCase {
    func testAssistantOutputRemovesOnlyTrailingProtocolMarkers() {
        XCTAssertEqual(ModelOutput.clean("ready<|im_end|><|endoftext|>"), "ready")
        XCTAssertEqual(ModelOutput.clean("<|endoftext|>"), "")
        XCTAssertEqual(ModelOutput.clean("explain <|endoftext|> here"), "explain <|endoftext|> here")
    }
    func testJSONRoundtripAndValidation() throws {
        let value = try JSONValue.parse(#"{"path":"a","limit":30,"ok":true,"n":null}"#)
        XCTAssertEqual(value["limit"].int, 30)
        XCTAssertEqual(try value.requiredString("path"), "a")
        XCTAssertThrowsError(try value.requiredString("missing"))
        XCTAssertEqual(try JSONValue.parse(value.encoded), value)
    }
    func testExactApprovalDeterministicAndScoped() throws {
        let first = try JSONValue.parse(#"{"command":"echo a","timeout":12}"#)
        let reordered = try JSONValue.parse(#"{"timeout":12,"command":"echo a"}"#)
        XCTAssertEqual(ApprovalPolicy.scope(tool: "run_shell", arguments: first), ApprovalPolicy.scope(tool: "run_shell", arguments: reordered))
        XCTAssertNotEqual(ApprovalPolicy.scope(tool: "run_shell", arguments: first), ApprovalPolicy.scope(tool: "other", arguments: first))
        XCTAssertNotEqual(ApprovalPolicy.scope(tool: "run_shell", arguments: first), ApprovalPolicy.scope(tool: "run_shell", arguments: .object(["command": .string("echo b")])) )
    }
    func testSecretRedactionLiteralEncodedAndPattern() {
        let vault = SecretVault(); vault.remember("private-test-value")
        let text = "private-test-value \(Data("private-test-value".utf8).base64EncodedString()) sk-proj-abcdefghijklmnopqrstuvwxyz0123456789"
        let redacted = vault.redact(text)
        XCTAssertFalse(redacted.contains("private-test-value"))
        XCTAssertFalse(redacted.contains("cHJpdmF0ZS"))
        XCTAssertFalse(redacted.contains("sk-proj-"))
        vault.remember("password\"with\nnewline")
        let encoded = String(data: try! JSONEncoder().encode("password\"with\nnewline"), encoding: .utf8)!
        XCTAssertFalse(vault.redact(encoded).contains("password"))
    }
    func testKeychainRoundTripWithDisposableNoncredential() throws {
        let id = "test." + UUID().uuidString
        let vault = SecretVault()
        defer { try? vault.remove(id) }
        try vault.set("disposable-noncredential-value", for: id)
        XCTAssertEqual(try vault.get(id), "disposable-noncredential-value")
        XCTAssertFalse(vault.redact("value=disposable-noncredential-value").contains("disposable-noncredential-value"))
        try vault.remove(id)
        XCTAssertThrowsError(try vault.get(id))
    }
    func testStreamingRedactorHoldsPartialSecrets() {
        let vault = SecretVault(); vault.remember("abc-private-secret")
        XCTAssertEqual(vault.redactStreaming("value: abc-pri"), "value: ")
        XCTAssertFalse(vault.redactStreaming("value: abc-private-secret done").contains("abc-private"))
        XCTAssertFalse(vault.redactStreaming("sk-proj-abc").contains("sk-proj"))
    }
    func testStateStoragePreservesPreviousAndRoundtrips() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StateStorage(paths: .init(root: root))
        var chat = Chat(); chat.messages = [.init(role: "user", text: "hello")]
        try storage.save(.init(chats: [chat], preferences: .init()))
        chat.title = "changed"
        try storage.save(.init(chats: [chat], preferences: .init()))
        XCTAssertEqual(try storage.load()?.chats.first?.title, "changed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("state.previous.json").path))
    }
    func testAPIRejectsCrossOriginAndTraversal() throws {
        XCTAssertEqual(try APIClient.requestURL(baseURL: "https://example.org/api", path: "models?limit=2").absoluteString, "https://example.org/api/models?limit=2")
        for path in ["https://evil.test/a", "//evil.test", "../private", "a#secret"] {
            XCTAssertThrowsError(try APIClient.requestURL(baseURL: "https://example.org/api", path: path))
        }
        XCTAssertThrowsError(try ApprovalPolicy.validateEndpoint("http://external.test"))
        XCTAssertThrowsError(try ApprovalPolicy.validateEndpoint("https://example.org", localOnly: true))
    }
    @MainActor func testDirectImageRoutingAndThemeWithoutModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: StateStorage(paths: .init(root: root)))
        store.draft = "Включи тёмную тему в этом приложении"; store.send()
        XCTAssertEqual(store.preferences.theme, "dark")
        XCTAssertFalse(store.busy)
        XCTAssertEqual(store.currentChat?.history.count, 0)
        store.draft = "/help"; store.send()
        XCTAssertTrue(store.currentChat?.messages.last?.text.contains("/image") == true)
    }
    @MainActor func testImageCommandBypassesLanguageModelEvenWhenComfyUnavailable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        store.preferences.comfyEndpoint = "http://127.0.0.1:1"
        store.preferences.lmEndpoint = "http://127.0.0.1:2"
        store.draft = "/image a ceramic mug"
        store.send()
        let deadline = Date().addingTimeInterval(5)
        while store.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        if store.busy { store.stop() }
        XCTAssertEqual(store.currentChat?.history.count, 0)
        XCTAssertTrue(store.currentChat?.messages.contains(where: { $0.toolName == "image" }) == true)
    }
    @MainActor func testRepairsIncompleteToolHistory() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: StateStorage(paths: .init(root: root)))
        var messages: [LMMessage] = [.init(role: "assistant", content: nil, toolCalls: [.init(id: "1", name: "write_file", arguments: "{}"), .init(id: "2", name: "read_file", arguments: "{}")]), .init(role: "tool", content: "ok", toolCallID: "1")]
        store.repairHistory(&messages)
        XCTAssertEqual(messages.count, 3)
        XCTAssertEqual(messages.last?.toolCallID, "2")
    }
}
