import XCTest
@testable import STIXAgent

final class MemoryScopeTests: XCTestCase {
    func testDocumentsRoundtripTextAndProvenance() throws {
        let entry = MemoryEntry(scope: .personal, category: .preferences, text: "Кратко\n\nСохраняй исходник\n", source: "Явная просьба пользователя", order: 0)
        let data = try MemoryDocuments.render([entry], category: .preferences)
        XCTAssertEqual(try MemoryDocuments.parse(data, scope: .personal, ownerID: nil, category: .preferences), [entry])
        XCTAssertThrowsError(try MemoryDocuments.parse(data, scope: .project, ownerID: UUID(), category: .decisions))
    }
    func testRetrievalNeverLeaksOtherProjectOrChat() throws {
        let project = UUID(), chat = UUID()
        let records = [
            MemoryEntry(scope: .personal, category: .preferences, text: "Краткие ответы", source: "User", order: 0),
            MemoryEntry(scope: .project, ownerID: project, category: .decisions, text: "Код Python используем для конвертации", source: "User", order: 1),
            MemoryEntry(scope: .project, ownerID: UUID(), category: .decisions, text: "Код Python PRIVATE_OTHER_PROJECT", source: "User", order: 2),
            MemoryEntry(scope: .chat, ownerID: UUID(), category: .notes, text: "PRIVATE_OTHER_CHAT", source: "User", order: 3)
        ]
        let chosen = MemoryRetrieval.select(records, chatID: chat, projectID: project, query: "Напиши код Python", byteBudget: 3000)
        XCTAssertTrue(chosen.contains { $0.text == "Краткие ответы" })
        XCTAssertTrue(chosen.contains { $0.text.contains("конвертации") })
        XCTAssertFalse(chosen.contains { $0.text.contains("PRIVATE_") })
    }
    func testRelevanceAndBudgetDoNotLoadEverything() {
        let records = (0..<30).map { MemoryEntry(scope: .personal, category: .profile, text: " unrelated \($0) " + String(repeating: "x", count: 1000), source: "User", order: $0) }
        XCTAssertTrue(MemoryRetrieval.select(records, chatID: UUID(), projectID: nil, query: "Изображение", byteBudget: 1000).isEmpty)
    }
    @MainActor func testProjectSharingAndChatIsolationSurviveReload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        store.newChat(folder: URL(fileURLWithPath: "/tmp/scoped-project")); let first = try XCTUnwrap(store.selectedID)
        try store.remember("Проект использует Swift", scope: .project, category: .decisions, chatID: first)
        try store.remember("Только этот чат", scope: .chat, category: .notes, chatID: first)
        store.newChat(folder: URL(fileURLWithPath: "/tmp/scoped-project")); let second = try XCTUnwrap(store.selectedID)
        XCTAssertEqual(store.memoryRecords(scope: .project, chatID: second).count, 1)
        XCTAssertTrue(store.memoryRecords(scope: .chat, chatID: second).isEmpty)
        let loaded = AppStore(storage: store.storage)
        XCTAssertEqual(loaded.memoryRecords(scope: .project, chatID: second).first?.text, "Проект использует Swift")
        XCTAssertEqual(loaded.memoryRecords(scope: .chat, chatID: first).first?.text, "Только этот чат")
        loaded.newChat(folder: URL(fileURLWithPath: "/tmp/scoped-project-other"))
        XCTAssertTrue(loaded.memoryRecords(scope: .project, chatID: try XCTUnwrap(loaded.selectedID)).isEmpty)
    }
}
