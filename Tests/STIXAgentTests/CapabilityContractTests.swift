import XCTest
@testable import STIXAgent

/// Offline contracts only: these never capture the screen, inspect apps, or send Apple Events.
final class CapabilityContractTests: XCTestCase {
    @MainActor func testMainModelReceivesSpecialistAndComputerToolsWithStrictSchemas() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        let tools = store.allTools()
        for name in ["delegate_model", "generate_image", "run_shell", "open_application", "computer_snapshot", "computer_action", "browser_action"] {
            let matches = tools.filter { $0.name == name }
            XCTAssertEqual(matches.count, 1, name)
            let schema = try XCTUnwrap(matches.first).parameters
            XCTAssertEqual(schema["type"].string, "object", name)
            XCTAssertEqual(schema["additionalProperties"].bool, false, name)
            let properties = try XCTUnwrap(schema["properties"].object)
            for field in schema["required"].array ?? [] {
                XCTAssertNotNil(properties[try XCTUnwrap(field.string)], name)
            }
        }
        let browser = try XCTUnwrap(tools.first { $0.name == "browser_action" })
        XCTAssertEqual(browser.parameters["properties"]["javascript"], .null)
        XCTAssertEqual(Set(browser.parameters["properties"].object?.keys.map { $0 } ?? []),
                       Set(["browser", "action", "window", "tab", "url", "snapshot_id", "element_id", "text"]))
    }

    func testApplicationIdentityRejectsPathsScriptsAndWhitespace() throws {
        XCTAssertEqual(try ComputerToolValidation.bundleID("com.apple.TextEdit"), "com.apple.TextEdit")
        for value in ["", "TextEdit", "/Applications/TextEdit.app", "com.apple.TextEdit\n", "com.apple.TextEdit\"", "com..app"] {
            XCTAssertThrowsError(try ComputerToolValidation.bundleID(value), value)
        }
    }

    func testNamedKeysAllowShortcutsWithoutLiteralTextInjection() throws {
        XCTAssertEqual(try ComputerToolValidation.key("return", modifiers: "").0, 36)
        XCTAssertEqual(try ComputerToolValidation.key("l", modifiers: "command").0, 37)
        XCTAssertEqual(try ComputerToolValidation.key("z", modifiers: "command, shift").1, [.maskCommand, .maskShift])
        for (key, modifiers) in [("password", ""), ("a", ""), ("a", "shift"), ("a", "command,command"), ("return", "command,"), ("return", "super")] {
            XCTAssertThrowsError(try ComputerToolValidation.key(key, modifiers: modifiers))
        }
    }

    @MainActor func testExecutorRejectsMalformedComputerCallsBeforeApprovalOrUIAccess() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        let chatID = try XCTUnwrap(store.selectedID)
        let calls: [(String, String, String)] = [
            ("computer_snapshot", #"{"max_elements":"many"}"#, "ожидается integer"),
            ("computer_action", #"{"snapshot_id":"s","element_id":"e"}"#, "Отсутствует аргумент action"),
            ("browser_action", #"{"browser":"chrome","action":"read","javascript":"alert(1)"}"#, "Неизвестные аргументы"),
            ("browser_action", #"{"browser":"chrome","action":"read","window":1.5}"#, "ожидается integer")
        ]
        for (name, arguments, expected) in calls {
            do {
                _ = try await store.execute(.init(id: UUID().uuidString, name: name, arguments: arguments), chatID: chatID)
                XCTFail("Invalid call accepted: \(name)")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription)
            }
            XCTAssertNil(store.pending)
        }
    }
}
