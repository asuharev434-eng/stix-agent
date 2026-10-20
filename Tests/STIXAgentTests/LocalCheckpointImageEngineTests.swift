import Foundation
import ImageIO
import XCTest
@testable import STIXAgent

final class LocalCheckpointImageEngineTests: XCTestCase {
    func testImportedCheckpointHasAppOwnedCopyAndStableIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stix-checkpoint-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("My SDXL.safetensors")
        let header = Data("{\"test.weight\":{\"dtype\":\"F16\",\"shape\":[1],\"data_offsets\":[0,2]}}".utf8)
        var bytes = Data()
        var length = UInt64(header.count).littleEndian
        withUnsafeBytes(of: &length) { bytes.append(contentsOf: $0) }
        bytes.append(header)
        bytes.append(Data(repeating: 0, count: 1024))
        try bytes.write(to: original)
        let engine = LocalCheckpointImageEngine(directory: root.appendingPathComponent("owned"),
                                                executable: URL(fileURLWithPath: "/usr/bin/true"))
        let first = try await engine.importFile(original)
        let second = try await engine.importFile(original)
        XCTAssertEqual(first.id, second.id)
        let listed = try await engine.models().map(\.id)
        XCTAssertEqual(listed, ["local-image:" + first.id])
        try FileManager.default.removeItem(at: original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("owned/" + first.fileName).path))
        let reloaded = LocalCheckpointImageEngine(directory: root.appendingPathComponent("owned"),
                                                  executable: URL(fileURLWithPath: "/usr/bin/true"))
        let restored = try await reloaded.models().map(\.id)
        XCTAssertEqual(restored, ["local-image:" + first.id])
    }

    func testCheckpointProviderDoesNotResolveToComfyUI() throws {
        let ref = try ModelRef.resolveImage("local-image:imported-1234567890abcdef")
        XCTAssertEqual(ref.provider, .localCheckpoint)
        XCTAssertEqual(ref.id, "imported-1234567890abcdef")
    }

    func testLiveStandaloneSDXLGeneration() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["STIX_SDCPP_MODEL"],
              let binaryPath = environment["STIX_SDCPP_BIN"] else {
            throw XCTSkip("Set STIX_SDCPP_MODEL and STIX_SDCPP_BIN for the live offline checkpoint test")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("stix-sdxl-live-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owned = root.appendingPathComponent("models")
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: owned, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: modelPath)
        let target = owned.appendingPathComponent("test.safetensors")
        try FileManager.default.linkItem(at: source, to: target)
        let size = (try FileManager.default.attributesOfItem(atPath: target.path)[.size] as? NSNumber)!.int64Value
        let record = ImportedImageCheckpoint(id: "test", name: "Test SDXL", fileName: target.lastPathComponent,
                                             sha256: "test", bytes: size)
        try JSONEncoder().encode([record]).write(to: owned.appendingPathComponent("manifest.json"))
        let engine = LocalCheckpointImageEngine(directory: owned, executable: URL(fileURLWithPath: binaryPath))
        var request = ImageRequest(prompt: "portrait of a woman in a blue coat, realistic photo")
        request.width = 512; request.height = 512; request.steps = 8; request.seed = 42
        let images = try await engine.generate(request: request, model: "test", outputDirectory: output,
                                               workflow: nil, onStepProgress: { _, _ in }, onProgress: { _ in })
        XCTAssertEqual(images.count, 1)
        let fileSize = (try FileManager.default.attributesOfItem(atPath: images[0].path)[.size] as? NSNumber)!.intValue
        XCTAssertGreaterThan(fileSize, 100_000, "Blank white image indicates a Metal CFG regression")
        let sourceImage = try XCTUnwrap(CGImageSourceCreateWithURL(images[0] as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(sourceImage, 0, nil))
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.height, 512)
    }
}
