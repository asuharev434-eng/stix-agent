import XCTest
@testable import STIXAgent

final class GGUFShardImportTests: XCTestCase {
    private func metadataFixture(splitCount: UInt16) -> Data {
        var data = Data("GGUF".utf8)
        func number<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func string(_ value: String) {
            number(UInt64(value.utf8.count)); data.append(contentsOf: value.utf8)
        }
        func text(_ key: String, _ value: String) {
            string(key); number(UInt32(8)); string(value)
        }
        number(UInt32(3)); number(UInt64(1)); number(UInt64(5))
        text("general.architecture", "qwen3")
        text("general.name", "STIX-Ai-0.2-mobile-other")
        text("tokenizer.ggml.model", "gpt2")
        string("qwen3.context_length"); number(UInt32(4)); number(UInt32(4096))
        string("split.count"); number(UInt32(2)); number(splitCount)
        data.append(Data(repeating: 0, count: 2048 - data.count))
        return data
    }

    func testSingleShardCannotBecomeAnInstalledModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("renamed.gguf")
        try metadataFixture(splitCount: 2).write(to: source)
        let directory = root.appendingPathComponent("Models")
        let library = LocalModelLibrary(bundled: nil, directory: directory, libraryURL: source)
        do { _ = try await library.importFile(source); XCTFail("Incomplete GGUF shard accepted") }
        catch { XCTAssertTrue(error.localizedDescription.contains("полный GGUF")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testUnsplitMetadataRemainsSupported() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gguf")
        defer { try? FileManager.default.removeItem(at: url) }
        try metadataFixture(splitCount: 1).write(to: url)
        XCTAssertEqual(try GGUFInspector.inspect(url).contextLength, 4096)
    }
}
