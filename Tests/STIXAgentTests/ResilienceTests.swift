import XCTest
import Network
@testable import STIXAgent

final class ResilienceTests: XCTestCase {
    func testCanonicalToolReceiptPreventsMutationReplay() {
        let first = ToolCall(id: "first", name: "write_file", arguments: "{\"path\":\"a\",\"content\":\"x\"}")
        let repeatCall = ToolCall(id: "second", name: "write_file", arguments: "{ \"content\": \"x\", \"path\": \"a\" }")
        var ledger = ToolExecutionLedger()
        XCTAssertNil(ledger.repeated(first))
        ledger.record(first, output: "saved")
        XCTAssertEqual(ledger.repeated(repeatCall)?.output, "saved")
        XCTAssertNil(ledger.repeated(.init(id: "third", name: "write_file", arguments: "{\"path\":\"a\",\"content\":\"y\"}")))
    }

    func testRestartRestoresSuccessAndUnknownWithoutReexecuting() {
        let saved = ToolCall(id: "a", name: "http_request", arguments: "{\"method\":\"POST\"}")
        let unknown = ToolCall(id: "b", name: "run_shell", arguments: "{\"command\":\"echo side-effect\"}")
        var ledger = ToolExecutionLedger(history: [.init(role: "assistant", content: nil, toolCalls: [saved, unknown]), .init(role: "tool", content: "accepted", toolCallID: "a")])
        XCTAssertEqual(ledger.repeated(saved)?.uncertain, false)
        XCTAssertEqual(ledger.repeated(unknown)?.uncertain, true)
    }

    func testReadVerificationAllowedButReadLoopBounded() {
        let call = ToolCall(id: "a", name: "read_file", arguments: "{\"path\":\"a\"}")
        var ledger = ToolExecutionLedger()
        XCTAssertNil(ledger.repeated(call))
        XCTAssertNil(ledger.repeated(call))
        XCTAssertNotNil(ledger.repeated(call))
        XCTAssertNil(ledger.repeated(.init(id: "b", name: "read_file", arguments: "{\"path\":\"b\"}")))
    }

    func testSkillReadsAndDiagnosticChecksRefreshAfterRepair() {
        var ledger = ToolExecutionLedger()
        let read = ToolCall(id: "r", name: "manage_skill", arguments: "{\"action\":\"read\",\"name\":\"skill-creator\"}")
        XCTAssertNil(ledger.repeated(read)); XCTAssertNil(ledger.repeated(read)); XCTAssertNotNil(ledger.repeated(read))
        let save = ToolCall(id: "w", name: "manage_skill", arguments: "{\"action\":\"save\",\"name\":\"new-skill\"}")
        ledger.record(save, output: "saved")
        XCTAssertNotNil(ledger.repeated(save))
        XCTAssertNil(ledger.repeated(read))
        let diagnostics = ToolCall(id: "d", name: "run_diagnostics", arguments: "{}")
        XCTAssertNil(ledger.repeated(diagnostics)); XCTAssertNil(ledger.repeated(diagnostics))
    }

    func testHistoryRepairClosesMissingAndRejectsOrphanToolResults() {
        let history: [LMMessage] = [.init(role: "tool", content: "orphan", toolCallID: "orphan"), .init(role: "assistant", content: nil, toolCalls: [.init(id: "a", name: "write_file", arguments: "{}"), .init(id: "b", name: "read_file", arguments: "{}")]), .init(role: "tool", content: "saved", toolCallID: "a"), .init(role: "user", content: "Continue")]
        let repaired = ContextSummary.paired(history)
        XCTAssertFalse(repaired.contains { $0.toolCallID == "orphan" })
        XCTAssertEqual(repaired.filter { $0.role == "tool" }.count, 2)
        XCTAssertTrue(repaired.first { $0.toolCallID == "b" }?.content?.contains("Результат неизвестен") == true)
    }

    func testContextBudgetReservesSystemToolsAndModelLimit() throws {
        let tools = [ToolDefinition(name: "test", description: "A tool", parameters: .object([:]))]
        let available = try ContextBudget.historyCharacters(contextLimit: 8192, system: String(repeating: "x", count: 4000), tools: tools)
        XCTAssertLessThan(available, 8192 - 2000)
        XCTAssertThrowsError(try ContextBudget.historyCharacters(contextLimit: 2048, system: String(repeating: "x", count: 10000), tools: tools))
    }

