import XCTest
@testable import STIXAgent

final class BuiltInToolExposureTests: XCTestCase {
    @MainActor func testQuestionDoesNotExposeToolsToSmallLocalModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        let id = try XCTUnwrap(store.selectedID)
        store.setModel("builtin-text:qwen3-4b-q4_k_m", image: false)
        let prompt = "Сколько будет 17 + 25? Ответь одним числом."
        XCTAssertTrue(store.toolsForRequest(chatID: id, system: store.systemPrompt(chatID: id), currentRequest: prompt).isEmpty)
    }

    @MainActor func testFileTaskExposesRelevantActions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        let id = try XCTUnwrap(store.selectedID)
        store.setModel("builtin-text:qwen3-4b-q4_k_m", image: false)
        let tools = store.toolsForRequest(chatID: id, system: store.systemPrompt(chatID: id),
                                          currentRequest: "Создай файл /tmp/example.txt с текстом Привет")
        XCTAssertTrue(tools.contains { $0.name == "write_file" })
        XCTAssertTrue(tools.contains { $0.name == "discover_tools" })
        XCTAssertLessThanOrEqual(tools.count, 7)
    }
}
