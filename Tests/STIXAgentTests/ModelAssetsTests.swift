import XCTest
@testable import STIXAgent

final class ModelAssetsTests: XCTestCase {
    func testMalformedGGUFIsRejectedWithoutChangingManifest() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bogus = root.appendingPathComponent("broken.gguf")
        try Data(repeating: 0, count: 2048).write(to: bogus)
        let library = LocalModelLibrary(bundled: nil, directory: root.appendingPathComponent("Models"), libraryURL: bogus)
        do { _ = try await library.importFile(bogus); XCTFail("Malformed GGUF accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("GGUF")) }
        let models = try await library.models()
        XCTAssertEqual(models.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Models/manifest.json").path))
    }

    func testRealQwenGGUFImportsAndSurvivesRestart() async throws {
        guard let path = ProcessInfo.processInfo.environment["STIX_TEST_GGUF"] else {
            throw XCTSkip("Set STIX_TEST_GGUF to exercise the real importer")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Models")
        let source = URL(fileURLWithPath: path)
        let bridge = URL(fileURLWithPath: ProcessInfo.processInfo.environment["STIX_TEST_LLAMA_LIB"] ?? source.path)
        let first = LocalModelLibrary(bundled: nil, directory: directory, libraryURL: bridge)
        let record = try await first.importFile(source)
        XCTAssertEqual(record.architecture, "qwen3")
        XCTAssertGreaterThanOrEqual(record.contextLength, 2048)
        let duplicate = try await first.importFile(source)
        XCTAssertEqual(duplicate.id, record.id)
        let restarted = LocalModelLibrary(bundled: nil, directory: directory, libraryURL: bridge)
        let importedModels = try await restarted.models()
        XCTAssertEqual(importedModels.map(\.id), ["builtin-text:" + record.id])
        try await restarted.remove(record.id)
        let remaining = try await restarted.models()
        XCTAssertEqual(remaining.count, 0)
    }
}
