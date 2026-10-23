import XCTest
import AppKit
@testable import STIXAgent

final class ImageEditorTests: XCTestCase {
    func testCommandKeepsPromptLiteralAndRoundTripsPaths() throws {
        let prompt = "change to blue --seed 9\nwith \"sparkles\" and \\ lines"
        let source = Attachment(path: "/tmp/my \"image\" \\ file.png", kind: "image")
        let command = try ImageEditorCommand.make(prompt: prompt, source: source, imageSize: CGSize(width: 1024, height: 768), strength: 0.55, maskPath: "/tmp/mask file.png")
        XCTAssertTrue(command.hasPrefix("/image2image "))
        let parsed = try ImageRequest.parse(command)
        XCTAssertEqual(parsed.prompt, prompt)
        XCTAssertEqual(parsed.inputImagePath, source.path)
        XCTAssertEqual(parsed.maskImagePath, "/tmp/mask file.png")
        XCTAssertEqual(parsed.denoise, 0.55)
        XCTAssertEqual(parsed.width, 1024)
        XCTAssertEqual(parsed.height, 768)
        XCTAssertFalse(parsed.explicitOptions.contains("seed"))
    }

    func testCommandConstrainsLargeSourceWithoutChangingAspect() throws {
        let command = try ImageEditorCommand.make(prompt: "edit", source: .init(path: "/tmp/input.png", kind: "image"), imageSize: CGSize(width: 4000, height: 3000), strength: 0.5, maskPath: nil)
        let parsed = try ImageRequest.parse(command)
        XCTAssertEqual(parsed.width, 2048)
        XCTAssertEqual(parsed.height, 1536)
        XCTAssertThrowsError(try ImageEditorCommand.make(prompt: "edit", source: .init(path: "/tmp/input.png", kind: "image"), imageSize: .zero, strength: 0.5, maskPath: nil))
    }

    func testMaskExportsWhitePaintBlackBackgroundAndEraserAtCorrectCoordinates() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try ImageMaskExporter.save(strokes: [
            .init(points: [CGPoint(x: 0.2, y: 0.2), CGPoint(x: 0.8, y: 0.2)], width: 0.15, erasing: false),
            .init(points: [CGPoint(x: 0.5, y: 0.2)], width: 0.2, erasing: true)
        ], width: 100, height: 80, directory: directory)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: url)))
        XCTAssertEqual(bitmap.pixelsWide, 100)
        XCTAssertEqual(bitmap.pixelsHigh, 80)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 25, y: 16)).usingColorSpace(.deviceRGB)!.redComponent, 0.9)
        XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 50, y: 16)).usingColorSpace(.deviceRGB)!.redComponent, 0.1)
        XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 25, y: 64)).usingColorSpace(.deviceRGB)!.redComponent, 0.1)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testRejectsInvalidMaskDimensionsAndCoordinates() {
        XCTAssertThrowsError(try ImageMaskExporter.save(strokes: [], width: 0, height: 100))
        XCTAssertThrowsError(try ImageMaskExporter.save(strokes: [.init(points: [CGPoint(x: -1, y: 0)], width: 0.1, erasing: false)], width: 100, height: 100))
    }
}
