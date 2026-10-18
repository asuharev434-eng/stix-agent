import XCTest
@testable import STIXAgent

final class FileChangePlanTests: XCTestCase {
    private func fixture(_ run: (URL, AppStoragePaths, FileChangePlanner) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppStoragePaths(root: root.appendingPathComponent("internal"))
        try run(root, paths, FileChangePlanner(paths: paths))
    }
    private func write(_ path: String, _ content: String) -> JSONValue {
        .object(["kind": .string("write"), "path": .string(path), "content": .string(content)])
    }
    private func move(_ source: String, _ destination: String) -> JSONValue {
        .object(["kind": .string("move"), "source": .string(source), "destination": .string(destination)])
    }
    func testPreviewEscapesCompleteTextAndDoesNotMutate() throws {
        try fixture { root, _, planner in
            let old = "same\n<script>alert('x')</script>\n" + String(repeating: "tail", count: 9_000)
            let new = "same\n<strong>new</strong>\n" + String(repeating: "tail", count: 9_000)
            let file = root.appendingPathComponent("a.txt")
            try Data(old.utf8).write(to: file)
            let preview = try planner.preview(operations: .array([write("a.txt", new)]), workingDirectory: root.path)
            XCTAssertEqual(try String(contentsOf: file), old)
            let html = try String(contentsOfFile: preview.attachment.path)
            XCTAssertTrue(html.contains("&lt;script&gt;"))
            XCTAssertTrue(html.contains("&lt;strong&gt;new&lt;/strong&gt;"))
            XCTAssertFalse(html.contains("<script>"))
            XCTAssertTrue(html.contains(String(repeating: "tail", count: 9_000)))
            XCTAssertTrue(html.contains("class=\"removed\""))
            XCTAssertTrue(html.contains("class=\"added\""))
        }
    }
    func testDurableApplyReturnsEveryUndoAndPreventsReplay() throws {
        try fixture { root, paths, planner in
            try Data("old".utf8).write(to: root.appendingPathComponent("a"))
            try Data("move me".utf8).write(to: root.appendingPathComponent("b"))
            let preview = try planner.preview(operations: .array([write("a", "new"), move("b", "c"), write("created", "hello")]), workingDirectory: root.path)
            let restored = FileChangePlanner(paths: paths)
            let result = try restored.apply(id: preview.id, workingDirectory: root.path)
            XCTAssertEqual(result.results.count, 3)
            XCTAssertEqual(result.results.compactMap(\.undo).count, 3)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a")), "new")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("c")), "move me")
            XCTAssertThrowsError(try restored.apply(id: preview.id, workingDirectory: root.path))
            for receipt in result.results.compactMap(\.undo).reversed() { _ = try FileTools(paths: paths).undo(receipt) }
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a")), "old")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b")), "move me")
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("created").path))
        }
    }
    func testTrashPlanUsesBackupReceipt() throws {
        try fixture { root, paths, planner in
            let file = root.appendingPathComponent("trash-test.txt")
            try Data("restore me".utf8).write(to: file)
            let preview = try planner.preview(operations: .array([.object(["kind": .string("trash"), "path": .string(file.path)])]), workingDirectory: root.path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
            let result = try planner.apply(id: preview.id, workingDirectory: root.path)
            let receipt = try XCTUnwrap(result.results.first?.undo)
            XCTAssertEqual(receipt.kind, "trash")
            XCTAssertNotNil(receipt.backup)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
            _ = try FileTools(paths: paths).undo(receipt)
            XCTAssertEqual(try String(contentsOf: file), "restore me")
        }
    }
    func testAllSourcesPreflightBeforeAnyMutation() throws {
        try fixture { root, _, planner in
            try Data("old".utf8).write(to: root.appendingPathComponent("a"))
            try Data("before".utf8).write(to: root.appendingPathComponent("b"))
            let preview = try planner.preview(operations: .array([write("a", "new"), move("b", "c")]), workingDirectory: root.path)
            try Data("external".utf8).write(to: root.appendingPathComponent("b"))
            XCTAssertThrowsError(try planner.apply(id: preview.id, workingDirectory: root.path))
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a")), "old")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b")), "external")
        }
    }
    func testDestinationConflictAndWorkingDirectoryChange() throws {
        try fixture { root, _, planner in
            try Data("source".utf8).write(to: root.appendingPathComponent("a"))
            let preview = try planner.preview(operations: .array([move("a", "b")]), workingDirectory: root.path)
            try Data("external".utf8).write(to: root.appendingPathComponent("b"))
            XCTAssertThrowsError(try planner.apply(id: preview.id, workingDirectory: root.path))
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a")), "source")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b")), "external")
            XCTAssertThrowsError(try planner.apply(id: preview.id, workingDirectory: root.deletingLastPathComponent().path))
            XCTAssertThrowsError(try planner.apply(id: "../../state", workingDirectory: root.path))
        }
    }
    func testOverlappingTargetsAndNonTextRejected() throws {
        try fixture { root, _, planner in
            XCTAssertThrowsError(try planner.preview(operations: .array([write("a", "1"), write("a", "2")]), workingDirectory: root.path))
            XCTAssertThrowsError(try planner.preview(operations: .array([write("folder/a", "1"), write("folder", "2")]), workingDirectory: root.path))
            try Data("a".utf8).write(to: root.appendingPathComponent("a"))
            XCTAssertThrowsError(try planner.preview(operations: .array([move("a", "a/child")]), workingDirectory: root.path))
            try Data([0xFF, 0xFE]).write(to: root.appendingPathComponent("binary"))
            XCTAssertThrowsError(try planner.preview(operations: .array([write("binary", "text")]), workingDirectory: root.path))
            XCTAssertThrowsError(try planner.preview(operations: .array([]), workingDirectory: root.path))
        }
    }
    func testSymlinkReplacementRejected() throws {
        try fixture { root, _, planner in
            let folder = root.appendingPathComponent("folder"), other = root.appendingPathComponent("other")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let preview = try planner.preview(operations: .array([write("folder/new", "new")]), workingDirectory: root.path)
            try FileManager.default.removeItem(at: folder)
            try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: other)
            XCTAssertThrowsError(try planner.apply(id: preview.id, workingDirectory: root.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("new").path))
        }
    }
    func testPartialFailureRollsBackAndKeepsDurableStatus() throws {
        try fixture { root, paths, planner in
            try Data("before".utf8).write(to: root.appendingPathComponent("a"))
            // Existing non-directory parent makes the second write fail at execution.
            // Its leaf is absent so digest preflight passes, exercising real rollback.
            try Data("parent".utf8).write(to: root.appendingPathComponent("not-folder"))
            let preview = try planner.preview(operations: .array([write("a", "after"), write("not-folder/child", "fail")]), workingDirectory: root.path)
            XCTAssertThrowsError(try planner.apply(id: preview.id, workingDirectory: root.path))
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a")), "before")
            let json = try JSONValue.parse(String(contentsOf: paths.backups.appendingPathComponent("plans/\(preview.id).json")))
            XCTAssertEqual(json["status"].string, "rolledBack")
            XCTAssertEqual(json["receipts"].array?.count, 0)
            XCTAssertThrowsError(try planner.apply(id: preview.id, workingDirectory: root.path))
        }
    }
    private func setPlanStatus(_ status: String, id: String, paths: AppStoragePaths) throws {
        let url = paths.backups.appendingPathComponent("plans/\(id).json")
        var journal = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        journal["status"] = status
        try JSONSerialization.data(withJSONObject: journal).write(to: url, options: .atomic)
    }
    func testInterruptedRecoveryAndCrashAfterUndo() throws {
        try fixture { root, paths, planner in
            try Data("old a".utf8).write(to: root.appendingPathComponent("a"))
            try Data("old b".utf8).write(to: root.appendingPathComponent("b"))
            let preview = try planner.preview(operations: .array([write("a", "new a"), write("b", "new b")]), workingDirectory: root.path)
            XCTAssertThrowsError(try planner.rollback(id: preview.id))
            let applied = try planner.apply(id: preview.id, workingDirectory: root.path)
            XCTAssertTrue(try planner.recoveries().isEmpty)
            // Simulate process interruption after mutation with durable receipts.
            try setPlanStatus("applying", id: preview.id, paths: paths)
            let restored = FileChangePlanner(paths: paths)
            let recoveries = try restored.recoveries()
            XCTAssertEqual(recoveries.count, 1)
            XCTAssertEqual(recoveries.first?.planID, preview.id)
            XCTAssertEqual(recoveries.first?.workingDirectory, try FileTools(paths: paths).resolve(root.path, workingDirectory: nil).path)
            XCTAssertEqual(recoveries.first?.receipts.count, 2)
            // A previous rollback reached the filesystem but not the journal.
            _ = try FileTools(paths: paths).undo(try XCTUnwrap(applied.results.last?.undo))
            let messages = try restored.rollback(id: preview.id)
            XCTAssertEqual(messages.count, 2)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a")), "old a")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b")), "old b")
            XCTAssertTrue(try restored.recoveries().isEmpty)
            XCTAssertThrowsError(try restored.rollback(id: preview.id))
            let journal = try JSONValue.parse(String(contentsOf: paths.backups.appendingPathComponent("plans/\(preview.id).json")))
            XCTAssertEqual(journal["status"].string, "rolledBack")
            XCTAssertEqual(journal["receipts"].array?.count, 0)
        }
    }
    func testRecoveryRollbackJournalsProgressAndPreservesExternalEdit() throws {
        try fixture { root, paths, planner in
            try Data("old a".utf8).write(to: root.appendingPathComponent("a"))
            try Data("old b".utf8).write(to: root.appendingPathComponent("b"))
            let preview = try planner.preview(operations: .array([write("a", "new a"), write("b", "new b")]), workingDirectory: root.path)
            _ = try planner.apply(id: preview.id, workingDirectory: root.path)
            try Data("external a".utf8).write(to: root.appendingPathComponent("a"))
            XCTAssertThrowsError(try planner.rollback(id: preview.id))
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a")), "external a")
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("b")), "old b")
            let remaining = try planner.recoveries()
            XCTAssertEqual(remaining.first?.status, "rollbackFailed")
            XCTAssertEqual(remaining.first?.receipts.count, 1)
            XCTAssertEqual(remaining.first?.receipts.first?.source, try FileTools(paths: paths).resolve("a", workingDirectory: root.path).path)
            try Data("new a".utf8).write(to: root.appendingPathComponent("a"))
            XCTAssertEqual(try planner.rollback(id: preview.id).count, 1)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a")), "old a")
            XCTAssertTrue(try planner.recoveries().isEmpty)
            XCTAssertThrowsError(try planner.rollback(id: "../../state"))
        }
    }

}
