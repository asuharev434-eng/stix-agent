import XCTest
import ImageIO
@testable import STIXAgent

final class LiveFeatureTests: XCTestCase {
    private func requireLive() throws {
        guard ProcessInfo.processInfo.environment["STIX_AGENT_LIVE_FEATURES"] == "1" else { throw XCTSkip("Enable local expanded feature smoke tests explicitly") }
    }
    @MainActor func testLocalPromptAdaptationAndThinkingTransport() async throws {
        try requireLive()
        let model = ProcessInfo.processInfo.environment["STIX_AGENT_TEST_MODEL"] ?? "qwen3-8b-abliterated"
        let client = LMStudioClient(endpoint: "http://127.0.0.1:1235")
        let reply = try await client.complete(model: model, messages: ImagePromptAdapter.messages(request: .init(prompt: "Красная керамическая кружка на белом столе"), imageModel: "sd_xl_base_1.0.safetensors", workflow: nil, language: "en"), tools: [], thinking: true) { _ in }
        let adapted = try ImagePromptAdapter.parse(reply.content)
        XCTAssertFalse(adapted.prompt.isEmpty); XCTAssertFalse(reply.content.contains("<think>")); XCTAssertTrue(reply.toolCalls.isEmpty)
    }
    @MainActor func testLocalSpecialistLeavesMainModelSelected() async throws {
        try requireLive()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        store.preferences.lmEndpoint = "http://127.0.0.1:1235"
        store.models = try await LMStudioClient(endpoint: store.preferences.lmEndpoint).models()
        let id = try XCTUnwrap(store.selectedID)
        store.chats[0].model = "main-selection-preserved"
        let model = ProcessInfo.processInfo.environment["STIX_AGENT_TEST_MODEL"] ?? "qwen3-8b-abliterated"
        let result = try await store.delegateModel(.object(["model_id": .string(model), "reason": .string("local smoke"), "task": .string("Ответь только числом: 2+2")]), chatID: id)
        XCTAssertTrue(result.text.contains("4")); XCTAssertEqual(store.currentChat?.model, "main-selection-preserved")
    }
    func testLocalComfyResizeAndEditOwnFixture() async throws {
        try requireLive()
        let client = ComfyClient(endpoint: "http://127.0.0.1:8188")
        let (queue, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:8188/queue")!)
        let state = try JSONDecoder().decode(JSONValue.self, from: queue)
        guard state["queue_running"].array?.isEmpty == true, state["queue_pending"].array?.isEmpty == true else { throw XCTSkip("User Comfy queue active; do not interfere") }
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/smoke-image.png")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Own generated fixture missing") }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let resized = try await client.generate(request: .init(prompt: "", inputImagePath: source.path, width: 512, height: 512, resizeOnly: true), checkpoint: "", outputDirectory: output) { _ in }
        let url = try XCTUnwrap(resized.first)
        let image = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any])
        XCTAssertEqual(properties[kCGImagePropertyPixelWidth as String] as? Int, 512)
        let edited = try await client.generate(request: .init(prompt: "a red ceramic mug on a white table, bright natural light", inputImagePath: url.path, width: 512, height: 512, steps: 1, denoise: 0.2), checkpoint: "sd_xl_base_1.0.safetensors", outputDirectory: output) { _ in }
        XCTAssertFalse(edited.isEmpty); XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let proof = source.deletingLastPathComponent().appendingPathComponent("smoke-image-edit.png")
        try Data(contentsOf: XCTUnwrap(edited.first)).write(to: proof, options: .atomic)
        try await client.releaseModelsIfIdle()
    }
}
