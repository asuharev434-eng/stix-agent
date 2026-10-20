import XCTest
@testable import STIXAgent

final class LocalMLXTextEngineTests: XCTestCase {
    func testNativeToolEventsReachAgentAndRejectUnlistedTools() throws {
        let raw = #"""
        STIX_EVENT:{"type":"tool","name":"write_file","arguments":"{\"path\":\"note.txt\",\"content\":\"ok\"}","id":"call-1"}
        STIX_EVENT:{"type":"done"}
        """#
        let reply = try LocalMLXTextEngine.parseEvents(raw, allowed: ["write_file"])
        XCTAssertEqual(reply.toolCalls.map(\.name), ["write_file"], reply.content)
        XCTAssertEqual(reply.toolCalls.first?.id, "call-1")
        XCTAssertEqual(try JSONValue.parse(XCTUnwrap(reply.toolCalls.first?.arguments))["content"].string, "ok")
        XCTAssertThrowsError(try LocalMLXTextEngine.parseEvents(raw, allowed: ["read_file"]))
        XCTAssertThrowsError(try LocalMLXTextEngine.parseEvents("STIX_EVENT:{\"type\":\"text\",\"text\":\"ok\"}", allowed: []))
        XCTAssertThrowsError(try LocalMLXTextEngine.parseEvents("STIX_EVENT:{\"type\":\"done\"}", allowed: []))
    }

    func testMLXProviderResolvesWithoutLMStudio() throws {
        let ref = try ModelRef.resolveText("mlx-text:abc")
        XCTAssertEqual(ref.provider, .localMLX)
        XCTAssertEqual(ref.id, "abc")
        let engine = LocalMLXTextEngine(directory: URL(fileURLWithPath: "/tmp/stix-mlx-test"),
                                        executable: URL(fileURLWithPath: "/bin/true"))
        let registry = InferenceRegistry(externalText: LMStudioTextEngine(client: .init(endpoint: "http://127.0.0.1:1")),
                                         externalImage: ComfyImageEngine(client: .init(endpoint: "http://127.0.0.1:1")),
                                         localMLX: engine)
        let resolved = try registry.text(for: "mlx-text:abc")
        XCTAssertEqual(resolved.0.provider, .localMLX)
    }

    func testImportCopiesModelDirectoryAndPreservesManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stix-mlx-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let destination = root.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"model_type":"gpt_oss"}"#.utf8).write(to: source.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: source.appendingPathComponent("tokenizer_config.json"))
        try Data(repeating: 1, count: 1024).write(to: source.appendingPathComponent("model.safetensors"))
        let engine = LocalMLXTextEngine(directory: destination, executable: URL(fileURLWithPath: "/bin/true"))
        let record = try await engine.importDirectory(source)
        XCTAssertEqual(record.modelType, "gpt_oss")
        XCTAssertFalse(record.vision)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(record.directoryName + "/model.safetensors").path))
        try FileManager.default.removeItem(at: source)
        let reopened = LocalMLXTextEngine(directory: destination, executable: URL(fileURLWithPath: "/bin/true"))
        let models = try await reopened.models()
        XCTAssertEqual(models.map(\.id), ["mlx-text:" + record.id])
    }

    func testLiveLocalMLXModel() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let modelPath = env["STIX_MLX_MODEL"], let runnerPath = env["STIX_MLX_RUNNER"] else {
            throw XCTSkip("Set STIX_MLX_MODEL and STIX_MLX_RUNNER for an offline live model test")
        }
        let target = env["STIX_MLX_IMPORT_TARGET"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("stix-mlx-live-" + UUID().uuidString)
        let temporary = env["STIX_MLX_IMPORT_TARGET"] == nil
        defer { if temporary { try? FileManager.default.removeItem(at: target) } }
        let engine = LocalMLXTextEngine(directory: target, executable: URL(fileURLWithPath: runnerPath))
        let model = try await engine.importDirectory(URL(fileURLWithPath: modelPath))
        let reply = try await engine.complete(model: model.id,
                                              messages: [.init(role: "user", content: "Сколько будет 2+2? Ответь одной цифрой.")],
                                              tools: [], maxOutputTokens: 128, preserveContext: false,
                                              thinking: false, onPhase: { _ in }, onRequest: { _ in },
                                              onReasoning: { _ in }, onText: { _ in })
        XCTAssertTrue(reply.content.contains("4"), reply.content)
    }

    func testLiveAppOwnedMLXToolCall() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["STIX_MLX_OWNED_DIRECTORY"],
              let modelID = env["STIX_MLX_OWNED_MODEL_ID"],
              let runner = env["STIX_MLX_RUNNER"] else {
            throw XCTSkip("Set STIX_MLX_OWNED_DIRECTORY, STIX_MLX_OWNED_MODEL_ID and STIX_MLX_RUNNER")
        }
        let engine = LocalMLXTextEngine(directory: URL(fileURLWithPath: directory),
                                        executable: URL(fileURLWithPath: runner))
        let tool = ToolDefinition(name: "write_file", description: "Create a UTF-8 file",
                                  parameters: .object([
                                    "type": .string("object"),
                                    "properties": .object([
                                        "path": .object(["type": .string("string")]),
                                        "content": .object(["type": .string("string")])
                                    ]),
                                    "required": .array([.string("path"), .string("content")])
                                  ]))
        let reply = try await engine.complete(model: modelID,
            messages: [.init(role: "user", content: "Используй только write_file: создай note.txt с текстом OK. Верни вызов инструмента JSON, без пояснений.")],
            tools: [tool], maxOutputTokens: 256, preserveContext: false, thinking: false,
            onPhase: { _ in }, onRequest: { _ in }, onReasoning: { _ in }, onText: { _ in })
        XCTAssertEqual(reply.toolCalls.map(\.name), ["write_file"], reply.content)
        let arguments = try JSONValue.parse(XCTUnwrap(reply.toolCalls.first?.arguments))
        XCTAssertEqual(arguments["path"].string, "note.txt")
        XCTAssertEqual(arguments["content"].string, "OK")
    }

    func testLiveAppOwnedMLXVision() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["STIX_MLX_OWNED_DIRECTORY"],
              let modelID = env["STIX_MLX_OWNED_MODEL_ID"],
              let runner = env["STIX_MLX_RUNNER"],
              let image = env["STIX_MLX_TEST_IMAGE"] else {
            throw XCTSkip("Set STIX_MLX_OWNED_DIRECTORY, STIX_MLX_OWNED_MODEL_ID, STIX_MLX_RUNNER and STIX_MLX_TEST_IMAGE")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: image))
        let engine = LocalMLXTextEngine(directory: URL(fileURLWithPath: directory),
                                        executable: URL(fileURLWithPath: runner))
        let reply = try await engine.complete(model: modelID,
            messages: [.init(role: "user", content: "What color is the mug in this image? Answer with one color word.",
                             imageURLs: ["data:image/png;base64," + data.base64EncodedString()])],
            tools: [], maxOutputTokens: 256, preserveContext: false, thinking: false,
            onPhase: { _ in }, onRequest: { _ in }, onReasoning: { _ in }, onText: { _ in })
        XCTAssertTrue(reply.content.lowercased().contains("red"), reply.content)
    }
}
