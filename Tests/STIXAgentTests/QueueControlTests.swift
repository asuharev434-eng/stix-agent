import XCTest
@testable import STIXAgent

final class QueueControlTests: XCTestCase {
    @MainActor func testQueuedEditsReorderAndSteeringRemainDurableWithoutExecuting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StateStorage(paths: .init(root: root)), store = AppStore(storage: storage)
        let chat = try XCTUnwrap(store.selectedID)
        let first = ChatMessage(role: "user", text: "first")
        store.addMessage(first, to: chat)
        store.jobs = [.init(chatID: chat, prompt: "active", status: "running"), .init(chatID: chat, prompt: "first", sourceMessageID: first.id), .init(chatID: chat, prompt: "second")]
        store.activeJobID = store.jobs[0].id; store.activeChatID = chat; store.busy = true
        let queued = store.jobs[1].id
        store.editQueuedJob(queued, prompt: "updated")
        XCTAssertEqual(store.currentChat?.messages.first?.text, "updated")
        XCTAssertEqual(store.jobs[1].displayPrompt, "updated")
        store.moveQueuedJob(queued, offset: 1)
        XCTAssertEqual(store.jobs.last?.id, queued)
        store.steerQueuedJob(queued)
        XCTAssertEqual(store.jobs.last?.status, "cancelled")
        XCTAssertTrue(store.applyPendingCorrections(chatID: chat))
        XCTAssertFalse(store.applyPendingCorrections(chatID: chat))
        XCTAssertTrue(store.currentChat?.history.last?.content?.contains("updated") == true)
        XCTAssertEqual(store.currentChat?.history.last?.sourceMessageID, store.currentChat?.messages.last?.id)
        XCTAssertNil(store.task)
        let restored = AppStore(storage: storage)
        XCTAssertEqual(restored.currentChat?.history, store.currentChat?.history)
    }
    @MainActor func testQueuedMessagesAppearOnlyWhenTheirJobStarts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StateStorage(paths: .init(root: root))
        let store = AppStore(storage: storage), chat = try XCTUnwrap(store.selectedID)
        store.busy = true
        store.draft = "Первое сообщение"
        store.send()
        store.draft = "Второе сообщение"
        store.send()
        XCTAssertEqual(store.jobs.map(\.status), ["queued", "queued"])
        XCTAssertTrue(store.currentChat?.messages.isEmpty == true)
        XCTAssertEqual(store.jobs.map { $0.displayPrompt }, ["Первое сообщение", "Второе сообщение"])

        let restored = AppStore(storage: storage)
        XCTAssertEqual(restored.jobs.map(\.status), ["queued", "queued"])
        XCTAssertTrue(restored.currentChat?.messages.isEmpty == true)
        restored.revealQueuedInput(restored.jobs[0].id)
        XCTAssertEqual(restored.currentChat?.messages.map(\.text), ["Первое сообщение"])
        restored.revealQueuedInput(restored.jobs[0].id)
        XCTAssertEqual(restored.currentChat?.messages.count, 1)
        restored.cancelJob(restored.jobs[1].id)
        XCTAssertEqual(restored.currentChat?.messages.count, 1)
    }
    @MainActor func testCorrectionsResolveObsoleteApprovalAndProtectSecretInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root))), chat = try XCTUnwrap(store.selectedID)
        store.jobs = [.init(chatID: chat, prompt: "active", status: "running")]
        store.activeJobID = store.jobs[0].id; store.activeChatID = chat; store.busy = true
        let waiting = Task { await store.interact(.init(kind: .approval, title: "Old plan", detail: ""), chatID: chat) }
        while store.continuation == nil { await Task.yield() }
        XCTAssertTrue(store.steerCurrentTask("use a different file"))
        guard case .deny = await waiting.value else { return XCTFail("Old approval must be denied") }
        XCTAssertTrue(store.hasPendingCorrections(chatID: chat))
        store.pending = .init(kind: .secret, title: "Key", detail: "")
        XCTAssertFalse(store.steerCurrentTask("change request"))
        store.pending = nil; store.vault.remember("fixture-secret-123")
        XCTAssertFalse(store.steerCurrentTask("fixture-secret-123"))
        XCTAssertEqual(store.jobs[0].pendingCorrections?.count, 1)
    }
    @MainActor func testProgressUsesKnownTotalAndDoneCompletes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root))), chat = try XCTUnwrap(store.selectedID)
        store.jobs = [.init(chatID: chat, prompt: "image", status: "running")]; store.activeJobID = store.jobs[0].id
        store.updateImageStep(3, total: 10); XCTAssertEqual(store.jobs[0].progress, 0.3)
        store.updateTaskPhase("Analyzing"); XCTAssertNil(store.jobs[0].progress)
        store.completedTaskStep(); XCTAssertEqual(store.jobs[0].completedSteps, 1)
        store.updateJob(store.jobs[0].id, status: "done"); XCTAssertEqual(store.jobs[0].progress, 1)
    }
}
