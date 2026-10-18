import XCTest
@testable import STIXAgent

final class LiveContextTests: XCTestCase {
    func testLocalSummaryRetainsConstraintsAndSupportsContinuation() async throws {
        guard ProcessInfo.processInfo.environment["STIX_AGENT_LIVE_FEATURES"] == "1" else { throw XCTSkip("Opt-in local context compaction") }
        let client = LMStudioClient(endpoint: "http://127.0.0.1:1235")
        let transcript: [LMMessage] = [
            .init(role: "user", content: "Запомни условия задачи: идентификатор проекта CTX-4731. Файл /tmp/stix-context-note.py. Исходник не удалять. Следующий шаг: добавить функцию add(a,b)."),
            .init(role: "assistant", content: nil, toolCalls: [.init(id: "read", name: "read_file", arguments: "{\"path\":\"/tmp/stix-context-note.py\"}")]),
            .init(role: "tool", content: "Файл прочитан: def subtract(a,b): return a-b. Изменений ещё нет.", toolCallID: "read"),
            .init(role: "user", content: "Сначала нужно резюме для продолжения; ничего не выполняй.")
        ]
        let summary = try await client.complete(model: "qwen3-8b-abliterated", messages: [
            .init(role: "system", content: ContextCompaction.summaryInstruction(maximumCharacters: 3000)),
            .init(role: "user", content: transcript.map(ContextCompaction.transcript).joined(separator: "\n"))
        ], tools: [], maxOutputTokens: 1024, preserveContext: true, thinking: false) { _ in }
        XCTAssertTrue(summary.toolCalls.isEmpty)
        XCTAssertTrue(summary.content.contains("CTX-4731"), summary.content)
        XCTAssertTrue(summary.content.contains("/tmp/stix-context-note.py"), summary.content)
        XCTAssertTrue(summary.content.contains("add"), summary.content)
        let continuation = try await client.complete(model: "qwen3-8b-abliterated", messages: [
            .init(role: "system", content: "Ответь кратко по данным резюме. Ничего не выполняй."),
            .init(role: "user", content: "Резюме предыдущей переписки:\n" + summary.content),
            .init(role: "user", content: "Назови идентификатор проекта, путь файла и следующий шаг. Можно ли удалять исходник?")
        ], tools: [], maxOutputTokens: 512, preserveContext: true, thinking: false) { _ in }
        XCTAssertTrue(continuation.toolCalls.isEmpty)
        XCTAssertTrue(continuation.content.contains("CTX-4731"), continuation.content)
        XCTAssertTrue(continuation.content.contains("/tmp/stix-context-note.py"), continuation.content)
        XCTAssertTrue(continuation.content.lowercased().contains("add"), continuation.content)
        let answer = continuation.content.lowercased()
        XCTAssertTrue(answer.contains("нельзя") || answer.contains("не удал") || answer.contains("нет"), continuation.content)
    }
}
