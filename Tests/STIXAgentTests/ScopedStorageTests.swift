import XCTest
@testable import STIXAgent

final class ScopedStorageTests: XCTestCase {
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    func testLegacyMigrationIsVerifiedAndSeparatesAllSources() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var chat = Chat(folder: "/tmp/memory-project", model: "chosen-main")
        chat.messages = [.init(role: "user", text: "ORIGINAL_VISIBLE")]
        chat.history = [.init(role: "user", content: "ORIGINAL_MODEL_HISTORY")]
        chat.savedDraft = "Unsent draft"
        var prefs = AppPreferences(); prefs.memory = ["Keep originals", "Brief Russian"]
        prefs.modelRoles = ["coding": "chosen-coder"]
        let original = PersistedState(chats: [chat], preferences: prefs, jobs: [.init(chatID: chat.id, prompt: "Pending", status: "paused")])
        let bytes = try JSONEncoder().encode(original)
        try bytes.write(to: root.appendingPathComponent("state.json"))
        let store = StateStorage(paths: .init(root: root))
        let migrated = try XCTUnwrap(store.load())
        XCTAssertEqual(migrated.chats[0].messages, chat.messages)
        XCTAssertEqual(migrated.chats[0].history, chat.history)
        XCTAssertEqual(migrated.chats[0].savedDraft, chat.savedDraft)
        XCTAssertEqual(migrated.preferences.modelRoles, prefs.modelRoles)
        XCTAssertEqual(migrated.preferences.memory, prefs.memory)
        XCTAssertEqual(migrated.jobs?.first?.status, "paused")
        let chatRoot = root.appendingPathComponent("Chats/\(chat.id.uuidString)")
        for name in ["chat.json", "messages.jsonl", "history.jsonl", "context.json", "memory.md", "Actions/state.json"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: chatRoot.appendingPathComponent(name).path), name)
        }
        let settings = try String(contentsOf: root.appendingPathComponent("settings.json"), encoding: .utf8)
        XCTAssertFalse(settings.contains("ORIGINAL_VISIBLE")); XCTAssertFalse(settings.contains("Keep originals"))
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("Memory/preferences.md"), encoding: .utf8).contains("Keep originals"))
        let archived = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Backups/Migrations"), includingPropertiesForKeys: nil)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(archived.first).appendingPathComponent("state.json")), bytes)
        XCTAssertEqual(try store.load()?.chats[0].messages, chat.messages)
    }
    func testTransactionRecoversEntireCommittedGenerationAfterInterruption() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = StateStorage(paths: .init(root: root))
        var first = Chat(); first.messages = [.init(role: "user", text: "before")]
        try storage.save(.init(chats: [first], preferences: .init()))
        first.title = "After"; first.messages.append(.init(role: "assistant", text: "after"))
        let interrupted = StateStorage(paths: .init(root: root), transactionFault: { phase in
            if phase == "after-first-file" { throw AgentError.message("Simulated power loss") }
        })
        XCTAssertThrowsError(try interrupted.save(.init(chats: [first], preferences: .init())))
        let restored = try XCTUnwrap(StateStorage(paths: .init(root: root)).load())
        XCTAssertEqual(restored.chats[0].title, "After")
        XCTAssertEqual(restored.chats[0].messages.map(\.text), ["before", "after"])
    }

    func testExternalMarkdownEditIsNotOverwrittenByAutosave() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let storage = StateStorage(paths: .init(root: root))
        var prefs = AppPreferences(); prefs.memory = ["Original preference"]
        try storage.save(.init(chats: [Chat()], preferences: prefs))
        let path = root.appendingPathComponent("Memory/preferences.md")
        let changed = try String(contentsOf: path, encoding: .utf8).replacingOccurrences(of: "Original preference", with: "Externally edited preference")
        try Data(changed.utf8).write(to: path)
        XCTAssertThrowsError(try storage.save(.init(chats: [Chat()], preferences: prefs)))
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), changed)
        XCTAssertEqual(try StateStorage(paths: .init(root: root)).load()?.preferences.memory, ["Externally edited preference"])
    }
    func testMigrationCopiesManagedAttachmentAndKeepsOriginalPathAndBytes() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("Attachments")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let source = assets.appendingPathComponent("original.png"), bytes = Data([1,2,3,4,5])
        try bytes.write(to: source)
        let attachment = Attachment(path: source.path, kind: "image")
        var chat = Chat(); chat.messages = [.init(role: "assistant", text: "Image", attachments: [attachment])]
        chat.history = [.init(role: "user", content: "Keep source " + source.path)] + (0..<9).map { .init(role: "assistant", content: "Step \($0)") }
        let plan = try XCTUnwrap(ContextCompaction.plan(history: chat.history, checkpoint: nil))
        chat.contextCheckpoint = ContextCompaction.checkpoint(plan: plan, summary: "Keep source", model: "local")
        try JSONEncoder().encode(PersistedState(chats: [chat], preferences: .init())).write(to: root.appendingPathComponent("state.json"))
        let loaded = try XCTUnwrap(StateStorage(paths: .init(root: root)).load())
        XCTAssertEqual(loaded.chats[0].messages[0].attachments[0].path, source.path)
        XCTAssertEqual(loaded.chats[0].history, chat.history)
        XCTAssertEqual(loaded.chats[0].contextCheckpoint, chat.contextCheckpoint)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        let copy = root.appendingPathComponent("Chats/\(chat.id.uuidString)/Attachments/\(attachment.id.uuidString)-original.png")
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
    }
    func testMalformedMetadataFailsWithoutCrashingOrFallingBackToLegacy() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let chat = Chat(), storage = StateStorage(paths: .init(root: root))
        try storage.save(.init(chats: [chat], preferences: .init()))
        try Data("[]".utf8).write(to: root.appendingPathComponent("Chats/\(chat.id.uuidString)/chat.json"))
        XCTAssertThrowsError(try storage.load())
    }


    func testLegacyUUIDCasingDoesNotCountAsUnknownData() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var chat = Chat(); chat.messages = [.init(role: "user", text: "Preserve this message")]
        let original = PersistedState(chats: [chat], preferences: .init())
        let encoded = try JSONEncoder().encode(original)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
            .replacingOccurrences(of: chat.id.uuidString, with: chat.id.uuidString.lowercased())
        try Data(text.utf8).write(to: root.appendingPathComponent("state.json"))
        let migrated = try XCTUnwrap(StateStorage(paths: .init(root: root)).load())
        XCTAssertEqual(migrated.chats[0].id, chat.id)
        XCTAssertEqual(migrated.chats[0].messages, chat.messages)
    }

    func testUnknownLegacyFieldStopsMigrationWithoutDroppingIt() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(PersistedState(chats: [Chat()], preferences: .init()))
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String:Any])
        raw["futureImportantField"] = "must survive"
        let original = try JSONSerialization.data(withJSONObject: raw)
        try original.write(to: root.appendingPathComponent("state.json"))
        XCTAssertThrowsError(try StateStorage(paths: .init(root: root)).load())
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("state.json")), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("store.json").path))
    }
    func testPerChatArtifactsAllowedButPrivateHistoryAndLinksRemainProtected() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppStoragePaths(root: root), id = UUID()
        try FileManager.default.createDirectory(at: paths.chatAttachments(id), withIntermediateDirectories: true)
        let tool = FileTools(paths: paths)
        XCTAssertNoThrow(try tool.resolve(paths.chatAttachments(id).appendingPathComponent("image.png").path, workingDirectory: nil))
        XCTAssertThrowsError(try tool.resolve(root.appendingPathComponent("Chats/\(id)/history.jsonl").path, workingDirectory: nil))
        let target = root.appendingPathComponent("settings.json")
        try Data("private".utf8).write(to: target)
        let link = paths.chatAttachments(id).appendingPathComponent("leak.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try tool.resolve(link.path, workingDirectory: nil))
    }

    func testMissingCanonicalChatFailsClosedInsteadOfLoadingEmptyHistory() throws {
        let root = root(); defer { try? FileManager.default.removeItem(at: root) }
        let chat = Chat()
        let storage = StateStorage(paths: .init(root: root))
        try storage.save(.init(chats: [chat], preferences: .init()))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Chats/\(chat.id.uuidString)/history.jsonl"))
        XCTAssertThrowsError(try storage.load())
    }
    func testCanonicalSymlinkCannotOverwriteExternalFile() throws {
        let root = root(), outside = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("private".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("settings.json"), withDestinationURL: outside)
        XCTAssertThrowsError(try StateStorage(paths: .init(root: root)).save(.init(chats: [Chat()], preferences: .init())))
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "private")
    }
}
