import XCTest
@testable import STIXAgent

final class ThinkingStreamTests: XCTestCase {
    func testTagsSplitAtEveryCharacterNeverLeakReasoning() {
        var filter = ThinkingStream()
        var answer = "", reasoning = ""
        for character in "Before <think>private reasoning</think>After" {
            let delta = filter.consume(String(character))
            answer += delta.text
            reasoning += delta.reasoning
        }
        let tail = filter.consume("", finishing: true)
        answer += tail.text; reasoning += tail.reasoning
        XCTAssertEqual(answer, "Before After")
        XCTAssertEqual(reasoning, "private reasoning")
    }

    func testUnclosedThinkingNeverBecomesAnswer() {
        var filter = ThinkingStream()
        XCTAssertEqual(filter.consume("<think>private thought"), ThinkingDelta(text: "", reasoning: "private thought"))
        XCTAssertEqual(filter.consume("more</thi"), ThinkingDelta(text: "", reasoning: "more"))
        XCTAssertEqual(filter.consume("", finishing: true), ThinkingDelta(text: "", reasoning: "</thi"))
    }

    func testNormalAngleBracketsAndMultipleThinkingBlocks() {
        var filter = ThinkingStream()
        XCTAssertEqual(filter.consume("1 < 2 <think>a</think>yes<think>b</think>!", finishing: true), ThinkingDelta(text: "1 < 2 yes!", reasoning: "ab"))
    }

    func testGemmaThoughtChannelIsHiddenAcrossChunks() {
        var filter = ThinkingStream()
        var answer = "", reasoning = ""
        for chunk in ["<|chan", "nel>thought\nprivate", "<chan", "nel|>42"] {
            let delta = filter.consume(chunk)
            answer += delta.text
            reasoning += delta.reasoning
        }
        let final = filter.consume("", finishing: true)
        XCTAssertEqual(answer + final.text, "42")
        XCTAssertEqual(reasoning + final.reasoning, "\nprivate")
    }

    private func event(_ delta: JSONValue, finish: String? = nil, parser: inout LMStreamParser) throws -> String? {
        var choice: [String: JSONValue] = ["index": .number(0), "delta": delta]
        if let finish { choice["finish_reason"] = .string(finish) }
        let data = try JSONEncoder().encode(JSONValue.object(["choices": .array([.object(choice)])]))
        _ = try parser.consume(line: "data: " + String(decoding: data, as: UTF8.self))
        return try parser.consume(line: "")
    }

    func testDedicatedReasoningDeltasExcludedFromReply() throws {
        var parser = LMStreamParser()
        XCTAssertNil(try event(.object(["reasoning_content": .string("private")]), parser: &parser))
        XCTAssertEqual(parser.reasoningDelta, "private")
        XCTAssertNil(try event(.object(["reasoning": .string(" second")]), parser: &parser))
        XCTAssertEqual(parser.reasoningDelta, " second")
        XCTAssertEqual(try event(.object(["content": .string("Final answer")]), finish: "stop", parser: &parser), "Final answer")
        XCTAssertEqual(parser.reasoningDelta, "")
        XCTAssertEqual(try parser.reply().content, "Final answer")
    }

    func testInlineReasoningSplitAcrossSSEEventsExcludedFromReply() throws {
        var parser = LMStreamParser()
        var answer = "", reasoning = ""
        for chunk in ["<th", "ink>private", " thought</thi", "nk>Visible", " answer"] {
            answer += try event(.object(["content": .string(chunk)]), parser: &parser) ?? ""
            reasoning += parser.reasoningDelta
        }
        answer += try event(.object([:]), finish: "stop", parser: &parser) ?? ""
        XCTAssertEqual(answer, "Visible answer")
        XCTAssertEqual(reasoning, "private thought")
        XCTAssertEqual(try parser.reply().content, "Visible answer")
    }

    func testThinkingRequestOptionOmittedByDefault() throws {
        let normal = try JSONDecoder().decode(JSONValue.self, from: LMStudioClient.requestBody(model: "local", messages: [], tools: []))
        XCTAssertEqual(normal["chat_template_kwargs"], .null)
        let thinking = try JSONDecoder().decode(JSONValue.self, from: LMStudioClient.requestBody(model: "local", messages: [], tools: [], thinking: true))
        XCTAssertEqual(thinking["chat_template_kwargs"]["enable_thinking"].bool, true)
        let qwen = try JSONDecoder().decode(JSONValue.self, from: LMStudioClient.requestBody(model: "qwen3-8b-abliterated", messages: [], tools: []))
        XCTAssertEqual(qwen["chat_template_kwargs"]["enable_thinking"].bool, false)
    }
}
