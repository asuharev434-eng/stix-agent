import XCTest
@testable import STIXAgent

final class ProductivityTests: XCTestCase {
    @MainActor func testFeatureConfigSurvivesReloadAndMissingDeclaredFileFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        store.features.resourceMode = .economy; store.save()
        let loaded = AppStore(storage: .init(paths: .init(root: root)))
        XCTAssertTrue(loaded.canPersist); XCTAssertEqual(loaded.features.resourceMode, .economy)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Features/config.json"))
        XCTAssertThrowsError(try StateStorage(paths: .init(root: root)).load())
    }
    func testWorkflowValidatesTypedParametersAndRejectsUnknownFields() throws {
        let workflow = LocalWorkflow(name: "Rename", prompt: "Use supplied values", fields: [.init(key: "width", label: "Width", kind: .number, required: true, minimum: 64, maximum: 2048)])
        XCTAssertNoThrow(try workflow.input(["width": .number(512)]))
        XCTAssertThrowsError(try workflow.input(["width": .number(9000)]))
        XCTAssertThrowsError(try workflow.input(["width": .number(512), "command": .string("evil")]))
    }
    func testDailyScheduleCatchesUpOnceAndDoesNotDuplicate() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var rule = LocalAutomation(name: "Daily", chatID: UUID(), prompt: "Read files", trigger: .daily, hour: 0, minute: 0, timeZone: "UTC")
        rule.createdAt = now.addingTimeInterval(-86400)
        let first = try XCTUnwrap(AutomationSchedule.dailyEvent(rule, now: now, lastEvent: nil))
        XCTAssertNil(AutomationSchedule.dailyEvent(rule, now: now, lastEvent: first))
        rule.enabled = false; XCTAssertNil(AutomationSchedule.dailyEvent(rule, now: now, lastEvent: nil))
    }
    func testCredentialArchiveRejectsWrongPasswordAndTampering() throws {
        let data = try CredentialArchive.seal(["synthetic": "synthetic-value"], password: "long-test-password")
        XCTAssertEqual(try CredentialArchive.open(data, password: "long-test-password"), ["synthetic": "synthetic-value"])
        XCTAssertThrowsError(try CredentialArchive.open(data, password: "different-password"))
        var broken = data; broken[broken.count - 1] ^= 1
        XCTAssertThrowsError(try CredentialArchive.open(broken, password: "long-test-password"))
    }
}
