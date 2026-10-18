import XCTest
@testable import STIXAgent

final class FileDiffTests: XCTestCase {
    private func fixture(_ body: (URL, AppStoragePaths, FileTools) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppStoragePaths(root: root.appendingPathComponent("internal"))
        try body(root, paths, FileTools(paths: paths))
    }

    func testSnapshotUsesBackupAndRejectsExternalChanges() throws {
        try fixture { root, _, tools in
            let file = root.appendingPathComponent("code.swift")
            try Data("let a = 1\n".utf8).write(to: file)
            let receipt = try tools.write(path: file.path, content: "let a = 2\n", workingDirectory: nil)
            let snapshot = try tools.diffSnapshot(receipt)
            XCTAssertEqual(snapshot.before, "let a = 1\n")
            XCTAssertEqual(snapshot.after, "let a = 2\n")
            try Data("external".utf8).write(to: file)
            XCTAssertThrowsError(try tools.diffSnapshot(receipt))
            XCTAssertEqual(try String(contentsOf: file), "external")
        }
    }

    func testNewFileSnapshotAndUndo() throws {
        try fixture { root, _, tools in
            let file = root.appendingPathComponent("new.txt")
            let receipt = try tools.write(path: file.path, content: "hello", workingDirectory: nil)
            let snapshot = try tools.diffSnapshot(receipt)
            XCTAssertNil(snapshot.before)
            XCTAssertEqual(snapshot.after, "hello")
            XCTAssertEqual(FileTextDiff(before: snapshot.before, after: snapshot.after).additions, 1)
            _ = try tools.undo(receipt)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testMoveSnapshotPreservesContentAndPaths() throws {
        try fixture { root, _, tools in
            let source = root.appendingPathComponent("a"), destination = root.appendingPathComponent("b")
            try Data("same".utf8).write(to: source)
            let receipt = try tools.move(source: source.path, destination: destination.path, workingDirectory: nil)
            let snapshot = try tools.diffSnapshot(receipt)
            XCTAssertEqual(snapshot.before, snapshot.after)
            XCTAssertEqual(snapshot.destination, receipt.destination)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        }
    }

    func testSeparatedChangesKeepLineNumbersAndCollapseContext() {
        let before = (1...40).map { "line \($0)" }
        var after = before
        after[2] = "first change"; after[36] = "last change"
        let diff = FileTextDiff(before: before.joined(separator: "\n"), after: after.joined(separator: "\n"))
        XCTAssertEqual(diff.additions, 2)
        XCTAssertEqual(diff.removals, 2)
        XCTAssertTrue(diff.lines.contains { $0.kind == .omitted })
        XCTAssertEqual(diff.lines.first { $0.text == "last change" }?.newNumber, 37)
        XCTAssertEqual(diff.lines.first { $0.kind == .removed }?.oldNumber, 3)
        XCTAssertFalse(diff.truncated)
    }

    func testEmptyFileAndTrailingNewlineAreVisibleChanges() {
        XCTAssertEqual(FileTextDiff(before: nil, after: "").additions, 1)
        XCTAssertEqual(FileTextDiff(before: "a", after: "a\n").additions, 1)
        XCTAssertEqual(FileTextDiff(before: "a\n", after: "a").removals, 1)
        let unchanged = FileTextDiff(before: "same", after: "same")
        XCTAssertEqual(unchanged.additions + unchanged.removals, 0)
    }

    func testLargeDiffHasBoundedRenderingAndRetainsOriginalText() {
        let before = (0..<2_000).map { "old \($0)" }.joined(separator: "\n")
        let after = (0..<2_000).map { "new \($0)" }.joined(separator: "\n")
        let diff = FileTextDiff(before: before, after: after, maximumRows: 80)
        XCTAssertEqual(diff.additions, 2_000)
        XCTAssertEqual(diff.removals, 2_000)
        XCTAssertEqual(diff.lines.count, 80)
        XCTAssertTrue(diff.truncated)
    }

    func testSpecificBatchUndoSurvivesReloadAndLeavesOtherFileApplied() throws {
        try fixture { root, paths, _ in
            let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
            try Data("old a".utf8).write(to: a)
            try Data("old b".utf8).write(to: b)
            let operations: JSONValue = .array([a, b].map { file in
                .object(["kind": .string("write"), "path": .string(file.path), "content": .string("new")])
            })
            let planner = FileChangePlanner(paths: paths)
            let preview = try planner.preview(operations: operations, workingDirectory: root.path)
            let result = try planner.apply(id: preview.id, workingDirectory: root.path)
            let receipt = try XCTUnwrap(result.results.first?.undo)
            // UI callers have only the undo record; journal ownership is automatic.
            _ = try planner.undo(receipt)
            XCTAssertEqual(try String(contentsOf: a), "old a")
            XCTAssertEqual(try String(contentsOf: b), "new")
            let reloaded = FileChangePlanner(paths: paths)
            XCTAssertEqual(try reloaded.undoReceipts(id: preview.id).count, 1)
            XCTAssertThrowsError(try reloaded.rollback(id: preview.id, receiptID: receipt.id))
            _ = try reloaded.rollback(id: preview.id)
            XCTAssertEqual(try String(contentsOf: b), "old b")
            XCTAssertTrue(try reloaded.undoReceipts(id: preview.id).isEmpty)
        }
    }

    func testSpecificBatchUndoConflictPreservesReceiptAndExternalEdit() throws {
        try fixture { root, paths, _ in
            let file = root.appendingPathComponent("a")
            try Data("old".utf8).write(to: file)
            let planner = FileChangePlanner(paths: paths)
            let preview = try planner.preview(operations: .array([.object(["kind": .string("write"), "path": .string(file.path), "content": .string("new")])]), workingDirectory: root.path)
            let result = try planner.apply(id: preview.id, workingDirectory: root.path)
            let receipt = try XCTUnwrap(result.results.first?.undo)
            try Data("external".utf8).write(to: file)
            XCTAssertThrowsError(try planner.rollback(id: preview.id, receiptID: receipt.id))
            XCTAssertEqual(try planner.undoReceipts(id: preview.id).count, 1)
            XCTAssertEqual(try String(contentsOf: file), "external")
        }
    }

    func testPlannerUndoFallsBackForStandaloneReceipt() throws {
        try fixture { root, paths, tools in
            let file = root.appendingPathComponent("standalone")
            let receipt = try tools.write(path: file.path, content: "created", workingDirectory: nil)
            _ = try FileChangePlanner(paths: paths).undo(receipt)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
    }

    func testPlannerUndoRejectsReceiptThatDisagreesWithJournal() throws {
        try fixture { root, paths, _ in
            let planner = FileChangePlanner(paths: paths)
            let preview = try planner.preview(operations: .array([.object(["kind": .string("write"), "path": .string("a"), "content": .string("new")])]), workingDirectory: root.path)
            let applied = try planner.apply(id: preview.id, workingDirectory: root.path)
            var receipt = try XCTUnwrap(applied.results.first?.undo)
            receipt.source = root.appendingPathComponent("unrelated").path
            XCTAssertThrowsError(try planner.undo(receipt))
            XCTAssertEqual(try planner.undoReceipts(id: preview.id).count, 1)
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a")), "new")
        }
    }
}
