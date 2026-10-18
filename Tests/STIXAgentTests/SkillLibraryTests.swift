import XCTest
@testable import STIXAgent

final class SkillLibraryTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("skills-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func content(_ name: String = "tidy-files") -> String { "---\nname: \(name)\ndescription: Sort local files by extension when requested.\n---\n\nPreview file moves, apply and verify results." }
    func testSeedSaveReadAndVersionsKeepInstructions() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let library = SkillLibrary(paths: .init(root: root))
        try library.seed()
        XCTAssertTrue(try library.read("skill-creator").contains("manage_skill"))
        let directory = try library.save(name: "tidy-files", content: content())
        let first = try library.read("tidy-files")
        try library.save(name: "tidy-files", content: content() + "\nKeep originals.")
        let revisions = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent(".revisions"), includingPropertiesForKeys: nil)
        XCTAssertEqual(revisions.count, 1)
        XCTAssertEqual(try String(contentsOf: revisions[0], encoding: .utf8), first)
        XCTAssertFalse(try library.list(disabled: ["tidy-files"]).first(where: { $0.name == "tidy-files" })!.enabled)
    }
    func testRejectsTraversalMismatchedMetadataAndSymlinks() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let library = SkillLibrary(paths: .init(root: root)); try library.seed()
        XCTAssertThrowsError(try library.save(name: "../oops", content: content()))
        XCTAssertThrowsError(try library.save(name: "other", content: content()))
        let outside = root.appendingPathComponent("outside"); try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: library.root.appendingPathComponent("linked"), withDestinationURL: outside)
        XCTAssertThrowsError(try library.save(name: "linked", content: content("linked")))
        XCTAssertThrowsError(try SkillLibrary.metadata("---\nname: empty\ndescription: Desc\n---\n"))
    }
    func testImportResourcesAndRejectsLinkedResource() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let library = SkillLibrary(paths: .init(root: root.appendingPathComponent("app")))
        let source = root.appendingPathComponent("source"); try FileManager.default.createDirectory(at: source.appendingPathComponent("references"), withIntermediateDirectories: true)
        try content().write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try "doc".write(to: source.appendingPathComponent("references/api.md"), atomically: true, encoding: .utf8)
        let installed = try library.importFolder(source)
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("references/api.md"), encoding: .utf8), "doc")
        XCTAssertThrowsError(try library.importFolder(source))
        try content("bad-skill").write(to: source.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("references/link"), withDestinationURL: root)
        XCTAssertThrowsError(try library.importFolder(source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.root.appendingPathComponent("bad-skill").path))
    }
    func testSkillResourcesCanBeReadAndWrittenWithoutOpeningInternalState() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppStoragePaths(root: root); try paths.prepare()
        let library = SkillLibrary(paths: paths)
        let skill = try library.save(name: "tidy-files", content: content())
        let tools = FileTools(paths: paths)
        let resource = skill.appendingPathComponent("references/rules.md")
        let receipt = try tools.write(path: resource.path, content: "Local sorting rules", workingDirectory: nil)
        XCTAssertEqual(try tools.read(path: resource.path, workingDirectory: nil), "Local sorting rules")
        XCTAssertThrowsError(try tools.read(path: paths.state.path, workingDirectory: nil))
        let link = skill.appendingPathComponent("references/state-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: paths.state)
        XCTAssertThrowsError(try tools.read(path: link.path, workingDirectory: nil))
        _ = try tools.undo(receipt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: resource.path))
    }
    @MainActor func testSkillInvocationMemoryAndDraftsSurviveReload() throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        let first = try XCTUnwrap(store.selectedID)
        store.draft = "first draft"; store.newChat(); let second = try XCTUnwrap(store.selectedID)
        store.draft = "second draft"; store.selectChat(first)
        XCTAssertEqual(store.draft, "first draft")
        store.selectChat(second); XCTAssertEqual(store.draft, "second draft")
        try store.setMemory(["Рабочая папка: /tmp/local", "Краткие ответы"])
        XCTAssertTrue(try XCTUnwrap(store.skillPrompt("/skill/skill-creator Создай сортировщик")).contains("Создай сортировщик"))
        store.preferences.disabledSkills = ["skill-creator"]
        XCTAssertThrowsError(try store.skillPrompt("$skill-creator Create"))
        store.save()
        let restored = AppStore(storage: store.storage)
        XCTAssertEqual(restored.preferences.memory?.count, 2)
        XCTAssertEqual(restored.chats.first(where: { $0.id == second })?.savedDraft, "second draft")
    }
    func testChatSearchFindsSnippetWithoutRequiringTitleMatch() {
        var chat = Chat(); chat.title = "Сортировка"
        let message = ChatMessage(role: "user", text: String(repeating: "x", count: 200) + " рабочая папка /tmp/images " + String(repeating: "y", count: 500))
        chat.messages = [message]
        let hits = LocalChatSearch.search("рабочая папка", in: [chat])
        XCTAssertEqual(hits.first?.messageID, message.id)
        XCTAssertTrue(hits.first?.snippet.contains("/tmp/images") == true)
        XCTAssertLessThanOrEqual(hits.first?.snippet.count ?? 0, 380)
        XCTAssertTrue(LocalChatSearch.search("", in: [chat]).isEmpty)
    }
}
