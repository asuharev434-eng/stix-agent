import XCTest
@testable import STIXAgent

final class TinyRussianModelTests: XCTestCase {
    func testTinyContextBudgetRejectsLongInputAndReservesOutput() throws {
        XCTAssertEqual(try TinyTextPolicy.outputLimit(question: "Привет!", context: 128), 104)
        XCTAssertThrowsError(try TinyTextPolicy.outputLimit(question: String(repeating: "я", count: 100), context: 128))
    }

    func testNativeImportRestartAndGeneration() async throws {
        guard let source = ProcessInfo.processInfo.environment["STIX_TINY_GGUF"],
              let bridge = ProcessInfo.processInfo.environment["STIX_TINY_BRIDGE"] else {
            throw XCTSkip("Set STIX_TINY_GGUF and STIX_TINY_BRIDGE to test the real trained model")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let libraryURL = URL(fileURLWithPath: bridge)
        let first = LocalModelLibrary(bundled: nil, directory: root, libraryURL: libraryURL)
        let record = try await first.importFile(URL(fileURLWithPath: source))
        XCTAssertEqual(record.architecture, "gpt2")
        XCTAssertEqual(record.contextLength, 128)
        let restarted = LocalModelLibrary(bundled: nil, directory: root, libraryURL: libraryURL)
        let models = try await restarted.models()
        XCTAssertEqual(models.first?.name, "STIX-AI-0.1 · импортирована")
        let reply = try await restarted.complete(model: record.id,
            messages: [.init(role: "user", content: "Привет!")], tools: [], maxOutputTokens: 80,
            preserveContext: false, thinking: false, onPhase: { _ in }, onRequest: { _ in },
            onReasoning: { _ in }, onText: { _ in })
        XCTAssertEqual(reply.content, "Привет! Чем могу помочь?")
        XCTAssertTrue(reply.toolCalls.isEmpty)
        await restarted.releaseAll()
    }
}
