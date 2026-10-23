import XCTest
@testable import STIXAgent

final class InstalledModelImportTests: XCTestCase {
    func testExplicitGGUFImportIntoAppOwnedStorage() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["STIX_IMPORT_GGUF_SOURCE"], let root = env["STIX_IMPORT_ROOT"],
              let bridge = env["STIX_IMPORT_LLAMA_BRIDGE"] else {
            throw XCTSkip("Set explicit source, app data root and bridge for an installed model import")
        }
        let library = LocalModelLibrary(bundled: nil, directory: URL(fileURLWithPath: root).appendingPathComponent("Models"),
                                        libraryURL: URL(fileURLWithPath: bridge))
        let record = try await library.importFile(URL(fileURLWithPath: source))
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent("Models/" + record.fileName).path))
        XCTAssertEqual(record.sha256.count, 64)
        if env["STIX_IMPORT_SELECT_CURRENT"] == "1" {
            let storage = StateStorage(paths: .init(root: URL(fileURLWithPath: root)))
            var state = try XCTUnwrap(storage.load())
            let originalChatIDs = state.chats.map(\.id)
            let index = try XCTUnwrap(state.chats.indices.first)
            let selected = "builtin-text:" + record.id
            state.chats[index].model = selected
            state.preferences.defaultModel = selected
            try storage.save(state)
            let saved = try XCTUnwrap(storage.load())
            XCTAssertEqual(saved.chats.map(\.id), originalChatIDs)
            XCTAssertEqual(saved.chats[index].model, selected)
            XCTAssertEqual(saved.preferences.defaultModel, selected)
            if let oldSHA = env["STIX_IMPORT_REMOVE_REPLACED_SHA"] {
                let records = try await library.importedModels()
                if let old = records.first(where: { $0.sha256 == oldSHA && $0.id != record.id }) {
                    let oldID = "builtin-text:" + old.id
                    guard !saved.chats.contains(where: { $0.model == oldID || $0.imagePromptModel == oldID }),
                          !(saved.preferences.modelRoles?.values.contains(oldID) ?? false),
                          saved.preferences.defaultModel != oldID else {
                        throw AgentError.message("Replaced model is still referenced; preserved its files")
                    }
                    try await library.remove(old.id)
                }
            }
        }
    }

    func testExplicitCheckpointImportIntoAppOwnedStorage() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["STIX_IMPORT_IMAGE_SOURCE"], let root = env["STIX_IMPORT_ROOT"],
              let engine = env["STIX_IMPORT_SDCPP_ENGINE"] else {
            throw XCTSkip("Set explicit source, app data root and image engine for an installed model import")
        }
        let library = LocalCheckpointImageEngine(directory: URL(fileURLWithPath: root).appendingPathComponent("Models/ImageCheckpoints"),
                                                 executable: URL(fileURLWithPath: engine))
        let record = try await library.importFile(URL(fileURLWithPath: source))
        XCTAssertEqual(record.sha256.count, 64)
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: root).appendingPathComponent("Models/ImageCheckpoints/" + record.fileName).path))
    }
}
