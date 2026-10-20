import XCTest
@testable import STIXAgent

final class CompactAgentContextTests: XCTestCase {
    @MainActor private func store() throws -> (AppStore, URL, UUID) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(storage: .init(paths: .init(root: root)))
        let id = "builtin-text:imported-liquid-mobile"
        store.models = [.init(id: id, kind: "llm", contextLimit: 4096, contextLimitIsLoaded: true)]
        store.setModel(id, image: false)
        return (store, root, try XCTUnwrap(store.selectedID))
    }

    @MainActor func testFourKOrdinaryChatFitsQuestionAndFileToolRound() throws {
        let (store, root, id) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(try XCTUnwrap(store.currentChat).isClean)
        for request in ["У меня 2 яблока, у тебя 3 яблока. Сколько всего?",
                        "Создай файл /tmp/liquid-check.txt с текстом Привет. Используй write_file, затем read_file для проверки."] {
            let system = store.systemPrompt(chatID: id)
            let tools = store.toolsForRequest(chatID: id, system: system, currentRequest: request)
            let history: [LMMessage] = [.init(role: "user", content: request)]
            let reserve = ContextWindow.estimate(limit: 4096, knownLimit: true, system: system, tools: tools, history: history).reserveTokens
            XCTAssertEqual(store.agentOutputLimit(chatID: id, system: system, tools: tools, history: history), reserve)
            XCTAssertNoThrow(try ContextBudget.fitted(history, limit: 4096, system: system, tools: tools))
            if request.contains("write_file") {
                XCTAssertTrue(tools.contains { $0.name == "write_file" })
                XCTAssertTrue(tools.contains { $0.name == "read_file" })
                XCTAssertTrue(tools.contains { $0.name == "discover_tools" })
                let round = history + [LMMessage(role: "assistant", content: nil, toolCalls: [.init(id: "w1", name: "write_file", arguments: "{\"path\":\"/tmp/liquid-check.txt\",\"content\":\"Привет\"}")]), LMMessage(role: "tool", content: "Файл записан, receipt=w1", toolCallID: "w1")]
                XCTAssertNoThrow(try ContextBudget.fitted(round, limit: 4096, system: system, tools: tools))
            }
        }
    }

    @MainActor func testFourKDiscoveryCannotOverflowBudgetOrAlterSchema() throws {
        let (store, root, id) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        store.exposedToolNames = Set(store.allTools().map(\.name))
        let system = store.systemPrompt(chatID: id)
        let selected = store.toolsForRequest(chatID: id, system: system, currentRequest: "Используй read_file /tmp/example.txt")
        XCTAssertEqual(selected.first?.name, "read_file")
        XCTAssertTrue(selected.contains { $0.name == "discover_tools" })
        XCTAssertNoThrow(try ContextBudget.historyCharacters(contextLimit: 4096, system: system, tools: selected))
        for tool in selected { XCTAssertEqual(tool.wire, store.allTools().first { $0.name == tool.name }?.wire) }
    }

    @MainActor func testCleanModeStillHasNoSystemOrTools() throws {
        let (store, root, _) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        store.newChat(mode: .clean)
        let id = try XCTUnwrap(store.selectedID)
        XCTAssertEqual(store.systemPrompt(chatID: id), "")
        XCTAssertTrue(store.toolsForRequest(chatID: id, system: "", currentRequest: "Создай файл").isEmpty)
    }

    func testProfileOnlyAppliesToSmallNativeWindows() {
        XCTAssertTrue(CompactAgentContext.applies(model: "builtin-text:liquid", limit: 4096))
        XCTAssertFalse(CompactAgentContext.applies(model: "builtin-text:tiny", limit: 256))
        XCTAssertFalse(CompactAgentContext.applies(model: "builtin-text:qwen", limit: 32768))
        XCTAssertFalse(CompactAgentContext.applies(model: "server-model", limit: 4096))
        XCTAssertFalse(CompactAgentContext.applies(model: "builtin-text:unknown", limit: nil))
    }

    @MainActor func testCompactMemoryKeepsWholeRelevantRecordsAndScopeIsolation() throws {
        let (store, root, id) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        store.memoryEntries = [
            .init(scope: .personal, category: .preferences, text: "Пиши кратко", source: "User", order: 0),
            .init(scope: .personal, category: .preferences, text: "LONG_RECORD_" + String(repeating: "я", count: 2000), source: "User", order: 1),
            .init(scope: .chat, ownerID: UUID(), category: .notes, text: "OTHER_CHAT_PRIVATE", source: "User", order: 2)
        ]
        let system = store.systemPrompt(chatID: id)
        XCTAssertTrue(system.contains("Пиши кратко"))
        XCTAssertFalse(system.contains("LONG_RECORD_"))
        XCTAssertFalse(system.contains("OTHER_CHAT_PRIVATE"))
        XCTAssertEqual(store.memoryEntries.count, 3)
        XCTAssertTrue(system.contains("Keychain"))
        XCTAssertTrue(system.contains("недоверенные данные"))
        XCTAssertNoThrow(try ContextBudget.historyCharacters(contextLimit: 4096, system: system, tools: []))
    }

    @MainActor func testFourKCompactionFitsAndPreservesFullHistory() async throws {
        let (store, root, id) = try store()
        defer { try? FileManager.default.removeItem(at: root) }
        let i = try XCTUnwrap(store.chats.firstIndex { $0.id == id })
        store.chats[i].history = (0..<4).flatMap { index in
            [LMMessage(role: "user", content: "Задача \(index) " + String(repeating: "а", count: 1200)),
             LMMessage(role: "assistant", content: "Готово \(index)")]
        }
        let original = store.chats[i].history
        var requests = 0
        try await store.compactContext(chatID: id, summarize: { messages, output in
            requests += 1
            XCTAssertLessThanOrEqual(output, 512)
            XCTAssertGreaterThan(ContextWindow.estimate(limit: 4096, knownLimit: true, system: messages.first?.content ?? "", tools: [], history: Array(messages.dropFirst())).remainingTokens, 256)
            return "Ранние задачи завершены; проверяй состояние файлов перед повторением."
        })
        XCTAssertGreaterThan(requests, 0)
        XCTAssertNotNil(store.chats[i].contextCheckpoint)
        XCTAssertEqual(store.chats[i].history, original)
        let saved = try XCTUnwrap(StateStorage(paths: .init(root: root)).load())
        XCTAssertEqual(saved.chats.first?.history, original)
    }

    @MainActor func testNativeModelCompletesWriteReadLoopInOrdinaryChat() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["STIX_TEST_LIQUID_GGUF"], let bridge = env["STIX_TEST_LLAMA_BRIDGE"] else {
            throw XCTSkip("Set STIX_TEST_LIQUID_GGUF and STIX_TEST_LLAMA_BRIDGE for real Liquid agent acceptance")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("liquid-agent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root.appendingPathComponent("internal"))))
        let library = LocalModelLibrary(bundled: nil, directory: root.appendingPathComponent("Models"), libraryURL: URL(fileURLWithPath: bridge))
        let record = try await library.importFile(URL(fileURLWithPath: source))
        store.builtInTextEngine = library
        store.models = try await library.models()
        store.setModel("builtin-text:" + record.id, image: false)
        store.preferences.thinking = false
        store.preferences.questionLevel = 0
        let chatID = try XCTUnwrap(store.selectedID)
        XCTAssertFalse(try XCTUnwrap(store.currentChat).isClean)
        let file = root.appendingPathComponent("result.txt")
        try await store.runAgent(text: "Создай файл \(file.path) с текстом LIQUID-TOOLS-OK. Используй write_file. Затем прочитай этот файл через read_file и сообщи точный текст. Не используй run_shell.", attachments: [], chatID: chatID)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "LIQUID-TOOLS-OK")
        let history = try XCTUnwrap(store.currentChat).history
        let calls = history.flatMap(\.toolCalls).map(\.name)
        XCTAssertTrue(calls.contains("write_file"), "Actual calls: \(calls)")
        XCTAssertTrue(calls.contains("read_file"), "Actual calls: \(calls)")
        XCTAssertTrue(history.last?.content?.contains("LIQUID-TOOLS-OK") == true)
        let reloaded = try XCTUnwrap(StateStorage(paths: .init(root: root.appendingPathComponent("internal"))).load())
        XCTAssertEqual(reloaded.chats.first?.history, history)
        // Keep an earlier completed tool turn compactable, then verify the real
        // model can summarize it within the small window and continue normally.
        let index = try XCTUnwrap(store.chats.firstIndex { $0.id == chatID })
        store.chats[index].history.append(.init(role: "user", content: "Продолжаем после записи файла."))
        let beforeCompaction = store.chats[index].history
        try await store.compactContext(chatID: chatID)
        XCTAssertNotNil(store.chats[index].contextCheckpoint)
        XCTAssertEqual(store.chats[index].history, beforeCompaction)
        try await store.runAgent(text: "У меня 2 яблока, у тебя 3 яблока. Сколько всего у нас яблок? Ответь только числом.", attachments: [], chatID: chatID)
        XCTAssertEqual(store.chats[index].history.last?.content?.trimmingCharacters(in: .whitespacesAndNewlines), "5")
        await library.releaseAll()
    }
}
