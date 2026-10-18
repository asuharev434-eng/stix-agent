import XCTest
@testable import STIXAgent

final class LocalExpansionTests: XCTestCase {
    func testFolderWatchBaselinesExistingFilesThenEmitsOnlyNewQuietFilesOnce() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Watch"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let paths = AppStoragePaths(root: base.appendingPathComponent("Data")), now = Date()
        try Data("old".utf8).write(to: folder.appendingPathComponent("old.txt"))
        let rule = LocalAutomation(name: "Watch", chatID: UUID(), prompt: "Read", trigger: .folder, folder: folder.path)
        try AutomationScheduler.tick(paths: paths, rules: [rule], now: now.addingTimeInterval(10))
        XCTAssertTrue(try AutomationScheduler.pending(paths: paths).isEmpty)
        try Data("new".utf8).write(to: folder.appendingPathComponent("new.txt"))
        try AutomationScheduler.tick(paths: paths, rules: [rule], now: now.addingTimeInterval(20))
        let events = try AutomationScheduler.pending(paths: paths); XCTAssertEqual(events.count, 1)
        try AutomationScheduler.acknowledge(events[0], status: "queued", paths: paths)
        try AutomationScheduler.tick(paths: paths, rules: [rule], now: now.addingTimeInterval(30))
        XCTAssertTrue(try AutomationScheduler.pending(paths: paths).isEmpty)
    }
    func testDocumentIndexUpdatesChangedFilesAndRemovesDeletedResults() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("Docs"); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("note.txt"); try Data("Уникальный договор ALPHA4731".utf8).write(to: file)
        let index = LocalDocumentIndex(paths: .init(root: base.appendingPathComponent("Data")))
        _ = try await index.refresh(folders: [folder.path])
        let initial = try await index.search("ALPHA4731", folders: [folder.path]); XCTAssertEqual(initial.count, 1)
        try Data("Новый договор BETA".utf8).write(to: file)
        _ = try await index.refresh(folders: [folder.path])
        let changed = try await index.search("ALPHA4731", folders: [folder.path]); XCTAssertTrue(changed.isEmpty)
        try FileManager.default.removeItem(at: file); _ = try await index.refresh(folders: [folder.path])
        let removed = try await index.search("BETA", folders: [folder.path]); XCTAssertTrue(removed.isEmpty)
    }
    @MainActor func testVerifiedBackupPreservesTranscriptAndRejectsTamperedSnapshot() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = AppStore(storage: .init(paths: .init(root: base.appendingPathComponent("Data"))))
        store.addMessage(.init(role: "user", text: "Keep transcript"), to: try XCTUnwrap(store.selectedID))
        let backup = try store.storage.createBackup(in: base.appendingPathComponent("Copies"), automatic: false)
        XCTAssertNoThrow(try LocalBackups.verify(backup.url))
        let manifest = try LocalBackups.verify(backup.url)
        let path = try XCTUnwrap(manifest.files.keys.first(where: { $0.hasSuffix("messages.jsonl") }))
        try Data("tamper".utf8).write(to: backup.url.appendingPathComponent("Data").appendingPathComponent(path))
        XCTAssertThrowsError(try LocalBackups.verify(backup.url))
    }
}

final class IsolatedExecutionTests: XCTestCase {
    func testSandboxBlocksExternalReadAndNetworkButAllowsOutputs() async throws {
        let base=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:base)}
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        let secret=base.appendingPathComponent("outside.txt");try Data("outside-private".utf8).write(to:secret)
        let encoder=JSONEncoder();encoder.outputFormatting=[.withoutEscapingSlashes]
        let code="""
        import pathlib, socket
        try:
            pathlib.Path(\(String(data:try encoder.encode(secret.path),encoding:.utf8)!)).read_text()
            print('READ_ALLOWED_BAD')
        except PermissionError:
            print('READ_DENIED_OK')
        try:
            socket.create_connection(('127.0.0.1', 1235), timeout=1)
            print('NETWORK_ALLOWED_BAD')
        except PermissionError:
            print('NETWORK_DENIED_OK')
        pathlib.Path('Outputs/result.txt').write_text('safe result')
        """
        let result=try await IsolatedRunner(paths:.init(root:base.appendingPathComponent("Data"))).run(language:"python",code:code,inputs:[],timeout:15)
        XCTAssertEqual(result.exitCode,0,result.output)
        XCTAssertTrue(result.output.contains("READ_DENIED_OK"),result.output)
        XCTAssertTrue(result.output.contains("NETWORK_DENIED_OK"),result.output)
        let output = try XCTUnwrap(result.outputs.first, result.output)
        XCTAssertEqual(try String(contentsOf:output,encoding:.utf8),"safe result")
        XCTAssertEqual(try String(contentsOf:secret,encoding:.utf8),"outside-private")
    }
}
