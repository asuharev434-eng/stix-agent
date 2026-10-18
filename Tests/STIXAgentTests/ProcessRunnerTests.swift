import XCTest
@testable import STIXAgent

final class ProcessRunnerTests: XCTestCase {
    func testOutputAndExit() async throws {
        let result = try await ProcessRunner().run(command: "printf hello; printf error >&2; exit 7", directory: nil)
        XCTAssertTrue(result.output.contains("hello")); XCTAssertTrue(result.output.contains("error"))
        XCTAssertEqual(result.exitCode, 7); XCTAssertFalse(result.timedOut)
    }
    func testTimeout() async throws {
        let start = Date()
        let result = try await ProcessRunner().run(command: "sleep 30 & wait", directory: nil, timeout: 0.15)
        XCTAssertTrue(result.timedOut); XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }
    func testCancellation() async throws {
        let task = Task { try await ProcessRunner().run(command: "sleep 30 & wait", directory: nil) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation expected") }
        catch is CancellationError {} 
    }
}
