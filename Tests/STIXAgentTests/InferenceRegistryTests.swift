import XCTest
@testable import STIXAgent

final class InferenceRegistryTests: XCTestCase {
    func testLegacyIdentifiersRemainUnchanged() throws {
        let text = try ModelRef.resolveText("qwen3-coder-30b-a3b-instruct")
        let image = try ModelRef.resolveImage("workflow:portrait")
        XCTAssertEqual(text.provider, .lmStudio)
        XCTAssertEqual(image.provider, .comfyUI)
        XCTAssertEqual(text.storedID, "qwen3-coder-30b-a3b-instruct")
        XCTAssertEqual(image.storedID, "workflow:portrait")
        XCTAssertThrowsError(try ModelRef.resolveText("builtin-image:tiny"))
        XCTAssertThrowsError(try ModelRef.resolveImage("builtin-text:tiny"))
    }

    func testExplicitBuiltInSelectionRoutesToInjectedEngine() async throws {
        let externalText = FakeTextEngine(answer: "external")
        let builtInText = FakeTextEngine(answer: "built-in")
        let externalImage = FakeImageEngine()
        let builtInImage = FakeImageEngine()
        let registry = InferenceRegistry(externalText: externalText, externalImage: externalImage,
                                         builtInText: builtInText, builtInImage: builtInImage)
        let (ref, engine) = try registry.text(for: "builtin-text:qwen")
        XCTAssertEqual(ref.provider, .builtInText)
        XCTAssertEqual(ref.id, "qwen")
        let reply = try await engine.complete(model: ref.id, messages: [.init(role: "user", content: "hi")],
                                              tools: [], maxOutputTokens: nil, preserveContext: false,
                                              thinking: false, onPhase: { _ in }, onRequest: { _ in },
                                              onReasoning: { _ in }, onText: { _ in })
        XCTAssertEqual(reply.content, "built-in")
        let (imageRef, imageEngine) = try registry.image(for: "builtin-image:tiny")
        XCTAssertEqual(imageRef.provider, .builtInImage)
        let urls = try await imageEngine.generate(request: .init(prompt: "cat"), model: imageRef.id,
                                                  outputDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
                                                  workflow: nil, onStepProgress: { _, _ in }, onProgress: { _ in })
        XCTAssertEqual(urls, [])
    }

    func testUnavailableBuiltInEngineIsExplicitError() {
        let registry = InferenceRegistry(externalText: FakeTextEngine(answer: "ok"),
                                         externalImage: FakeImageEngine())
        XCTAssertThrowsError(try registry.text(for: "builtin-text:qwen"))
        XCTAssertThrowsError(try registry.image(for: "builtin-image:tiny"))
    }

    func testOnlyAllowedStructuredToolCallsAreExecutable() {
        let answer = "```json\n{\"tool_calls\":[{\"name\":\"list_files\",\"arguments\":{\"path\":\"/tmp\"}}]}\n```"
        let parsed = LlamaTextEngine.parseToolReply(answer, allowed: ["list_files"])
        XCTAssertEqual(parsed.toolCalls.first?.name, "list_files")
        XCTAssertEqual(parsed.toolCalls.first?.arguments.contains("/tmp"), true)
        XCTAssertTrue(LlamaTextEngine.parseToolReply(answer, allowed: ["write_file"]).toolCalls.isEmpty)
        XCTAssertTrue(LlamaTextEngine.parseToolReply("not JSON", allowed: ["list_files"]).toolCalls.isEmpty)
    }

    func testSuccessiveJSONToolCallsAreExecutedInOrderOnlyWhenAllAreValid() {
        let answer = """
        {"tool_calls":[{"name":"write_file","arguments":{"path":"/tmp/test.txt","content":"Привет"}}]}

        {"tool_calls":[{"name":"read_file","arguments":{"path":"/tmp/test.txt"}}]}
        """
        let parsed = LlamaTextEngine.parseToolReply(answer, allowed: ["write_file", "read_file"])
        XCTAssertEqual(parsed.toolCalls.map(\.name), ["write_file", "read_file"])
        XCTAssertTrue(parsed.content.isEmpty)
        XCTAssertTrue(LlamaTextEngine.parseToolReply(answer, allowed: ["write_file"]).toolCalls.isEmpty)
        XCTAssertTrue(LlamaTextEngine.parseToolReply(answer + "\nГотово", allowed: ["write_file", "read_file"]).toolCalls.isEmpty)
        XCTAssertTrue(LlamaTextEngine.parseToolReply(answer + "\n{", allowed: ["write_file", "read_file"]).toolCalls.isEmpty)
    }
}

private struct FakeTextEngine: TextInferenceEngine {
    let answer: String
    func models() async throws -> [ModelDescriptor] { [ModelDescriptor(id: "fake")] }
    func prepare(model: String) async throws -> Int? { 8192 }
    func complete(model: String, messages: [LMMessage], tools: [ToolDefinition],
                  maxOutputTokens: Int?, preserveContext: Bool, thinking: Bool,
                  onPhase: @escaping @Sendable (String) async -> Void,
                  onRequest: @escaping @Sendable ([LMMessage]) async -> Void,
                  onReasoning: @escaping @Sendable (String) async -> Void,
                  onText: @escaping @Sendable (String) async -> Void) async throws -> LMReply {
        await onRequest(messages)
        await onText(answer)
        return LMReply(content: answer, toolCalls: [])
    }
}

private struct FakeImageEngine: ImageInferenceEngine {
    func models() async throws -> [ModelDescriptor] { [ModelDescriptor(id: "fake", kind: "image")] }
    func releaseIfIdle() async throws {}
    func generate(request: ImageRequest, model: String, outputDirectory: URL,
                  workflow: JSONValue?, onStepProgress: @escaping @Sendable (Int, Int) async -> Void,
                  onProgress: @escaping @Sendable (String) async -> Void) async throws -> [URL] {
        await onStepProgress(1, 1)
        return []
    }
}