    func testMonotonicDeadlineIgnoresKeepAliveAndHonorsSemanticProgress() {
        let limits = InferenceDeadline.Limits(firstProgress: 10, stalledProgress: 5, total: 30)
        let silent = InferenceDeadline(limits: limits, now: 100)
        XCTAssertNil(silent.expired(now: 109)); XCTAssertNotNil(silent.expired(now: 110))
        let streaming = InferenceDeadline(limits: limits, now: 100)
        streaming.progress(now: 109)
        XCTAssertNil(streaming.expired(now: 113)); XCTAssertNotNil(streaming.expired(now: 114))
        let endless = InferenceDeadline(limits: limits, now: 100)
        endless.progress(now: 129)
        XCTAssertNotNil(endless.expired(now: 130))
    }

    func testStreamProgressOnlyCountsSemanticData() throws {
        var parser = LMStreamParser()
        _ = try parser.consume(line: ": keep alive"); _ = try parser.consume(line: "")
        XCTAssertEqual(parser.progressVersion, 0)
        _ = try parser.consume(line: "data: {\"choices\":[{\"index\":0,\"delta\":{}}]}"); _ = try parser.consume(line: "")
        XCTAssertEqual(parser.progressVersion, 0)
        _ = try parser.consume(line: "data: {\"choices\":[{\"index\":0,\"delta\":{\"reasoning_content\":\"thinking\"}}]}"); _ = try parser.consume(line: "")
        XCTAssertEqual(parser.progressVersion, 1)
    }

    func testResidencyOnlyReleasesOwnedInactiveLLMInstances() throws {
        let item = try JSONValue.parse("{\"key\":\"previous\",\"type\":\"llm\",\"loaded_instances\":[{\"id\":\"instance-a\"}]}")
        XCTAssertEqual(ModelResidency.instancesToRelease(item, requestedModel: "new", ownedKeys: ["previous"]), ["instance-a"])
        XCTAssertTrue(ModelResidency.instancesToRelease(item, requestedModel: "previous", ownedKeys: ["previous"]).isEmpty)
        XCTAssertTrue(ModelResidency.instancesToRelease(item, requestedModel: "new", ownedKeys: []).isEmpty)
    }
    func testKeepAliveStreamIsCancelledBySemanticDeadline() async throws {
        let server = try StalledInferenceServer()
        let port = try await server.start()
        defer { server.stop() }
        let started = Date()
        let client = LMStudioClient(endpoint: "http://127.0.0.1:\(port)", deadlines: .init(firstProgress: 0.25, stalledProgress: 0.25, total: 2))
        do {
            _ = try await client.complete(model: "test", messages: [.init(role: "user", content: "Hello")], tools: []) { _ in }
            XCTFail("Keep-alive traffic must not keep a silent model alive")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("не начала ответ"), error.localizedDescription)
            XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        }
    }

}


/// A real loopback SSE server catches URLSession cancellation regressions without
/// starting a model, reserving GPU memory or depending on Python/Node.
private final class StalledInferenceServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "test.inference-stall")
    private var connections: [NWConnection] = []
    private var timers: [DispatchSourceTimer] = []
    init() throws { listener = try NWListener(using: .tcp, on: .any) }
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, _ in
                guard let self else { return }
                let request = String(data: data ?? Data(), encoding: .utf8) ?? ""
                if request.hasPrefix("GET ") {
                    connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".utf8), completion: .contentProcessed { _ in connection.cancel() })
                } else {
                    connection.send(content: Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                    let timer = DispatchSource.makeTimerSource(queue: self.queue)
                    timer.schedule(deadline: .now(), repeating: .milliseconds(30))
                    timer.setEventHandler { connection.send(content: Data(": keepalive\n\n".utf8), completion: .contentProcessed { _ in }) }
                    self.timers.append(timer); timer.resume()
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready: continuation.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let error): continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() {
        listener.cancel()
        queue.async { [self] in
            timers.forEach { $0.cancel() }; timers = []
            connections.forEach { $0.cancel() }; connections = []
        }
    }
}
