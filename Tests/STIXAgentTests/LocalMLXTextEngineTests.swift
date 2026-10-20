import XCTest
@testable import STIXAgent

final class LocalMLXTextEngineTests: XCTestCase {
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
}
