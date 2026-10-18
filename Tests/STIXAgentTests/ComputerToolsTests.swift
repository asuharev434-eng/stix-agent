import XCTest
@testable import STIXAgent

final class ComputerToolsTests: XCTestCase {
    func testBrowserURLAllowsOnlyPublicWebSchemesWithoutCredentials() throws {
        XCTAssertEqual(try ComputerToolValidation.webURL("https://example.com/a?q=1"), "https://example.com/a?q=1")
        for value in ["javascript:alert(1)", "file:///etc/passwd", "https://user:pass@example.com", "data:text/html,test", "https://example.com\n"] {
            XCTAssertThrowsError(try ComputerToolValidation.webURL(value))
        }
    }
    func testSecureFieldDetection() {
        for value in ["password", "api_key", "access-token", "secret", "one-time-code", "verification_code"] {
            XCTAssertTrue(ComputerToolValidation.isSecret(value))
        }
        XCTAssertFalse(ComputerToolValidation.isSecret("customer display name"))
    }
    func testAppleScriptStringEscapesExecutableText() {
        XCTAssertEqual(ComputerToolValidation.appleString("a\"\\\nb"), "\"a\\\"\\\\\\nb\"")
    }
    func testStrictArgumentsAndBounds() throws {
        XCTAssertThrowsError(try ComputerToolValidation.validate(.object(["javascript": .string("bad")]), allowed: ["action"]))
        XCTAssertThrowsError(try ComputerToolValidation.boundedInt(.number(-1), fallback: 10, range: 1...100))
        XCTAssertThrowsError(try ComputerToolValidation.boundedInt(.number(1.5), fallback: 10, range: 1...100))
        XCTAssertEqual(try ComputerToolValidation.boundedInt(.null, fallback: 10, range: 1...100), 10)
    }
}
