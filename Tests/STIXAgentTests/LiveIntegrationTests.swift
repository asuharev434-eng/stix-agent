import XCTest
@testable import STIXAgent

final class LiveIntegrationTests: XCTestCase {
    private func requireLive() throws {
        guard ProcessInfo.processInfo.environment["STIX_AGENT_LIVE"] == "1" else { throw XCTSkip("Set STIX_AGENT_LIVE=1 to use this Mac's local models") }
    }
    @MainActor func testLocalModelCreatesFileThroughAgentLoop() async throws {
        try requireLive()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("STIXAgent-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: StateStorage(paths: .init(root: root.appendingPathComponent("appdata"))))
        store.preferences.lmEndpoint = "http://127.0.0.1:1235"
        store.newChat(folder: root)
        store.setModel(ProcessInfo.processInfo.environment["STIX_AGENT_TEST_MODEL"] ?? "qwen/qwen3.5-9b", image: false)
        store.draft = "Выполни ровно одно действие: инструментом write_file создай файл agent-smoke.txt в рабочей папке с содержимым LOCAL_AGENT_OK. Не запускай терминал и не задавай вопросы. После записи ответь коротко."
        store.send()
        let deadline = Date().addingTimeInterval(180)
        while store.busy && Date() < deadline { try await Task.sleep(nanoseconds: 200_000_000) }
        if store.busy { store.stop(); XCTFail("Agent did not finish within180s") }
        let target = root.appendingPathComponent("agent-smoke.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), store.currentChat?.messages.map(\.text).joined(separator: "\n") ?? "no chat")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "LOCAL_AGENT_OK")
        XCTAssertTrue(store.currentChat?.history.contains(where: { $0.role == "tool" }) == true)
        XCTAssertEqual(store.currentChat?.messages.last?.status, "done")
        XCTAssertFalse(store.currentChat?.messages.last?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
    func testLocalComfyProducesPNG() async throws {
        try requireLive()
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("STIXAgent-images-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: output) }
        let client = ComfyClient(endpoint: "http://127.0.0.1:8188")
        let checkpoints = try await client.checkpoints()
        XCTAssertTrue(checkpoints.contains("sd_xl_base_1.0.safetensors"))
        let results = try await client.generate(prompt: "a simple red ceramic mug on a white table, natural light, product photograph", checkpoint: "sd_xl_base_1.0.safetensors", outputDirectory: output) { _ in }
        XCTAssertFalse(results.isEmpty)
        let data = try Data(contentsOf: XCTUnwrap(results.first))
        XCTAssertEqual(Array(data.prefix(8)), [137,80,78,71,13,10,26,10])
        XCTAssertGreaterThan(data.count, 10000)
        try await client.releaseModelsIfIdle()
        // Keep a separate proof artifact, without altering the user's chat history.
        let proof = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/smoke-image.png")
        try FileManager.default.createDirectory(at: proof.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: proof, options: .atomic)
    }
}
