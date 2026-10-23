import XCTest
@testable import STIXAgent

final class CleanChatTests: XCTestCase {
    @MainActor func testNewCleanChatStartsWithZeroContextAndNoInjectedMessages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        store.newChat(mode: .clean)
        let chatID = try XCTUnwrap(store.selectedID)
        XCTAssertTrue(store.currentChat?.isClean == true)
        XCTAssertTrue(store.currentChat?.history.isEmpty == true)
        XCTAssertEqual(store.systemPrompt(chatID: chatID), "")
        XCTAssertTrue(store.toolsForRequest(chatID: chatID, system: "", currentRequest: "Hello").isEmpty)
        XCTAssertEqual(store.contextWindow(chatID: chatID)?.percentage, 0)
        let user = LMMessage(role: "user", content: "Hello")
        XCTAssertEqual(store.modelMessages(chatID: chatID, model: store.currentChat?.model ?? "", system: "", history: [user]), [user])
        XCTAssertEqual(AppStore(storage: store.storage).chats.first?.mode, .clean)
    }

    @MainActor func testFolderChatUsesFolderNameAndLegacyChatRemainsAgent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        store.newChat(folder: URL(fileURLWithPath: "/tmp/Example Workspace"))
        XCTAssertEqual(store.currentChat?.title, "Example Workspace")
        XCTAssertFalse(store.currentChat?.isClean ?? true)

        let data = try JSONEncoder().encode(Chat(model: "local"))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "mode")
        let legacy = try JSONDecoder().decode(Chat.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(legacy.isClean)
    }
}
