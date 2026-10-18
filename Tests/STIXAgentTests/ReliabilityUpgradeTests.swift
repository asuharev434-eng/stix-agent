import XCTest
@testable import STIXAgent

final class ReliabilityUpgradeTests: XCTestCase {
    @MainActor func testMemoryHistoryRestoresDeletedRecordAfterReloadWithoutCrossScopeLeak() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        let first = try XCTUnwrap(store.selectedID)
        try store.remember("Исходное предпочтение", scope: .chat, category: .notes, chatID: first)
        var entry = try XCTUnwrap(store.memoryRecords(scope: .chat, chatID: first).first)
        entry.text = "Изменённое предпочтение"; try store.updateMemory(entry, chatID: first)
        try store.forgetMemory(entry.id, scope: .chat, chatID: first)
        let restored = AppStore(storage: .init(paths: .init(root: root)))
        let versions = restored.memoryHistory(scope: .chat, chatID: first)
        XCTAssertEqual(versions.count, 3)
        let revision = try XCTUnwrap(versions.first { $0.before?.text == "Исходное предпочтение" })
        restored.newChat(); let other = try XCTUnwrap(restored.selectedID)
        XCTAssertTrue(restored.memoryHistory(scope: .chat, chatID: other).isEmpty)
        XCTAssertThrowsError(try restored.restoreMemory(revision.id, chatID: other))
        try restored.restoreMemory(revision.id, chatID: first)
        XCTAssertEqual(restored.memoryRecords(scope: .chat, chatID: first).first?.text, "Исходное предпочтение")
        XCTAssertEqual(try StateStorage(paths: .init(root: root)).load()?.memoryRevisions?.count, 4)
    }

    func testRecoveryVerificationDetectsExternalEditsAndMissingMoves() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppStoragePaths(root: root.appendingPathComponent("Data")); try paths.prepare()
        let folder = root.appendingPathComponent("Work"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let tools = FileTools(paths: paths), file = folder.appendingPathComponent("a.txt")
        let receipt = try tools.write(path: file.path, content: "original", workingDirectory: nil)
        XCTAssertTrue(try ResultVerifier.receipt(receipt, paths: paths).passed)
        try Data("external edit".utf8).write(to: file)
        XCTAssertFalse(try ResultVerifier.receipt(receipt, paths: paths).passed)
        let moved = try tools.move(source: file.path, destination: folder.appendingPathComponent("b.txt").path, workingDirectory: nil)
        XCTAssertTrue(try ResultVerifier.receipt(moved, paths: paths).passed)
        try FileManager.default.removeItem(atPath: moved.destination!)
        XCTAssertFalse(try ResultVerifier.receipt(moved, paths: paths).passed)
    }

    @MainActor func testStopMessagePausesInsteadOfQueueingAndSkipIsDurable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root))), chat = try XCTUnwrap(store.selectedID)
        store.jobs = [.init(chatID: chat, prompt: "active", status: "running")]
        store.activeJobID = store.jobs[0].id; store.activeChatID = chat; store.busy = true
        store.draft = "пропусти этот шаг"; store.send()
        XCTAssertEqual(store.jobs.count, 1)
        XCTAssertTrue(store.consumeSkippedStep(chatID: chat))
        XCTAssertFalse(store.consumeSkippedStep(chatID: chat))
        store.draft = "остановись"; store.send()
        XCTAssertEqual(store.jobs[0].status, "paused")
        XCTAssertEqual(store.jobs.count, 1)
    }

    func testRoutingUsesSizeAndRejectsNonVisionExplicitImageModel() throws {
        let installed = [ModelDescriptor(id: "local-27b", kind: "vlm"), ModelDescriptor(id: "local-8b", kind: "llm"), ModelDescriptor(id: "local-4b-vl", kind: "vlm")]
        let assignments = ModelOrchestrator.effectiveAssignments(installed: installed, configured: [:], physicalMemory: 16 * 1024 * 1024 * 1024)
        XCTAssertEqual(assignments["vision"], "local-4b-vl")
        XCTAssertNotEqual(assignments["general"], "local-27b")
        let args: JSONValue = .object(["model_id": .string("local-8b"), "task": .string("Describe"), "reason": .string("Photo"), "image_paths": .array([.string("/tmp/photo.png")])])
        XCTAssertThrowsError(try ModelOrchestrator.request(args, installed: installed, assignments: assignments))
    }

    func testCapturedContextSeparatesExactMemoryAndDoesNotExposeBase64() {
        let snapshot = ContextRequestSnapshot(model: "main", system: "instructions\n<stix-memory>\nchosen fact\n</stix-memory>", history: [.init(role: "user", content: "latest", imageURLs: ["data:image/png;base64,PRIVATE_PIXELS"])], tools: [])
        XCTAssertTrue(snapshot.instructions.contains("instructions"))
        XCTAssertFalse(snapshot.instructions.contains("chosen fact"))
        XCTAssertTrue(snapshot.memory.contains("chosen fact"))
        XCTAssertTrue(snapshot.transcript.contains("latest"))
        XCTAssertFalse(snapshot.transcript.contains("PRIVATE_PIXELS"))
    }

    @MainActor func testAutomaticWriteVerificationChecksSyntaxWithoutRunningCode() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root.appendingPathComponent("Data"))))
        let chat = try XCTUnwrap(store.selectedID), work = root.appendingPathComponent("Work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        store.chats[0].folder = work.path
        store.jobs = [.init(chatID: chat, prompt: "write code", status: "running")]
        store.activeJobID = store.jobs[0].id
        let code = "raise RuntimeError('MUST NOT RUN')\nif :\n  pass\n"
        let args: JSONValue = .object(["path": .string(work.appendingPathComponent("bad.py").path), "content": .string(code)])
        _ = try await store.execute(.init(id: "write", name: "write_file", arguments: args.encoded), chatID: chat)
        XCTAssertTrue(store.jobs[0].verifications?.contains(where: { !$0.passed && $0.detail.contains("SyntaxError") }) == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("__pycache__").path))
    }

    @MainActor func testUpgradeOfPreviousSplitStorePreservesAllDataAndAddsHistoryAtomically() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StateStorage(paths: .init(root: root))
        var chat = Chat(); chat.messages = [.init(role: "user", text: "Keep this")]
        var prefs = AppPreferences(); prefs.memory = ["Keep memory"]
        try storage.save(.init(chats: [chat], preferences: prefs))
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("store.json"))) as? [String:Any])
        manifest.removeValue(forKey: "memoryHistoryVersion")
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("store.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Memory/history.jsonl"))
        let upgraded = AppStore(storage: .init(paths: .init(root: root)))
        XCTAssertTrue(upgraded.canPersist)
        XCTAssertEqual(upgraded.chats[0].messages, chat.messages)
        XCTAssertEqual(upgraded.memoryEntries.first?.text, "Keep memory")
        try upgraded.remember("New preference", scope: .personal, category: .preferences, chatID: chat.id)
        let loaded = try XCTUnwrap(StateStorage(paths: .init(root: root)).load())
        XCTAssertEqual(loaded.chats[0].messages, chat.messages)
        XCTAssertEqual(loaded.memoryEntries?.count, 2)
        XCTAssertEqual(loaded.memoryRevisions?.count, 1)
        try FileManager.default.removeItem(at: root.appendingPathComponent("Memory/history.jsonl"))
        XCTAssertThrowsError(try StateStorage(paths: .init(root: root)).load())
    }

    @MainActor func testNativePlanApplyCreatesUndoAndReplayDoesNotTouchFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root.appendingPathComponent("Data"))))
        let work = root.appendingPathComponent("Work"), chat = try XCTUnwrap(store.selectedID)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        store.chats[0].folder = work.path; store.save()
        let source = work.appendingPathComponent("a.txt"), target = work.appendingPathComponent("b.txt")
        try Data("original".utf8).write(to: source)
        let operations: JSONValue = .array([.object(["kind": .string("move"), "source": .string(source.path), "destination": .string(target.path)])])
        let preview = try FileChangePlanner(paths: store.storage.paths).preview(operations: operations, workingDirectory: work.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path)); XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        await store.applyReviewedPlan(preview.id, chatID: chat)
        XCTAssertEqual(store.jobs.last?.status, "done"); XCTAssertEqual(store.undos.count, 1)
        XCTAssertTrue(store.currentChat?.history.contains(where: { $0.role == "user" && $0.content?.contains(preview.id) == true }) == true)
        XCTAssertTrue(store.currentChat?.history.contains(where: { $0.role == "assistant" && $0.content?.contains("План применён") == true && $0.content?.contains(target.path) == true }) == true)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
        await store.applyReviewedPlan(preview.id, chatID: chat)
        XCTAssertEqual(store.jobs.last?.status, "failed"); XCTAssertEqual(store.undos.count, 1)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
    }

    @MainActor func testNativePlanReportsSyntaxFailureToMainModel() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root.appendingPathComponent("Data"))))
        let work = root.appendingPathComponent("Work"), chat = try XCTUnwrap(store.selectedID)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        store.chats[0].folder = work.path; store.save()
        let code = work.appendingPathComponent("bad.py")
        let ops: JSONValue = .array([.object(["kind": .string("write"), "path": .string(code.path), "content": .string("if :\n  pass\n")])])
        let plan = try FileChangePlanner(paths: store.storage.paths).preview(operations: ops, workingDirectory: work.path)
        await store.applyReviewedPlan(plan.id, chatID: chat)
        XCTAssertTrue(store.currentChat?.history.contains(where: { $0.role == "assistant" && $0.content?.contains("SyntaxError") == true }) == true)
        XCTAssertTrue(store.jobs.last?.verifications?.contains(where: { !$0.passed }) == true)
    }

    func testImageValidationRejectsTextDisguisedAsPNG() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("bad.png"); try Data("not image".utf8).write(to: file)
        XCTAssertFalse(try ResultVerifier.image(file.path, paths: .init(root: root.appendingPathComponent("Data"))).passed)
    }

    @MainActor func testResumedImageSubmissionCannotGenerateAgainWithoutNewTask() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        let chat = try XCTUnwrap(store.selectedID)
        store.jobs = [.init(chatID: chat, prompt: "/image photo", status: "running", imageReplayBlocked: true)]
        store.activeJobID = store.jobs[0].id
        do { try await store.generateImage(prompt: "photo", chatID: chat); XCTFail("Must not submit image to any service") }
        catch { XCTAssertTrue(error.localizedDescription.contains("повтор")) }
        XCTAssertTrue(store.currentChat?.messages.isEmpty == true)
    }

    func testMemoryConflictReviewKeepsSourcesAndDoesNotMixOwners() {
        let owner = UUID()
        let records = [
            MemoryEntry(scope: .project, ownerID: owner, category: .decisions, text: "Язык: Swift", source: "Чат A", order: 0),
            MemoryEntry(scope: .project, ownerID: owner, category: .decisions, text: "Язык: Python", source: "Чат B", order: 1),
            MemoryEntry(scope: .project, ownerID: UUID(), category: .decisions, text: "Язык: Go", source: "OTHER_PROJECT", order: 2)
        ]
        let notes = MemoryReview.notes(records)
        XCTAssertTrue(notes[records[0].id]?.contains("Чат B") == true)
        XCTAssertFalse(notes.values.joined().contains("OTHER_PROJECT"))
        XCTAssertNil(notes[records[2].id])
    }

    func testAutomaticRoutingRespectsAvailableMemoryButCanUseAlreadyLoadedModel() {
        let models = [ModelDescriptor(id: "coder-8b", kind: "llm"), ModelDescriptor(id: "ready-8b", kind: "llm", contextLimitIsLoaded: true)]
        let roles = ModelOrchestrator.effectiveAssignments(installed: models, configured: [:], physicalMemory: 24 * 1024 * 1024 * 1024, availableMemory: 1024 * 1024 * 1024)
        XCTAssertEqual(roles["coding"], "ready-8b")
        let explicit = ModelOrchestrator.effectiveAssignments(installed: models, configured: ["coding": "coder-8b"], physicalMemory: 24 * 1024 * 1024 * 1024, availableMemory: 1024 * 1024 * 1024)
        XCTAssertEqual(explicit["coding"], "coder-8b")
    }

    func testDoctorDiskReportOffersActionOnlyWhenLow() {
        XCTAssertTrue(Diagnostics.diskReport(availableBytes: 100_000_000).contains("Освободите"))
        XCTAssertFalse(Diagnostics.diskReport(availableBytes: 80_000_000_000).contains("Освободите"))
    }
}
