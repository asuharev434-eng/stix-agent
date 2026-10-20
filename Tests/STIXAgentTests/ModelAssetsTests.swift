import XCTest
@testable import STIXAgent

final class ModelAssetsTests: XCTestCase {
    func testVisionOutputOmitsDiagnosticPreamble() {
        let log = "0.1 I mtmd_cli_context: chat template example: <channel|>\n" +
            "0.8 I mtmd batch encoding done in 589 ms\n\nДерево в тумане.\n"
        XCTAssertEqual(LocalGGUFVisionEngine.generatedText(from: log), "Дерево в тумане.")
    }
    func testImportedModelWithProjectorIsAdvertisedAsVisionModel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let records = [
            ImportedGGUF(id: "text", name: "Text", fileName: "text.gguf", sha256: "text",
                         bytes: 1000, architecture: "qwen3", tokenizer: "gpt2", contextLength: 4096),
            ImportedGGUF(id: "vision", name: "Vision", fileName: "vision.gguf", sha256: "vision",
                         bytes: 1000, architecture: "gemma4", tokenizer: "gemma4", contextLength: 4096,
                         projectorFileName: "vision-mmproj.gguf", projectorSHA256: String(repeating: "a", count: 64))
        ]
        try JSONEncoder().encode(records).write(to: directory.appendingPathComponent("manifest.json"))
        let library = LocalModelLibrary(bundled: nil, directory: directory, libraryURL: nil)
        let models = try await library.models()
        XCTAssertEqual(models.map(\.kind), ["text", "vlm"])
    }

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
