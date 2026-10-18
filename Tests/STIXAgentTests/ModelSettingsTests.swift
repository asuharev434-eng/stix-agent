import XCTest
@testable import STIXAgent

final class ModelSettingsTests: XCTestCase {
    @MainActor func testChatCommandShowsPersistentFormWithoutStartingModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StateStorage(paths: .init(root: root))
        let store = AppStore(storage: storage)
        store.draft = "Настрой модели"; store.send()
        XCTAssertFalse(store.busy)
        XCTAssertTrue(store.jobs.isEmpty)
        XCTAssertEqual(store.currentChat?.messages.last?.role, "model_settings")
        let restored = AppStore(storage: storage)
        XCTAssertEqual(restored.currentChat?.messages.last?.role, "model_settings")
        XCTAssertTrue(store.allTools().contains { $0.name == "show_model_settings" })
    }
    @MainActor func testAssignmentsPersistResetAndNeverReplaceMainSelection() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StateStorage(paths: .init(root: root)), store = AppStore(storage: storage)
        store.models = [.init(id: "main"), .init(id: "coder")]
        store.setModel("main", image: false)
        _ = try store.configureModelRole(.object(["role": .string("coding"), "model_id": .string("coder")]))
        XCTAssertEqual(AppStore(storage: storage).preferences.modelRoles?["coding"], "coder")
        XCTAssertEqual(store.currentChat?.model, "main")
        XCTAssertThrowsError(try store.configureModelRole(.object(["role": .string("coding"), "model_id": .string("missing")])))
        _ = try store.configureModelRole(.object(["role": .string("coding"), "model_id": .string("auto")]))
        XCTAssertNil(AppStore(storage: storage).preferences.modelRoles?["coding"])
        XCTAssertEqual(store.currentChat?.model, "main")
    }
    func testUnavailableAssignmentFallsBackAndHeavyCoderIsNotAutomatic() {
        let available = [ModelDescriptor(id: "main"), .init(id: "qwen/qwen3.5-9b", kind: "vlm"), .init(id: "qwen3-coder-30b-a3b-instruct")]
        let roles = ModelOrchestrator.effectiveAssignments(installed: available, configured: ["vision": "removed-model"])
        XCTAssertEqual(roles["vision"], "qwen/qwen3.5-9b")
        XCTAssertEqual(roles["coding"], "qwen/qwen3.5-9b")
        XCTAssertEqual(ModelOrchestrator.effectiveAssignments(installed: available, configured: ["coding": "main"])["coding"], "main")
    }
    @MainActor func testImageSettingsAreValidatedAndScopedToOriginalChat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        let original = try XCTUnwrap(store.selectedID)
        store.models = [.init(id: "prompt-model")]; store.checkpoints = ["sdxl"]
        store.newChat()
        store.setTaskImageModel("prompt-model", prompt: true, chatID: original)
        store.setTaskImageModel("sdxl", prompt: false, chatID: original)
        XCTAssertNil(store.currentChat?.imagePromptModel)
        XCTAssertEqual(store.chats.first { $0.id == original }?.imagePromptModel, "prompt-model")
        store.preferences.imageProfiles = [.init(id: "custom", name: "Custom", path: "/tmp/workflow.json")]
        store.setTaskImageModel("workflow:custom", prompt: false, chatID: original)
        XCTAssertEqual(store.chats.first { $0.id == original }?.imageModel, "workflow:custom")
        store.setTaskImageModel("sdxl", prompt: false, chatID: original)
        store.setTaskImageModel("unknown", prompt: false, chatID: original)
        XCTAssertEqual(store.chats.first { $0.id == original }?.imageModel, "sdxl")
        XCTAssertNotNil(store.error)
        store.setTaskImageModel("", prompt: true, chatID: original)
        XCTAssertNil(store.chats.first { $0.id == original }?.imagePromptModel)
    }
}
