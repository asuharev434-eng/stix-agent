import XCTest
@testable import STIXAgent

final class DiagnosticsTests: XCTestCase {
    func testRejectsExternalAndCredentialEndpoints() throws {
        for endpoint in ["https://example.com", "http://user:secret@127.0.0.1:1234", "http://localhost:1234?token=private", "file:///tmp/model"] {
            XCTAssertThrowsError(try Diagnostics.localURL(endpoint: endpoint, path: "/queue"))
        }
        XCTAssertEqual(try Diagnostics.localURL(endpoint: "http://localhost:1234/v1", path: "/v1/models", lm: true).absoluteString, "http://localhost:1234/v1/models")
        XCTAssertEqual(try Diagnostics.localURL(endpoint: "http://[::1]:8188", path: "/queue").host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), "::1")
    }
    func testLMReportsMissingModelWithoutExposingBody() async {
        let fetch: Diagnostics.Fetch = { _ in .object(["data": .array([.object(["id": .string("local-model")])]), "secret": .string("do-not-display")]) }
        let report = await Diagnostics.inspectLM(endpoint: "http://127.0.0.1:1234", selected: "missing", fetch: fetch)
        XCTAssertTrue(report.contains("отсутствует"))
        XCTAssertFalse(report.contains("do-not-display"))
    }
    func testComfyReportsActualQueueAndMissingCheckpoints() async {
        let fetch: Diagnostics.Fetch = { url in
            if url.path == "/queue" { return .object(["queue_running": .array([.null]), "queue_pending": .array([.null, .null])]) }
            return .object(["CheckpointLoaderSimple": .object(["input": .object(["required": .object(["ckpt_name": .array([.array([])])])])])])
        }
        let report = await Diagnostics.inspectComfy(endpoint: "http://localhost:8188", fetch: fetch)
        XCTAssertTrue(report.contains("выполняются 1, ожидают 2"))
        XCTAssertTrue(report.contains("checkpoint-моделей нет"))
    }
    func testErrorsNeverEchoSecrets() async {
        let fetch: Diagnostics.Fetch = { _ in throw AgentError.message("password=top-secret") }
        let report = await Diagnostics.inspectLM(endpoint: "http://localhost:1234", selected: "", fetch: fetch)
        XCTAssertFalse(report.contains("top-secret"))
        XCTAssertTrue(report.contains("Запустите"))
    }
    @MainActor func testReportSummarizesQueueAndMemoryWithoutReadingContents() async {
        var preferences = AppPreferences(); preferences.memory = ["secret-memory-text"]
        let jobs = [AgentJob(chatID: UUID(), prompt: "private-prompt", status: "queued")]
        let report = await Diagnostics.run(preferences: preferences, jobs: jobs, fetch: { _ in .object([:]) })
        XCTAssertTrue(report.contains("1 записей"))
        XCTAssertTrue(report.contains("ожидают 1"))
        XCTAssertFalse(report.contains("secret-memory-text")); XCTAssertFalse(report.contains("private-prompt"))
    }
    @MainActor func testUnbundledVoiceFailsBeforeRequestingPermissions() async throws {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") == nil else { throw XCTSkip("Requires unbundled test executable") }
        let voice = VoiceInputController()
        var emitted = false
        await voice.start { _ in emitted = true }
        XCTAssertFalse(voice.isRecording)
        XCTAssertFalse(voice.isRequestingPermission)
        XCTAssertNotNil(voice.errorMessage)
        voice.stop(); voice.cancel()
        XCTAssertFalse(emitted)
    }
    @MainActor func testVoiceTranscriptOnlyAppendsToDraft() {
        XCTAssertEqual(VoiceInputController.appending("  сказано  ", to: "Черновик"), "Черновик сказано")
        XCTAssertEqual(VoiceInputController.appending("сказано", to: "Черновик\n"), "Черновик\nсказано")
        XCTAssertEqual(VoiceInputController.appending(" \n", to: "Черновик"), "Черновик")
    }
}
