import XCTest
@testable import STIXAgent

final class ImageRequestTests: XCTestCase {
    func testParsesQuotedImageOptions() throws {
        let request = try ImageRequest.parse("/image A red fox --input '/tmp/my image.png' --mask /tmp/mask.png --size 768x1024 --steps 30 --seed 42 --cfg 6.5 --denoise 0.4 --negative 'blurry, text' --count 3")
        XCTAssertEqual(request.prompt, "A red fox")
        XCTAssertEqual(request.inputImagePath, "/tmp/my image.png")
        XCTAssertEqual(request.maskImagePath, "/tmp/mask.png")
        XCTAssertEqual(request.width, 768)
        XCTAssertEqual(request.height, 1024)
        XCTAssertEqual(request.steps, 30)
        XCTAssertEqual(request.seed, 42)
        XCTAssertEqual(request.cfg, 6.5)
        XCTAssertEqual(request.denoise, 0.4)
        XCTAssertEqual(request.negativePrompt, "blurry, text")
        XCTAssertEqual(request.count, 3)
    }

    func testLatestImageAndAttachmentDefaults() throws {
        let latest = try ImageRequest.parse("/image make it blue --input last", lastImagePath: "/tmp/last.png")
        XCTAssertEqual(latest.inputImagePath, "/tmp/last.png")
        XCTAssertEqual(latest.denoise, 0.75)
        let attachment = try ImageRequest.parse("/image make it blue", inputImagePath: "/tmp/attached.png")
        XCTAssertEqual(attachment.inputImagePath, "/tmp/attached.png")
        XCTAssertEqual(attachment.denoise, 0.75)
        XCTAssertThrowsError(try ImageRequest.parse("/image edit --input last"))
    }

    func testRejectsInvalidOptionsAndBounds() {
        let options = ["--steps 0", "--steps 101", "--width 257", "--height 4096", "--size 0x1024", "--size 1024", "--size 512x512 --width 512", "--seed -1", "--seed 9007199254740992", "--cfg nan", "--cfg inf", "--cfg 31", "--denoise 0.5", "--count 0", "--count 5", "--input relative.png", "--mask /tmp/mask.png", "--steps 20 --steps 30", "--unknown yes", "--steps", "--negative 'unterminated"]
        for option in options { XCTAssertThrowsError(try ImageRequest.parse("/image fox \(option)"), option) }
        XCTAssertThrowsError(try ImageRequest.parse("/image"))
    }

    func testEndOfOptionsAndEquals() throws {
        let request = try ImageRequest.parse("/image --steps=1 --seed=0 -- --a literal prompt")
        XCTAssertEqual(request.prompt, "--a literal prompt")
        XCTAssertEqual(request.steps, 1)
        XCTAssertEqual(request.seed, 0)
    }

    func testImageWorkflowEncodesResizedPixelsAndRepeatsLatent() throws {
        let request = try ImageRequest.parse("/image fox --input /tmp/input.png --size 768x512 --count 2 --steps 25 --seed 9")
        let workflow = try ComfyClient.workflow(request: request, checkpoint: "sdxl", uploadedImage: "input.png")
        XCTAssertEqual(workflow["8"]["inputs"]["image"].string, "input.png")
        XCTAssertEqual(workflow["9"]["inputs"]["width"].int, 768)
        XCTAssertEqual(workflow["9"]["inputs"]["height"].int, 512)
        XCTAssertEqual(workflow["4"]["class_type"].string, "VAEEncode")
        XCTAssertEqual(workflow["13"]["inputs"]["amount"].int, 2)
        XCTAssertEqual(workflow["5"]["inputs"]["latent_image"], .array([.string("13"), .number(0)]))
        XCTAssertEqual(workflow["5"]["inputs"]["denoise"], .number(0.75))
        XCTAssertEqual(workflow["5"]["inputs"]["steps"].int, 25)
        XCTAssertThrowsError(try ComfyClient.workflow(request: request, checkpoint: "sdxl"))
    }

