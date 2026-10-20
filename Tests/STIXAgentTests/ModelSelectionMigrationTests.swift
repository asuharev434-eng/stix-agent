import XCTest
@testable import STIXAgent

@MainActor
final class ModelSelectionMigrationTests: XCTestCase {
    func testExistingChatsAndRoleAssignmentsResolveToInstalledModels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stix-model-migration-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: StateStorage(paths: .init(root: root)))
        let chatID = try XCTUnwrap(store.selectedID)
        let chatIndex = try XCTUnwrap(store.index(chatID))
        store.chats[chatIndex].model = "qwen3-8b-abliterated"
        store.chats[chatIndex].imagePromptModel = "qwen/qwen3.5-9b"
        store.chats[chatIndex].imageModel = "sd_xl_base_1.0.safetensors"
        store.preferences.defaultModel = "gpt-oss-20b"
        store.preferences.modelRoles = ["coding": "qwen3-coder-30b-a3b-instruct"]
        store.importedModels = [
            .init(id: "eight", name: "Qwen3 8b Abliterated", fileName: "eight.gguf", sha256: "", bytes: 1,
                  architecture: "qwen3", tokenizer: "", contextLength: 8192),
            .init(id: "coder", name: "Qwen3-Coder-30B-A3B-Instruct", fileName: "coder.gguf", sha256: "", bytes: 1,
                  architecture: "qwen3moe", tokenizer: "", contextLength: 8192)
        ]
        store.importedMLXModels = [
            .init(id: "qwen", name: "Qwen3.5-9B-MLX-4bit", directoryName: "qwen", modelType: "qwen3_5", vision: true,
                  bytes: 1, files: [:]),
            .init(id: "oss", name: "gpt-oss-20b-MXFP4-Q4", directoryName: "oss", modelType: "gpt_oss", vision: false,
                  bytes: 1, files: [:])
        ]
        store.importedImageModels = [
            .init(id: "sdxl", name: "sd_xl_base_1.0", fileName: "sdxl.safetensors", sha256: "", bytes: 1)
        ]
        store.migrateInstalledModelSelections()
        XCTAssertEqual(store.chats[chatIndex].model, "builtin-text:eight")
        XCTAssertEqual(store.chats[chatIndex].imagePromptModel, "mlx-text:qwen")
        XCTAssertEqual(store.chats[chatIndex].imageModel, "local-image:sdxl")
        XCTAssertEqual(store.preferences.defaultModel, "mlx-text:oss")
        XCTAssertEqual(store.preferences.modelRoles?["coding"], "builtin-text:coder")
    }
}
