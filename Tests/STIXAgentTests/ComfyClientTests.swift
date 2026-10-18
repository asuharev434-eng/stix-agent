import XCTest
@testable import STIXAgent

final class ComfyClientTests: XCTestCase {
    func testCustomWorkflowBindingAndOutputPrefix() throws {
        let template: JSONValue = .object([
            "1": .object(["class_type": .string("CustomModel"), "inputs": .object([
                "nested": .array([.string("{{prompt}}"), .object(["model": .string("{{checkpoint}}"), "seed": .string("{{seed}}")])]),
                "literal": .string("prefix {{prompt}}")])]),
            "2": .object(["class_type": .string("SaveImage"), "inputs": .object(["filename_prefix": .string("../../outside")])])
        ])
        let bound = try ComfyClient.bindWorkflow(template, prompt: "Mountains", checkpoint: "custom.gguf", seed: 42)
        let nested = try XCTUnwrap(bound["1"]["inputs"]["nested"].array)
        XCTAssertEqual(nested[0], .string("Mountains"))
        XCTAssertEqual(nested[1]["model"], .string("custom.gguf"))
        XCTAssertEqual(nested[1]["seed"], .number(42))
        XCTAssertEqual(bound["1"]["inputs"]["literal"], .string("prefix {{prompt}}"))
        XCTAssertEqual(bound["2"]["inputs"]["filename_prefix"], .string("STIXAgent"))
    }

    func testRejectsInvalidCustomWorkflows() {
        let invalid: [JSONValue] = [
            .array([]), .object([:]),
            .object(["1": .object(["class_type": .string(""), "inputs": .object([:])])]),
            .object(["1": .object(["class_type": .string("SaveImage"), "inputs": .object([:])])]),
            .object(["1": .object(["class_type": .string("Text"), "inputs": .object(["text": .string("{{prompt}}")])])])
        ]
        for template in invalid {
            XCTAssertThrowsError(try ComfyClient.bindWorkflow(template, prompt: "x", checkpoint: "y", seed: 1))
        }
        let node: JSONValue = .object(["class_type": .string("SaveImage"), "inputs": .object(["text": .string("{{prompt}}")])])
        XCTAssertThrowsError(try ComfyClient.bindWorkflow(.object(Dictionary(uniqueKeysWithValues: (0...500).map { (String($0), node) })), prompt: "x", checkpoint: "y", seed: 1))
    }

    func testStandardSDXLWorkflowConnections() throws {
        let workflow = ComfyClient.workflow(prompt: "A mountain", checkpoint: "sdxl.safetensors", seed: 123)
        XCTAssertEqual(workflow.object?.count, 7)
        XCTAssertEqual(workflow["1"]["inputs"]["ckpt_name"].string, "sdxl.safetensors")
        XCTAssertEqual(workflow["2"]["inputs"]["text"].string, "A mountain")
        XCTAssertEqual(workflow["4"]["inputs"]["width"].int, 1024)
        XCTAssertEqual(workflow["4"]["inputs"]["height"].int, 1024)
        XCTAssertEqual(workflow["5"]["inputs"]["steps"].int, 20)
        XCTAssertEqual(workflow["5"]["inputs"]["seed"].int, 123)
        XCTAssertEqual(workflow["6"]["inputs"]["vae"], .array([.string("1"), .number(2)]))
        XCTAssertEqual(workflow["7"]["class_type"].string, "SaveImage")
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(workflow)), workflow)
    }

    func testRejectsEmptyPromptBeforeNetworking() async {
        do {
            _ = try await ComfyClient(endpoint: "invalid").generate(prompt: " ", checkpoint: "x", outputDirectory: FileManager.default.temporaryDirectory) { _ in }
            XCTFail("Expected validation error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Описание")) }
    }
}
