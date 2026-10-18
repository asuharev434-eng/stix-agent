import XCTest
@testable import STIXAgent

final class ImagePromptAdapterTests: XCTestCase {
    func testAdapterReceivesModelEditAndLanguageWithoutTools() throws {
        let messages = ImagePromptAdapter.messages(request: .init(prompt: "Сделай фон белым", inputImagePath: "/tmp/source.png"), imageModel: "sd_xl_base_1.0.safetensors", workflow: nil, language: "auto")
        let data = try LMStudioClient.requestBody(model: "prompt-model", messages: messages, tools: [])
        let body = try JSONValue.parse(String(decoding: data, as: UTF8.self))
        XCTAssertEqual(body["model"].string, "prompt-model"); XCTAssertNil(body["tools"].array)
        let input = try JSONValue.parse(try XCTUnwrap(messages.last?.content))
        XCTAssertEqual(input["image_model"].string, "sd_xl_base_1.0.safetensors"); XCTAssertEqual(input["editing"].bool, true)
        XCTAssertEqual(input["language"].string, "auto")
    }
    func testStrictAdapterJSONAndFenceHandling() throws {
        XCTAssertEqual(try ImagePromptAdapter.parse(#"{"prompt":"red mug","negative":"blurry"}"#).prompt, "red mug")
        XCTAssertEqual(try ImagePromptAdapter.parse("```json\n{\"prompt\":\"red mug\",\"negative\":\"\"}\n```").negative, "")
        XCTAssertThrowsError(try ImagePromptAdapter.parse("Which image would you like?"))
        XCTAssertThrowsError(try ImagePromptAdapter.parse(#"{"prompt":"","negative":""}"#))
    }
}
