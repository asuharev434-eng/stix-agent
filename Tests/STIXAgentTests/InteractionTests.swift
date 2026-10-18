import XCTest
@testable import STIXAgent

final class InteractionTests: XCTestCase {
    @MainActor func testQuestionIsBoundToRunningChatAndAnswerResumes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        let original = try XCTUnwrap(store.selectedID)
        store.activeChatID = original
        let task = Task { await store.interact(.init(kind: .question, title: "Choose", detail: "", choices: ["A", "B"]), chatID: original) }
        await Task.yield()
        XCTAssertTrue(store.pendingHere)
        store.newChat(); XCTAssertFalse(store.pendingHere)
        store.selectChat(original); store.respond(.text("B"))
        let result = await task.value
        guard case .text(let answer) = result else { return XCTFail("Wrong answer kind") }
        XCTAssertEqual(answer, "B"); XCTAssertNil(store.pending)
    }
    @MainActor func testPersistentExactActionApprovalAndRevocation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        let id = try XCTUnwrap(store.selectedID)
        let arguments = JSONValue.object(["command": .string("echo hello")])
        let task = Task { try await store.approve(tool: "run_shell", arguments: arguments, title: "Command", detail: "echo hello", chatID: id) }
        await Task.yield(); XCTAssertNotNil(store.pending)
        store.respond(.always); try await task.value
        let scope = ApprovalPolicy.scope(tool: "run_shell", arguments: arguments)
        XCTAssertTrue(store.preferences.alwaysApprovals.contains(scope))
        try await store.approve(tool: "run_shell", arguments: arguments, title: "Command", detail: "echo hello", chatID: id)
        XCTAssertNil(store.pending)
        XCTAssertTrue(store.handleLocalCommand("/permissions reset", chatID: id))
        XCTAssertTrue(store.preferences.alwaysApprovals.isEmpty)
    }
    @MainActor func testCancellationResolvesPendingContinuation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        let id = try XCTUnwrap(store.selectedID)
        let task = Task { await store.interact(.init(kind: .secret, title: "Key", detail: ""), chatID: id) }
        await Task.yield(); task.cancel()
        let result = await task.value
        guard case .deny = result else { return XCTFail("Cancellation must deny") }
        XCTAssertNil(store.pending); XCTAssertNil(store.continuation)
        XCTAssertFalse(store.currentChat?.messages.contains(where: { $0.text.contains("Key") }) == true)
    }
}
