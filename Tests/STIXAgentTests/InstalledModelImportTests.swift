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
