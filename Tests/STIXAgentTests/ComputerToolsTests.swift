import XCTest
@testable import STIXAgent

final class ComputerToolsTests: XCTestCase {
    func testBrowserRejectsInventedSettingsActionsBeforeApproval() throws {
        XCTAssertThrowsError(try ComputerToolValidation.browserAction(.object(["action": .string("toggle_settings")])))
        for action in ComputerToolValidation.browserActions { XCTAssertNoThrow(try ComputerToolValidation.browserAction(.object(["action": .string(action)]))) }
        XCTAssertTrue(ComputerToolValidation.javascriptUnavailable("Выполнение JavaScript через AppleScript отключено"))
        XCTAssertTrue(ComputerToolValidation.javascriptUnavailable("JavaScript from Apple Events is disabled"))
        XCTAssertFalse(ComputerToolValidation.javascriptUnavailable("Automation permission denied"))
        XCTAssertFalse(ComputerToolValidation.javascriptUnavailable("Apple Events: permission denied. Разрешите Automation; для DOM включите Allow JavaScript from Apple Events в браузере."))
    }
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
