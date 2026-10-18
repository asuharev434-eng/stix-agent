import XCTest
@testable import STIXAgent

final class ModelOrchestratorTests: XCTestCase {
    private let installed = [ModelDescriptor(id: "main"), ModelDescriptor(id: "local-coder"), ModelDescriptor(id: "local-vl")]

    func testTypedVisionPathsChooseAssignedVisionWithoutChangingRouting() throws {
        let args: JSONValue = .object(["task": .string("Describe"), "reason": .string("Vision"), "image_paths": .array([.string("/tmp/photo.png")])])
        let result = try ModelOrchestrator.request(args, installed: installed, assignments: ["vision": "local-vl", "general": "main"])
        XCTAssertEqual(result.model, "local-vl"); XCTAssertEqual(result.imagePaths, ["/tmp/photo.png"])
        var invalid = args.object!; invalid["image_paths_json"] = .string("[]")
        XCTAssertThrowsError(try ModelOrchestrator.request(.object(invalid), installed: installed, assignments: ["vision": "local-vl"]))
        XCTAssertFalse(ModelOrchestrator.definitions.contains { $0.name == "configure_model_role" })
    }

    func testDelegationHasNoToolsOrConversationHistory() throws {
        let request = try ModelOrchestrator.request(.object(["role": .string("coding"), "task": .string("Review this function"), "reason": .string("Need coding specialist")]), installed: installed, assignments: ["coding": "local-coder"])
        let body = try LMStudioClient.requestBody(model: request.model, messages: request.messages(), tools: [])
        let json = try JSONDecoder().decode(JSONValue.self, from: body)
        XCTAssertEqual(json["model"].string, "local-coder")
        XCTAssertEqual(json["tools"], .null)
        XCTAssertEqual(json["tool_choice"], .null)
        let messages = try XCTUnwrap(json["messages"].array)
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages.last?["content"].string, "Review this function")
        XCTAssertTrue(messages.allSatisfy { $0["tool_calls"] == .null })
    }

    func testDelegationValidatesInstalledAssignmentAndBounds() throws {
        let base: [String: JSONValue] = ["task": .string("Task"), "reason": .string("Specialism")]
        XCTAssertThrowsError(try ModelOrchestrator.request(.object(base.merging(["role": .string("coding")]) { _, new in new }), installed: installed, assignments: ["coding": "not-installed"]))
        XCTAssertThrowsError(try ModelOrchestrator.request(.object(base.merging(["role": .string("unknown"), "model_id": .string("main")]) { _, new in new }), installed: installed, assignments: [:]))
        XCTAssertThrowsError(try ModelOrchestrator.request(.object(base.merging(["model_id": .string("not-installed")]) { _, new in new }), installed: installed, assignments: [:]))
        XCTAssertThrowsError(try ModelOrchestrator.request(.object(base.merging(["model_id": .string("main"), "task": .string(String(repeating: "x", count: 16001))]) { _, new in new }), installed: installed, assignments: [:]))
        XCTAssertThrowsError(try ModelOrchestrator.request(.object(base.merging(["model_id": .string("main"), "image_paths_json": .string("[1]")]) { _, new in new }), installed: installed, assignments: [:]))
        XCTAssertThrowsError(try ModelOrchestrator.request(.object(base.merging(["role": .string("vision"), "model_id": .string("main")]) { _, new in new }), installed: installed, assignments: ["vision": "local-vl"]))
    }

    @MainActor func testRoleAssignmentAndRejectedDelegationPreserveMainSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        let id = try XCTUnwrap(store.selectedID)
        store.setModel("main", image: false)
        store.models = installed
        _ = try store.configureModelRole(.object(["role": .string("coding"), "model_id": .string("local-coder")]))
        XCTAssertEqual(store.currentChat?.model, "main")
        XCTAssertEqual(store.preferences.defaultModel, "main")
        store.preferences.lmEndpoint = "https://example.com"
        do {
            _ = try await store.delegateModel(.object(["role": .string("coding"), "task": .string("Task"), "reason": .string("Specialism")]), chatID: id)
            XCTFail("Remote endpoint must not be called")
        } catch { XCTAssertTrue(error.localizedDescription.contains("localhost")) }
        XCTAssertEqual(store.currentChat?.model, "main")
        XCTAssertEqual(store.preferences.modelRoles?["coding"], "local-coder")
    }

    func testOnlyLoopbackEndpointsAllowed() throws {
        for endpoint in ["http://127.0.0.1:1234", "http://localhost:1234/v1", "http://[::1]:1234"] { XCTAssertNoThrow(try ModelOrchestrator.validateEndpoint(endpoint)) }
        for endpoint in ["https://example.com", "http://localhost.example.com", "http://192.168.1.3:1234", "file:///tmp/model", "http://user:pass@localhost:1234", "http://localhost:1234?url=https://example.com"] { XCTAssertThrowsError(try ModelOrchestrator.validateEndpoint(endpoint)) }
    }

    func testCapabilityGuessesAreLabelledAndRolesExplicit() {
        let result = ModelOrchestrator.catalog(installed: installed, assignments: ["writing": "main"])
        XCTAssertTrue(result.contains("main | назначено: writing"))
        XCTAssertTrue(result.contains("по имени (не проверено): coding"))
        XCTAssertTrue(result.contains("по имени (не проверено): vision"))
    }

    func testVisionPayloadOnlyContainsProvidedImages() throws {
        let request = try ModelOrchestrator.request(.object(["model_id": .string("local-vl"), "task": .string("Describe"), "reason": .string("Vision"), "image_paths_json": .string("[\"/tmp/photo.png\"]")]), installed: installed, assignments: [:])
        XCTAssertEqual(request.imagePaths, ["/tmp/photo.png"])
        XCTAssertEqual(request.messages(imageURLs: ["data:image/jpeg;base64,eA=="]).last?.imageURLs, ["data:image/jpeg;base64,eA=="])
    }

    func testCurrentImagePayloadSurvivesTextContextBudget() {
        let image = "data:image/jpeg;base64," + String(repeating: "a", count: 300000)
        let result = ContextSummary.bounded([.init(role: "user", content: "Describe this image", imageURLs: [image])])
        XCTAssertEqual(result.last?.imageURLs, [image])
    }

    func testExtractiveSummaryIsDeterministicAndHonest() {
        let omitted = [LMMessage(role: "user", content: "Keep the backup"), LMMessage(role: "tool", content: "Failed to write file", toolCallID: "a")]
        let summary = ContextSummary.excerpts(omitted, budget: 700)
        XCTAssertEqual(summary, ContextSummary.excerpts(omitted, budget: 700))
        XCTAssertTrue(summary.contains("Failed to write file"))
        XCTAssertTrue(summary.contains("не полное резюме"))
        XCTAssertLessThanOrEqual(summary.count, 700)
    }

    func testContextKeepsToolGroupsAndLatestRequest() {
        let call = ToolCall(id: "a", name: "write_file", arguments: "{}")
        var history = (0..<15).map { LMMessage(role: "user", content: "Old \($0): " + String(repeating: "x", count: 1000)) }
        history += [.init(role: "user", content: "Current task"), .init(role: "assistant", content: nil, toolCalls: [call]), .init(role: "tool", content: "saved", toolCallID: "a"), .init(role: "assistant", content: "Checking")]
        let result = ContextSummary.bounded(history, maxCharacters: 6000)
        XCTAssertTrue(result.contains { $0.role == "user" && $0.content == "Current task" })
        XCTAssertTrue(result.contains { $0.role == "system" && $0.content?.contains("Сокращённая история") == true })
        let toolIndex = result.firstIndex { $0.toolCallID == "a" }
        XCTAssertNotNil(toolIndex)
        if let toolIndex { XCTAssertEqual(result[toolIndex - 1].toolCalls.first?.id, "a") }
    }

    func testLatestUserRetainedAfterLongToolLoopWithoutBreakingGroups() {
        var history = [LMMessage(role: "user", content: "Do the original task")]
        for index in 0..<15 {
            let id = "call\(index)"
            history.append(.init(role: "assistant", content: nil, toolCalls: [.init(id: id, name: "read_file", arguments: "{}")]))
            history.append(.init(role: "tool", content: String(repeating: "x", count: 1000), toolCallID: id))
        }
        let result = ContextSummary.bounded(history, maxCharacters: 6000)
        XCTAssertTrue(result.contains { $0.role == "user" && $0.content?.hasPrefix("Do the original task") == true })
        for (index, message) in result.enumerated() where message.role == "tool" {
            XCTAssertGreaterThan(index, 0)
            XCTAssertEqual(result[index - 1].toolCalls.first?.id, message.toolCallID)
        }
        XCTAssertLessThanOrEqual(result.reduce(0) { $0 + ($1.content?.count ?? 0) + $1.toolCalls.reduce(0) { $0 + $1.arguments.count } }, 6000)
    }
}
