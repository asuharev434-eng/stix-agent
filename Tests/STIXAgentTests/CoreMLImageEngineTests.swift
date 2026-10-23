import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import STIXAgent

final class CoreMLImageEngineTests: XCTestCase {
    func testWideImageIsCenterCroppedForFixedSquareModel() throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 2))
        context.setFillColor(CGColor(red: 0, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 1, y: 0, width: 2, height: 2))
        let source = try XCTUnwrap(context.makeImage())
        let square = try CoreMLImageEngine.squareForModel(source)
        XCTAssertEqual(square.width, 512)
        XCTAssertEqual(square.height, 512)
        let image = CIImage(cgImage: square)
        let center = try XCTUnwrap(CIContext().createCGImage(image.cropped(to: CGRect(x: 256, y: 256, width: 1, height: 1)), from: CGRect(x: 256, y: 256, width: 1, height: 1)))
        var pixel = [UInt8](repeating: 0, count: 4)
        let bitmap = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                                             bytesPerRow: 4, space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(center, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertGreaterThan(pixel[1], 200)
        XCTAssertLessThan(pixel[0], 50)
    }

    func testWhiteMaskEditsAndBlackMaskPreservesOriginal() throws {
        let context = CIContext()
        let extent = CGRect(x: 0, y: 0, width: 2, height: 2)
        let original = try XCTUnwrap(context.createCGImage(CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: extent), from: extent))
        let changed = try XCTUnwrap(context.createCGImage(CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: extent), from: extent))
        let mask = try XCTUnwrap(context.createCGImage(
            CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 2))
                .composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: extent)),
            from: extent))
        let result = try CoreMLImageEngine.composite(new: changed, original: original, mask: mask)
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var pixels = [UInt8](repeating: 0, count: 16)
        let bitmap = try XCTUnwrap(CGContext(data: &pixels, width: 2, height: 2, bitsPerComponent: 8,
                                             bytesPerRow: 8, space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        bitmap.draw(result, in: extent)
        XCTAssertLessThan(pixels[0], 50)
        XCTAssertGreaterThan(pixels[2], 200)
        XCTAssertGreaterThan(pixels[4], 200)
        XCTAssertLessThan(pixels[6], 50)
    }

    func testOfflineGenerationAndMaskedEditWithRealWeights() async throws {
        guard let resources = ProcessInfo.processInfo.environment["STIX_TEST_COREML_RESOURCES"] else {
            throw XCTSkip("Set STIX_TEST_COREML_RESOURCES for the real Core ML integration test")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stix-coreml-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = CoreMLImageEngine(resources: URL(fileURLWithPath: resources))
        let installed = try await engine.models()
        XCTAssertEqual(installed.first?.id, "builtin-image:sd15-palettized-512")
        var request = ImageRequest(prompt: "A red ceramic cup on a wooden table, soft daylight")
        request.width = 512; request.height = 512
        request.steps = Int(ProcessInfo.processInfo.environment["STIX_TEST_IMAGE_STEPS"] ?? "4") ?? 4
        request.seed = 14561
        let created = try await engine.generate(request: request, model: CoreMLImageEngine.modelID,
                                                outputDirectory: folder, workflow: nil,
                                                onStepProgress: { _, _ in }, onProgress: { _ in })
        XCTAssertEqual(created.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: created[0].path))

        let maskURL = folder.appendingPathComponent("mask.png")
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.beginPath()
        context.move(to: CGPoint(x: 250, y: 300))
        context.addLine(to: CGPoint(x: 410, y: 300))
        context.addLine(to: CGPoint(x: 390, y: 85))
        context.addLine(to: CGPoint(x: 275, y: 85))
        context.closePath()
        context.fillPath()
        let mask = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(maskURL as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, mask, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        request.prompt = "A blue ceramic cup on a wooden table, soft daylight"
        request.inputImagePath = created[0].path
        request.maskImagePath = maskURL.path
        request.denoise = 0.85
        let edited = try await engine.generate(request: request, model: CoreMLImageEngine.modelID,
                                               outputDirectory: folder, workflow: nil,
                                               onStepProgress: { _, _ in }, onProgress: { _ in })
        XCTAssertEqual(edited.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: edited[0].path))
        if let output = ProcessInfo.processInfo.environment["STIX_TEST_IMAGE_OUTPUT"] {
            let directory = URL(fileURLWithPath: output)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: created[0], to: directory.appendingPathComponent("generated.png"))
            try FileManager.default.copyItem(at: edited[0], to: directory.appendingPathComponent("edited.png"))
        }
    }

    func testCancellationDoesNotLeavePartialImage() async throws {
        guard let resources = ProcessInfo.processInfo.environment["STIX_TEST_COREML_RESOURCES"] else {
            throw XCTSkip("Set STIX_TEST_COREML_RESOURCES for cancellation")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stix-coreml-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = CoreMLImageEngine(resources: URL(fileURLWithPath: resources))
        var request = ImageRequest(prompt: "A blue ceramic cup on a wooden table")
        request.width = 512; request.height = 512; request.steps = 20
        let task = Task {
            try await engine.generate(request: request, model: CoreMLImageEngine.modelID,
                                      outputDirectory: folder, workflow: nil,
                                      onStepProgress: { _, _ in }, onProgress: { _ in })
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled generation finished as successful") }
        catch { }
        let images = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertFalse(images.contains { $0.pathExtension == "png" })
    }
}
