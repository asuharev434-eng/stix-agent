import XCTest
@testable import STIXAgent

@MainActor
final class ImageRoutingRecoveryTests: XCTestCase {
    func testTextModelDoesNotReceiveImagesFromEarlierTurns() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        let chatID = try XCTUnwrap(store.selectedID)
        let textModel = "builtin-text:imported-text"
        let visionModel = "mlx-text:imported-vision"
        store.models = [.init(id: textModel, kind: "text"), .init(id: visionModel, kind: "vlm")]
        let earlierImage = LMMessage(role: "user", content: "Что на фото?", imageURLs: ["/tmp/photo.png"])
        let latest = LMMessage(role: "user", content: "Привет")
        let history = [earlierImage, latest]

        let textRequest = store.modelMessages(chatID: chatID, model: textModel, system: "Правила", history: history)
        XCTAssertTrue(textRequest.allSatisfy { ($0.imageURLs ?? []).isEmpty })
        XCTAssertEqual(textRequest[1].content, earlierImage.content)
        let visionRequest = store.modelMessages(chatID: chatID, model: visionModel, system: "Правила", history: history)
        XCTAssertEqual(visionRequest[1].imageURLs, ["/tmp/photo.png"])
        XCTAssertEqual(history[0].imageURLs, ["/tmp/photo.png"])
    }

    func testMissingComfyCheckpointFallsBackToImportedLocalModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        let chatID = try XCTUnwrap(store.selectedID)
        let chatIndex = try XCTUnwrap(store.index(chatID))
        let local = ModelDescriptor(id: "local-image:realism", kind: "image")
        store.checkpoints = ["builtin-image:sd15", local.id]
        store.chats[chatIndex].imageModel = "sd_xl_base_1.0.safetensors"
        store.preferences.defaultImageModel = "sd_xl_base_1.0.safetensors"

        store.repairUnavailableImageSelections(builtInImages: [.init(id: "builtin-image:sd15", kind: "image")], localImages: [local])

        XCTAssertEqual(store.chats[chatIndex].imageModel, local.id)
        XCTAssertEqual(store.preferences.defaultImageModel, local.id)
        XCTAssertEqual(AppStore(storage: store.storage).currentChat?.imageModel, local.id)
    }
}
