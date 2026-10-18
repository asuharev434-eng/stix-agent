import XCTest
@testable import STIXAgent

final class LMStudioTests: XCTestCase {
    private func event(_ payload: String, into parser: inout LMStreamParser) throws -> String? {
        _ = try parser.consume(line: "data: " + payload)
        return try parser.consume(line: "")
    }

    func testFragmentsAndInterleavedCalls() throws {
        var parser = LMStreamParser()
        _ = try event(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"id":"b","function":{"name":"read","arguments":"{"}},{"index":0,"id":"a","function":{"name":"li","arguments":"{}"}}]}}]}"#, into: &parser)
        _ = try event(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"1","function":{"name":"st"}},{"index":1,"function":{"arguments":"}"}}]},"finish_reason":"tool_calls"}]}"#, into: &parser)
        _ = try event("[DONE]", into: &parser)
        let reply = try parser.reply()
        XCTAssertEqual(reply.toolCalls, [ToolCall(id: "a1", name: "list", arguments: "{}"), ToolCall(id: "b", name: "read", arguments: "{}")])
    }

    func testTextAndCRLF() throws {
        var parser = LMStreamParser()
        _ = try parser.consume(line: ": keepalive\r")
        _ = try parser.consume(line: #"data: {"choices":[{"index":0,"delta":{"content":"Привет"}}]}"# + "\r")
        XCTAssertEqual(try parser.consume(line: "\r"), "Привет")
        _ = try event(#"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#, into: &parser)
        XCTAssertEqual(try parser.reply().content, "Привет")
    }

    func testFailuresAreNotSuccessfulEmptyReplies() throws {
        var parser = LMStreamParser()
        XCTAssertThrowsError(try parser.reply())
        _ = try event("[DONE]", into: &parser)
        XCTAssertThrowsError(try parser.reply())
        var broken = LMStreamParser()
        XCTAssertThrowsError(try event("not json", into: &broken))
        var provider = LMStreamParser()
        XCTAssertThrowsError(try event(#"{"error":{"message":"Model unloaded"}}"#, into: &provider))
        var truncated = LMStreamParser()
        XCTAssertThrowsError(try event(#"{"choices":[{"index":0,"delta":{"content":"partial"},"finish_reason":"length"}]}"#, into: &truncated))
    }

    func testIncompleteToolArgumentsRejected() throws {
        var parser = LMStreamParser()
        _ = try event(#"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"a","function":{"name":"write","arguments":"{"}}]},"finish_reason":"tool_calls"}]}"#, into: &parser)
        XCTAssertThrowsError(try parser.reply())
    }

    func testWireBodyUsesOpenAINesting() throws {
        let messages = [LMMessage(role: "assistant", content: nil, toolCalls: [ToolCall(id: "call1", name: "read", arguments: "{}")]), LMMessage(role: "tool", content: "ok", toolCallID: "call1")]
        let body = try LMStudioClient.requestBody(model: "local", messages: messages, tools: [ToolDefinition(name: "read", description: "Read", parameters: .object(["type": .string("object")]))])
        let json = try JSONDecoder().decode(JSONValue.self, from: body)
        let wire = try XCTUnwrap(json["messages"].array)
        XCTAssertEqual(wire[0]["tool_calls"].array?.first?["function"]["name"].string, "read")
        XCTAssertEqual(wire[0]["tool_calls"].array?.first?["type"].string, "function")
        XCTAssertEqual(wire[1]["tool_call_id"].string, "call1")
        XCTAssertEqual(json["stream"].bool, true)
        XCTAssertEqual(json["tools"].array?.first?["function"]["name"].string, "read")
        XCTAssertNil(wire[0]["toolCalls"].array)
    }
}
