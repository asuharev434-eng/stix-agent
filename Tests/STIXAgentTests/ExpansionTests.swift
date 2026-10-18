import XCTest
@testable import STIXAgent

final class ExpansionTests: XCTestCase {
    private func temporaryRoot() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("STIX-expansion-" + UUID().uuidString) }
    func testOldStateWithoutNewFieldsDecodes() throws {
        let state = PersistedState(chats: [Chat()], preferences: AppPreferences())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        object.removeValue(forKey: "jobs")
        let decoded = try JSONDecoder().decode(PersistedState.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.jobs); XCTAssertNil(decoded.preferences.questionLevel); XCTAssertEqual(decoded.chats.count, 1)
    }
    @MainActor func testQuestionsEnforcedAndExcludedFromSecureInput() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        let chat = try XCTUnwrap(store.selectedID)
        store.jobs = [.init(chatID: chat, prompt: "task", status: "running")]; store.activeJobID = store.jobs[0].id
        store.preferences.questionLevel = 0
        let result = try await store.execute(.init(id: "q", name: "ask_user", arguments: #"{"question":"why?"}"#), chatID: chat)
        XCTAssertTrue(result.text.contains("Лимит")); XCTAssertNil(store.pending)
        store.preferences.questionLevel = 1
        XCTAssertTrue(store.questionAllowed(chatID: chat)); XCTAssertFalse(store.questionAllowed(chatID: chat))
        XCTAssertEqual(store.jobs[0].questionsAsked, 1)
        XCTAssertEqual(QuestionPolicy.budgets, [0,1,3,6,12])
    }
    @MainActor func testQueueSurvivesRestartWithoutReplaying() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = StateStorage(paths: .init(root: root))
        let store = AppStore(storage: storage), chat = try XCTUnwrap(store.selectedID)
        store.jobs = [.init(chatID: chat, prompt: "move file", status: "running", started: true, inputRecorded: true)]
        store.save()
        let restored = AppStore(storage: storage)
        XCTAssertEqual(restored.jobs[0].status, "interrupted"); XCTAssertFalse(restored.busy); XCTAssertNil(restored.task)
        restored.busy = true; restored.resumeJob(restored.jobs[0].id)
        XCTAssertEqual(restored.jobs[0].status, "queued"); XCTAssertNil(restored.task)
    }
    @MainActor func testDeleteCancelsQueuedChatJobs() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        let chat = try XCTUnwrap(store.selectedID); store.jobs = [.init(chatID: chat, prompt: "queued")]
        store.newChat(); store.deleteChat(chat)
        XCTAssertEqual(store.jobs[0].status, "cancelled")
    }
    @MainActor func testMemoryPersistsAcrossChatsAndCanBeForgotten() async throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = StateStorage(paths: .init(root: root)), store = AppStore(storage: .init(paths: .init(root: root)))
        let chat = try XCTUnwrap(store.selectedID)
        _ = try await store.execute(.init(id: "m", name: "manage_memory", arguments: #"{"action":"remember","text":"Use concise Russian"}"#), chatID: chat)
        store.newChat(); XCTAssertTrue(store.systemPrompt(chatID: try XCTUnwrap(store.selectedID)).contains("Use concise Russian"))
        let restored = AppStore(storage: storage); XCTAssertEqual(restored.preferences.memory, ["Use concise Russian"])
        _ = try await store.execute(.init(id: "f", name: "manage_memory", arguments: #"{"action":"forget","text":"all"}"#), chatID: chat)
        XCTAssertEqual(store.preferences.memory, [])
    }
    @MainActor func testBranchCutsDocumentEnrichedHistoryBySourceID() throws {
        let message = ChatMessage(role: "user", text: "Read attached PDF", attachments: [.init(path: "/tmp/example.pdf", kind: "file")])
        var chat = Chat(); chat.messages = [message, .init(role: "assistant", text: "later result")]
        chat.history = [.init(role: "user", content: "Read attached PDF\nextracted document body", sourceMessageID: message.id), .init(role: "assistant", content: "later result")]
        let branch = try XCTUnwrap(ChatTranscript.branch(chat, before: message.id))
        XCTAssertTrue(branch.history.isEmpty); XCTAssertTrue(branch.messages.isEmpty); XCTAssertEqual(chat.history.count, 2)
    }
    @MainActor func testFontAndQuestionSettingsValidate() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root))), chat = try XCTUnwrap(store.selectedID)
        _ = try store.applyPreference(key: "font_size", value: "18", chatID: chat)
        XCTAssertEqual(store.preferences.fontSize, 18)
        XCTAssertThrowsError(try store.applyPreference(key: "font_size", value: "nan", chatID: chat))
        XCTAssertThrowsError(try store.applyPreference(key: "question_level", value: "5", chatID: chat))
    }
    func testCredentialEnvironmentDeliveredWithoutInheritedSecrets() async throws {
        let result = try await ProcessRunner().run(command: "printf '%s' \"$STIX_TEST_VALUE\"", directory: nil, environment: ["STIX_TEST_VALUE": "fixture-value"])
        XCTAssertEqual(result.output, "fixture-value")
        do { _ = try await ProcessRunner().run(command: "true", directory: nil, environment: ["DYLD_INSERT_LIBRARIES": "bad"]); XCTFail("Unsafe env accepted") } catch {}
    }
    @MainActor func testOpaqueAttachmentCanStillBeMovedWithoutPretendingToReadIt() async throws {
        let root = temporaryRoot(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("archive.zip"); try Data([0,1,2,255]).write(to: file)
        let store = AppStore(storage: .init(paths: .init(root: root.appendingPathComponent("app"))))
        let result = try await store.prepareAgentAttachments([.init(path: file.path, kind: "file")])
        XCTAssertTrue(result.text.contains(file.path)); XCTAssertTrue(result.text.contains("не прочитано")); XCTAssertTrue(result.imageURLs.isEmpty)
    }
    @MainActor func testBranchRemapsSourceIDsForFutureEdits() throws {
        let first = ChatMessage(role: "user", text: "Read doc")
        let second = ChatMessage(role: "user", text: "next")
        var chat = Chat(); chat.messages = [first, second]
        chat.history = [.init(role: "user", content: "Read doc enriched", sourceMessageID: first.id), .init(role: "assistant", content: "result"), .init(role: "user", content: second.text, sourceMessageID: second.id)]
        let branch = try XCTUnwrap(ChatTranscript.branch(chat, before: second.id))
        XCTAssertEqual(branch.history.first?.sourceMessageID, branch.messages.first?.id)
        let earlier = try XCTUnwrap(ChatTranscript.branch(branch, before: try XCTUnwrap(branch.messages.first?.id)))
        XCTAssertTrue(earlier.history.isEmpty)
    }

    @MainActor func testThinkingTextIsTransientAndRedacted() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        store.preferences.thinking = true
        store.vault.remember("fake-secret-123")
        store.receiveReasoning("temporary-thought fake-secret-123 reasoning")
        XCTAssertFalse(store.reasoningText.contains("fake-secret-123"))
        store.save()
        let json = try String(contentsOf: store.storage.paths.state, encoding: .utf8)
        XCTAssertFalse(json.contains("temporary-thought")); XCTAssertFalse(json.contains("reasoningText"))
    }

    @MainActor func testLegacyInFlightTaskMigratesToExplicitResume() throws {
        let root = temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = StateStorage(paths: .init(root: root))
        var chat = Chat(); chat.messages = [.init(role: "user", text: "Connect API"), .init(role: "tool", text: "Pending", status: "running")]; chat.history = [.init(role: "user", content: "Connect API")]
        try storage.save(.init(chats: [chat], preferences: .init()))
        let restored = AppStore(storage: storage)
        XCTAssertEqual(restored.jobs.count, 1); XCTAssertEqual(restored.jobs[0].status, "interrupted")
        XCTAssertFalse(restored.busy); XCTAssertNil(restored.pending)
    }

    @MainActor func testReviewedPlanRollbackClearsHostReceiptsAndCards() async throws {
        let root = temporaryRoot(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("before".utf8).write(to: root.appendingPathComponent("note.txt"))
        let store = AppStore(storage: .init(paths: .init(root: root.appendingPathComponent("data")))); store.newChat(folder: root)
        let chat = try XCTUnwrap(store.selectedID)
        let preview = try await store.execute(.init(id: "preview", name: "preview_changes", arguments: JSONValue.object(["operations_json": .string(#"[{"kind":"write","path":"note.txt","content":"after"}]"#)]).encoded), chatID: chat)
        let id = try XCTUnwrap(preview.text.components(separatedBy: "\n").first).replacingOccurrences(of: "plan_id: ", with: "")
        let args = JSONValue.object(["plan_id": .string(id)])
        store.preferences.alwaysApprovals.insert(ApprovalPolicy.scope(tool: "apply_changes", arguments: args))
        _ = try await store.execute(.init(id: "apply", name: "apply_changes", arguments: args.encoded), chatID: chat)
        let receipt = try XCTUnwrap(store.undos.values.first)
        store.addMessage(.init(role: "tool", text: "written", status: "done", undoID: receipt.id), to: chat)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("note.txt")), "after")
        store.preferences.alwaysApprovals.insert(ApprovalPolicy.scope(tool: "rollback_changes", arguments: args))
        _ = try await store.execute(.init(id: "rollback", name: "rollback_changes", arguments: args.encoded), chatID: chat)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("note.txt")), "before")
        XCTAssertTrue(store.undos.isEmpty); XCTAssertNil(store.currentChat?.messages.last?.undoID)
        XCTAssertEqual(store.currentChat?.messages.last?.status, "undone")
    }

}
