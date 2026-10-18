import XCTest
@testable import STIXAgent

final class FileToolsTests: XCTestCase {
    func testWriteUndoAndConflict() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = FileTools(paths: AppStoragePaths(root: root.appendingPathComponent("internal")))
        let file = root.appendingPathComponent("text.txt")
        try Data("before".utf8).write(to: file)
        let record = try tools.write(path: file.path, content: "after", workingDirectory: nil)
        _ = try tools.undo(record)
        XCTAssertEqual(try String(contentsOf: file), "before")
        let second = try tools.write(path: file.path, content: "after", workingDirectory: nil)
        try Data("external".utf8).write(to: file)
        XCTAssertThrowsError(try tools.undo(second))
        XCTAssertEqual(try String(contentsOf: file), "external")
    }
    func testMoveTrashAndProtectedSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppStoragePaths(root: root.appendingPathComponent("internal")); try paths.prepare()
        let tools = FileTools(paths: paths)
        let source = root.appendingPathComponent("a"), target = root.appendingPathComponent("b")
        try Data("original".utf8).write(to: source)
        let move = try tools.move(source: source.path, destination: target.path, workingDirectory: nil)
        _ = try tools.undo(move)
        let trash = try tools.trash(path: source.path, workingDirectory: nil)
        _ = try tools.undo(trash)
        XCTAssertEqual(try String(contentsOf: source), "original")
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: paths.root)
        XCTAssertThrowsError(try tools.resolve(target.appendingPathComponent("state.json").path, workingDirectory: nil))
    }
    func testDirectoryMoveTrashAndConflict() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("folder")
        let target = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: source.appendingPathComponent("nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("content".utf8).write(to: source.appendingPathComponent("nested/file"))
        let tools = FileTools(paths: AppStoragePaths(root: root.appendingPathComponent("internal")))
        let moved = try tools.move(source: source.path, destination: target.path, workingDirectory: nil)
        _ = try tools.undo(moved)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("nested/file")), "content")
        let trashed = try tools.trash(path: source.path, workingDirectory: nil)
        _ = try tools.undo(trashed)
        XCTAssertEqual(try String(contentsOf: source.appendingPathComponent("nested/file")), "content")
        let conflict = try tools.move(source: source.path, destination: target.path, workingDirectory: nil)
        try Data("external".utf8).write(to: target.appendingPathComponent("nested/file"))
        XCTAssertThrowsError(try tools.undo(conflict))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("nested/file")), "external")
    }
    func testAllowedInternalArtifactsAndNestedWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = AppStoragePaths(root: root.appendingPathComponent("internal"))
        try paths.prepare()
        let tools = FileTools(paths: paths)
        let document = paths.documentation.appendingPathComponent("api/nested.txt")
        _ = try tools.write(path: document.path, content: "API documentation", workingDirectory: nil)
        XCTAssertEqual(try tools.read(path: document.path, workingDirectory: nil), "API documentation")
        XCTAssertTrue(try tools.search(path: paths.documentation.path, query: "API", workingDirectory: nil).contains("API documentation"))
        _ = try tools.write(path: paths.attachments.appendingPathComponent("image.txt").path, content: "artifact", workingDirectory: nil)
        XCTAssertThrowsError(try tools.resolve(paths.state.path, workingDirectory: nil))
        XCTAssertThrowsError(try tools.resolve(paths.backups.path, workingDirectory: nil))
        let link = paths.documentation.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: paths.backups)
        XCTAssertThrowsError(try tools.resolve(link.appendingPathComponent("private").path, workingDirectory: nil))
    }
}
