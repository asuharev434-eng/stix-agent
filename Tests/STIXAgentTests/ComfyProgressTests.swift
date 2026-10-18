import XCTest
@testable import STIXAgent

final class ComfyProgressTests: XCTestCase {
    func testAcceptsOnlyOwnedPromptSamplerProgress() {
        let event = #"{"type":"progress","data":{"prompt_id":"owned","value":4,"max":20,"node":"5"}}"#
        XCTAssertEqual(ComfyStepProgress.parse(event, promptID: "owned"), .init(value: 4, maximum: 20))
        XCTAssertNil(ComfyStepProgress.parse(event, promptID: "other"))
        XCTAssertNil(ComfyStepProgress.parse(event, promptID: ""))
        XCTAssertEqual(ComfyStepProgress.parse(#"{"type":"progress","data":{"prompt_id":"owned","value":20,"max":20}}"#, promptID: "owned"), .init(value: 20, maximum: 20))
    }

    func testRejectsMalformedUnscopedAndUnknownEvents() {
        let invalid = [
            "not JSON", "null", "[]", "{}",
            #"{"type":"status","data":{"prompt_id":"owned","value":1,"max":20}}"#,
            #"{"type":"execution_start","data":{"prompt_id":"owned","value":1,"max":20}}"#,
            #"{"type":"progress","data":{"value":1,"max":20}}"#,
            #"{"type":"progress","data":{"prompt_id":"owned","value":-1,"max":20}}"#,
            #"{"type":"progress","data":{"prompt_id":"owned","value":21,"max":20}}"#,
            #"{"type":"progress","data":{"prompt_id":"owned","value":0,"max":0}}"#,
            #"{"type":"progress","data":{"prompt_id":"owned","value":1.5,"max":20}}"#,
            #"{"type":"progress","data":{"prompt_id":"owned","value":"1","max":20}}"#,
            #"{"type":"progress","data":{"prompt_id":"owned","value":true,"max":20}}"#,
            #"{"type":"progress","data":{"prompt_id":"owned","value":1,"max":1e100}}"#
        ]
        for event in invalid { XCTAssertNil(ComfyStepProgress.parse(event, promptID: "owned"), event) }
        XCTAssertNil(ComfyStepProgress.parse(String(repeating: " ", count: ComfyStepProgress.maximumTextBytes + 1), promptID: "owned"))
    }

    func testSocketUsesEncodedClientIDAndPreservesLocalPath() throws {
        let url = try XCTUnwrap(ComfyStepProgress.socketURL(endpoint: "http://127.0.0.1:8188/comfy", clientID: "unique&client"))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.scheme, "ws")
        XCTAssertEqual(parts.host, "127.0.0.1")
        XCTAssertEqual(parts.port, 8188)
        XCTAssertEqual(parts.path, "/comfy/ws")
        XCTAssertEqual(parts.queryItems, [URLQueryItem(name: "clientId", value: "unique&client")])
        XCTAssertEqual(ComfyStepProgress.socketURL(endpoint: "https://localhost:8188", clientID: "x")?.scheme, "wss")
        XCTAssertNotNil(ComfyStepProgress.socketURL(endpoint: "http://[::1]:8188", clientID: "x"))
    }

    func testRejectsNonLocalOrAmbiguousSocketAddresses() {
        for endpoint in ["invalid", "file:///tmp/comfy", "ws://localhost:8188", "https://example.com", "http://localhost.example.com", "http://192.168.1.5:8188", "http://user:pass@localhost:8188", "http://localhost:8188?redirect=external", "http://localhost:8188#fragment"] {
            XCTAssertNil(ComfyStepProgress.socketURL(endpoint: endpoint, clientID: "x"), endpoint)
        }
        XCTAssertNil(ComfyStepProgress.socketURL(endpoint: "http://localhost:8188", clientID: ""))
    }
}