    func testInpaintMaskIsResizedAndComposited() throws {
        let request = try ImageRequest.parse("/image fox --input /tmp/input.png --mask /tmp/mask.png")
        let workflow = try ComfyClient.workflow(request: request, checkpoint: "sdxl", uploadedImage: "input.png", uploadedMask: "mask.png")
        XCTAssertEqual(workflow["4"]["class_type"].string, "VAEEncodeForInpaint")
        XCTAssertEqual(workflow["11"]["inputs"]["upscale_method"].string, "nearest-exact")
        XCTAssertEqual(workflow["12"]["inputs"]["channel"].string, "red")
        XCTAssertEqual(workflow["14"]["class_type"].string, "ImageCompositeMasked")
        XCTAssertEqual(workflow["7"]["inputs"]["images"], .array([.string("14"), .number(0)]))
    }

    func testInpaintVariationsRepeatCompositeBackground() throws {
        let request = try ImageRequest.parse("/image fox --input /tmp/input.png --mask /tmp/mask.png --count 3")
        let workflow = try ComfyClient.workflow(request: request, checkpoint: "sdxl", uploadedImage: "input.png", uploadedMask: "mask.png")
        XCTAssertEqual(workflow["15"]["class_type"].string, "RepeatImageBatch")
        XCTAssertEqual(workflow["15"]["inputs"]["amount"].int, 3)
        XCTAssertEqual(workflow["14"]["inputs"]["destination"], .array([.string("15"), .number(0)]))
    }

    func testResizeOnlyUsesNoModelAndAllowsEmptyPrompt() throws {
        let request = try ImageRequest.parse("/image --input last --resize-only --size 512x768", lastImagePath: "/tmp/last.png")
        XCTAssertTrue(request.resizeOnly)
        let workflow = try ComfyClient.workflow(request: request, checkpoint: "", uploadedImage: "last.png")
        XCTAssertEqual(workflow.object?.count, 3)
        XCTAssertEqual(workflow["9"]["inputs"]["width"].int, 512)
        XCTAssertEqual(workflow["9"]["inputs"]["height"].int, 768)
        XCTAssertEqual(workflow["7"]["inputs"]["images"], .array([.string("9"), .number(0)]))
        XCTAssertFalse(workflow.object!.values.contains { $0["class_type"].string == "KSampler" })
        for options in ["--steps 20", "--seed 4", "--mask /tmp/mask.png", "--count 2"] {
            XCTAssertThrowsError(try ImageRequest.parse("/image --resize-only --input /tmp/image.png \(options)"))
        }
        XCTAssertThrowsError(try ImageRequest.parse("/image --resize-only"))
    }

    func testCustomWorkflowBindsSupportedOptionsAndRejectsIgnoredOnes() throws {
        let template: JSONValue = .object([
            "1": .object(["class_type": .string("Custom"), "inputs": .object([
                "text": .string("{{prompt}}"), "steps": .string("{{steps}}"),
                "image": .string("{{input_image}}"), "denoise": .string("{{denoise}}")])]),
            "2": .object(["class_type": .string("SaveImage"), "inputs": .object([:])])])
        let request = try ImageRequest.parse("/image edit --input /tmp/image.png --steps 30")
        let workflow = try ComfyClient.bindWorkflow(template, request: request, checkpoint: "sdxl", uploadedImage: "image.png")
        XCTAssertEqual(workflow["1"]["inputs"]["steps"].int, 30)
        XCTAssertEqual(workflow["1"]["inputs"]["image"].string, "image.png")
        XCTAssertEqual(workflow["1"]["inputs"]["denoise"], .number(0.75))
        var unsupported = request
        unsupported.width = 768
        XCTAssertThrowsError(try ComfyClient.bindWorkflow(template, request: unsupported, checkpoint: "sdxl", uploadedImage: "image.png"))
        XCTAssertThrowsError(try ComfyClient.bindWorkflow(template, request: request, checkpoint: "sdxl"))
    }
}
