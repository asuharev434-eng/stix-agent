import XCTest
@testable import STIXAgent

final class LlamaNativeTests: XCTestCase {
    func testLocalMetalGenerationWithoutServer() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["STIX_TEST_GGUF"],
              let bridgePath = environment["STIX_TEST_LLAMA_BRIDGE"] else {
            throw XCTSkip("Set STIX_TEST_GGUF and STIX_TEST_LLAMA_BRIDGE for the native integration test")
        }
        let engine = LlamaTextEngine(modelID: "test-qwen", modelURL: URL(fileURLWithPath: modelPath),
                                     expectedSHA256: environment["STIX_TEST_GGUF_SHA256"] ?? "da2572f16c06133561ce56accaa822216f2391ef4d37fba427801cd6736417d4",
                                     libraryURL: URL(fileURLWithPath: bridgePath), contextLength: 4096)
        let available = try await engine.models()
        XCTAssertEqual(available.first?.id, "builtin-text:test-qwen")
        let reply = try await engine.complete(model: "test-qwen",
                                              messages: [.init(role: "system", content: "Отвечай кратко по-русски."),
                                                         .init(role: "user", content: "Сколько будет 17 + 25?")],
                                              tools: [], maxOutputTokens: 64, preserveContext: false,
                                              thinking: false, onPhase: { _ in }, onRequest: { _ in },
                                              onReasoning: { _ in }, onText: { _ in })
        XCTAssertTrue(reply.content.contains("42"), "Expected a correct offline arithmetic response: \(reply.content)")
        XCTAssertTrue(reply.toolCalls.isEmpty)
        await engine.release()
    }
}
