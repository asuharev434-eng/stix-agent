import XCTest
@testable import STIXAgent

final class ContextCompactionTests: XCTestCase {
    private var history: [LMMessage] {
        (0..<12).flatMap { i in [LMMessage(role: "user", content: "Task \(i) " + String(repeating: "a", count: 400)), LMMessage(role: "assistant", content: "Done \(i)")] }
    }
    func testBudgetIncludesSchemasUnicodeImagesAndOutputReserve() {
        let plain = ContextWindow.estimate(limit: 32768, knownLimit: true, system: "rules", tools: [], history: [.init(role: "user", content: "hello")])
        let rich = ContextWindow.estimate(limit: 32768, knownLimit: true, system: String(repeating: "я", count: 100), tools: [.init(name: "tool", description: "schema", parameters: .object([:]))], history: [.init(role: "user", content: "hello", imageURLs: ["data:image/png;base64,x"])])
        XCTAssertGreaterThan(rich.inputTokens, plain.inputTokens)
        XCTAssertGreaterThan(rich.reserveTokens, 0)
        XCTAssertEqual(rich.remainingTokens, max(0, rich.limit - rich.inputTokens - rich.reserveTokens))
        XCTAssertFalse(ContextWindow.estimate(limit: nil, knownLimit: false, system: "", tools: [], history: []).knownLimit)
    }

