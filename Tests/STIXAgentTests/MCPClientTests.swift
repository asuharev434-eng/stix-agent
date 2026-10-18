import XCTest
@testable import STIXAgent

final class MCPClientTests: XCTestCase {
    func testFragmentedAndBatchedFrames() throws {
        var buffer = Data()
        XCTAssertEqual(try MCPFraming.append(Data("{\"id\":1".utf8), to: &buffer), [])
        let values = try MCPFraming.append(Data("}\r\n\n{\"id\":2}\n{\"id\":".utf8), to: &buffer)
        XCTAssertEqual(values.map { $0["id"].int }, [1, 2])
        XCTAssertEqual(String(decoding: buffer, as: UTF8.self), "{\"id\":")
    }
    func testOversizedAndMalformedFramesFail() {
        var buffer = Data()
        XCTAssertThrowsError(try MCPFraming.append(Data(repeating: 65, count: MCPClient.maximumBytes + 1), to: &buffer))
        XCTAssertThrowsError(try MCPFraming.append(Data("broken\n".utf8), to: &buffer))
    }
    func testSSECommentsCRLFAndIncompleteEvent() throws {
        let data = Data(": keepalive\r\n\r\nevent: message\r\ndata: {\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{}}\r\n\r\ndata: incomplete".utf8)
        let messages = try MCPFraming.events(data)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(try MCPFraming.result(messages[0], id: 3), .object([:]))
    }
    func testValidNullResultAndResponseValidation() throws {
        XCTAssertEqual(try MCPFraming.result(JSONValue.parse("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":null}"), id: 1), .null)
        XCTAssertThrowsError(try MCPFraming.result(JSONValue.parse("{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{}}"), id: 1))
        XCTAssertThrowsError(try MCPFraming.result(JSONValue.parse("{\"jsonrpc\":\"2.0\",\"id\":1,\"error\":{\"code\":-1}}"), id: 1))
        XCTAssertThrowsError(try MCPFraming.result(JSONValue.parse("{\"jsonrpc\":\"2.0\",\"id\":1}"), id: 1))
    }
}
