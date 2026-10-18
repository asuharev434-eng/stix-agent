import XCTest
@testable import STIXAgent

final class ImageToolSchemaTests: XCTestCase {
    func testImageToolRequiresExplicitPromptForCompactModels() throws {
        let tool = try XCTUnwrap(ExtendedToolCatalog.definitions.first { $0.name == "generate_image" })
        XCTAssertTrue(tool.parameters["required"].array?.contains(.string("prompt")) == true)
        let prompt = tool.parameters["properties"]["prompt"]
        XCTAssertEqual(prompt["type"].string, "string")
        XCTAssertTrue(prompt["description"].string?.contains("resize_only") == true)
    }

    func testResizeStillAcceptsExplicitEmptyPrompt() throws {
        let request = try ImageRequest.parse("\"\" --input last --resize-only --width 512 --height 512", lastImagePath: "/tmp/own-image.png")
        XCTAssertTrue(request.resizeOnly)
        XCTAssertEqual(request.prompt, "")
        XCTAssertEqual(request.width, 512)
    }
}