    func testExistingChatDecodesWithoutCheckpoint() throws {
        let data = try JSONEncoder().encode(Chat(model: "local", history: history))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "contextCheckpoint")
        let decoded = try JSONDecoder().decode(Chat.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.contextCheckpoint)
        XCTAssertEqual(ContextCompaction.effective(history: decoded.history, checkpoint: nil), history)
    }

    func testCheckpointPreservesSourceAndRejectsEditedPrefix() throws {
        let original = history
        let plan = try XCTUnwrap(ContextCompaction.plan(history: original, checkpoint: nil))
        let checkpoint = ContextCompaction.checkpoint(plan: plan, summary: "Keep backups; completed old tasks", model: "local")
        XCTAssertTrue(checkpoint.matches(original))
        var changed = original; changed[0].content = "Edited"
        XCTAssertFalse(checkpoint.matches(changed))
        XCTAssertEqual(ContextCompaction.effective(history: changed, checkpoint: checkpoint), changed)
        XCTAssertEqual(history, original)
        let effective = ContextCompaction.effective(history: original, checkpoint: checkpoint)
        XCTAssertEqual(effective.last, original.last)
        XCTAssertEqual(effective.first?.role, "user")
        XCTAssertLessThan(effective.count, original.count)
    }
    func testLongToolLoopRetainsCurrentRequestAndWholeGroups() throws {
        var source = [LMMessage(role: "user", content: "Keep the original task")]
        for i in 0..<12 {
            source += [.init(role: "assistant", content: nil, toolCalls: [.init(id: "c\(i)", name: "write_file", arguments: "{}")]), .init(role: "tool", content: "Saved \(i)", toolCallID: "c\(i)")]
        }
        let plan = try XCTUnwrap(ContextCompaction.plan(history: source, checkpoint: nil))
        let checkpoint = ContextCompaction.checkpoint(plan: plan, summary: "Writes completed", model: "local")
        let result = ContextCompaction.effective(history: source, checkpoint: checkpoint)
        XCTAssertTrue(result.contains { $0.content == "Keep the original task" })
        XCTAssertEqual(result, ContextSummary.paired(result))
        XCTAssertEqual(source.count, 25)
    }
    func testIncrementalPlanDoesNotSummarizeCoveredPrefixAgain() throws {
        let first = try XCTUnwrap(ContextCompaction.plan(history: history, checkpoint: nil))
        let checkpoint = ContextCompaction.checkpoint(plan: first, summary: "Old summary", model: "local")
        let extended = history + (0..<10).map { LMMessage(role: "user", content: "Follow-up \($0)") }
        let next = try XCTUnwrap(ContextCompaction.plan(history: extended, checkpoint: checkpoint))
        XCTAssertEqual(next.previousSummary, "Old summary")
        XCTAssertEqual(next.source, Array(extended[first.coveredCount..<next.coveredCount]))
        XCTAssertGreaterThan(next.coveredCount, first.coveredCount)
    }

    func testChunksRetainUnicodeToolArgumentsAndDiscardOnlyOldImagePixels() {
        let source = [LMMessage(role: "user", content: String(repeating: "Я 👨‍👩‍👧‍👦 ", count: 200), imageURLs: ["data:image/png;base64,PRIVATEPIXELS"]), .init(role: "assistant", content: nil, toolCalls: [.init(id: "id", name: "write_file", arguments: "{\"path\":\"/tmp/file\"}")])]
        let chunks = ContextCompaction.chunks(source, maximumBytes: 111)
        XCTAssertGreaterThan(chunks.count, 2)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= 111 })
        XCTAssertEqual(chunks.joined(), source.map { ContextCompaction.transcript($0) + "\n" }.joined())
        XCTAssertFalse(chunks.joined().contains("PRIVATEPIXELS"))
        XCTAssertTrue(chunks.joined().contains("write_file"))
    }
    func testNetworkGuardDoesNotSilentlyTruncateCurrentRequest() {
        XCTAssertThrowsError(try ContextBudget.fitted([.init(role: "user", content: String(repeating: "я", count: 30000))], limit: 8192, system: "rules", tools: []))
        let window = ContextWindow.estimate(limit: 8192, knownLimit: true, system: "rules", tools: [], history: [.init(role: "user", content: String(repeating: "x", count: 14000))])
        XCTAssertTrue(window.shouldCompact)
    }
    func testResponseReserveIsSentToLocalServer() throws {
        let body = try LMStudioClient.requestBody(model: "local", messages: [.init(role: "user", content: "test")], tools: [], maxOutputTokens: 1536)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: body)["max_tokens"].int, 1536)
        XCTAssertThrowsError(try LMStudioClient.requestBody(model: "local", messages: [], tools: [], maxOutputTokens: -1))
    }
    @MainActor func testCancellationNeverPublishesCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        store.chats[0].model = "local"; store.chats[0].history = history
        do {
            try await store.compactContext(chatID: store.chats[0].id, summarize: { _, _ in throw CancellationError() })
            XCTFail("Expected cancellation")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(store.chats[0].contextCheckpoint)
        XCTAssertNil(store.compactingChatID)
        XCTAssertEqual(store.chats[0].history, history)
    }
    @MainActor func testFailedWriteNeverPublishesCheckpoint() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        store.chats[0].model = "local"; store.chats[0].history = history
        try FileManager.default.removeItem(at: root)
        try Data("Not a directory".utf8).write(to: root)
        var called = false
        do {
            try await store.compactContext(chatID: store.chats[0].id, summarize: { _, _ in called = true; return "Keep backups" })
            XCTFail("Expected write failure")
        } catch { }
        XCTAssertTrue(called)
        XCTAssertNil(store.chats[0].contextCheckpoint)
        XCTAssertEqual(store.chats[0].history, history)
    }


    @MainActor func testAutomaticCompactionUsesActualBudgetAndPreservesHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        store.chats[0].model = "local"
        store.models = [.init(id: "local", contextLimit: 8192, contextLimitIsLoaded: true)]
        let source = (0..<24).map { LMMessage(role: $0 % 2 == 0 ? "user" : "assistant", content: "Message \($0) " + String(repeating: "x", count: 1000)) }
        store.chats[0].history = source
        var requests = 0
        let result = try await store.preparedContext(chatID: store.chats[0].id, model: "local", system: "rules", tools: [], summarize: { _, _ in requests += 1; return "Goal: keep backups. Completed old messages." })
        XCTAssertGreaterThan(requests, 0)
        XCTAssertNotNil(store.chats[0].contextCheckpoint, store.contextNotices[store.chats[0].id] ?? "No checkpoint")
        XCTAssertEqual(store.chats[0].history, source)
        XCTAssertEqual(result.last, source.last)
        XCTAssertTrue(result.contains { $0.content == source.last(where: { $0.role == "user" })?.content })
        XCTAssertFalse(ContextWindow.estimate(limit: 8192, knownLimit: true, system: "rules", tools: [], history: result).shouldCompact)
    }
    @MainActor func testAutomaticFailureIsNotRetriedOnEveryToolRound() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        store.chats[0].model = "local"
        store.models = [.init(id: "local", contextLimit: 8192, contextLimitIsLoaded: true)]
        store.chats[0].history = history.map { var m = $0; m.content = (m.content ?? "") + String(repeating: "x", count: 1000); return m }
        var requests = 0
        let summarize: ([LMMessage], Int) async throws -> String = { _, _ in requests += 1; throw AgentError.message("Offline") }
        _ = try await store.preparedContext(chatID: store.chats[0].id, model: "local", system: "rules", tools: [], summarize: summarize)
        _ = try await store.preparedContext(chatID: store.chats[0].id, model: "local", system: "rules", tools: [], summarize: summarize)
        XCTAssertEqual(requests, 1)
        XCTAssertNil(store.chats[0].contextCheckpoint)
    }

    @MainActor func testPersistedCheckpointAndFailureDoNotDeleteHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        store.chats[0].model = "local"; store.chats[0].history = history
        let id = store.chats[0].id
        try await store.compactContext(chatID: id, summarize: { _, _ in "Goal: keep backups. Completed tasks 0–9. Next: task 10." })
        let checkpoint = try XCTUnwrap(store.chats[0].contextCheckpoint)
        XCTAssertEqual(store.chats[0].history, history)
        XCTAssertEqual(AppStore(storage: store.storage).chats[0].contextCheckpoint, checkpoint)
        store.chats[0].history += (0..<10).map { .init(role: "user", content: "More \($0)") }
        do { try await store.compactContext(chatID: id, summarize: { _, _ in throw AgentError.message("Offline") }); XCTFail("Expected failure") } catch { }
        XCTAssertEqual(store.chats[0].contextCheckpoint, checkpoint)
        XCTAssertEqual(store.chats[0].history.count, history.count + 10)
    }
    @MainActor func testChangedHistoryCannotPublishStaleSummary() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        store.chats[0].model = "local"; store.chats[0].history = history
        do {
            try await store.compactContext(chatID: store.chats[0].id, summarize: { _, _ in
                store.chats[0].history[0].content = "Changed while summarizing"
                return "Stale summary"
            })
            XCTFail("Expected stale source rejection")
        } catch { }
        XCTAssertNil(store.chats[0].contextCheckpoint)
    }
}
