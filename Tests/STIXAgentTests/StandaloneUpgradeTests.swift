import CryptoKit
import XCTest
@testable import STIXAgent

final class StandaloneUpgradeTests: XCTestCase {
    func testExistingProfileRoundTripsWithoutLosingChatsOrAttachments() throws {
        guard let source = ProcessInfo.processInfo.environment["STIX_TEST_UPGRADE_SNAPSHOT"] else {
            throw XCTSkip("Set STIX_TEST_UPGRADE_SNAPSHOT to a stopped-app backup")
        }
        let original = URL(fileURLWithPath: source)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("stix-upgrade-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.copyItem(at: original, to: scratch)
        let paths = AppStoragePaths(root: scratch)
        let before = try XCTUnwrap(StateStorage(paths: paths).load())
        let hashes = try attachmentHashes(in: scratch)
        let chatCount = before.chats.count
        let messageCount = before.chats.reduce(0) { $0 + $1.messages.count }
        let historyCount = before.chats.reduce(0) { $0 + $1.history.count }
        try StateStorage(paths: paths).save(before)
        let after = try XCTUnwrap(StateStorage(paths: paths).load())
        XCTAssertEqual(after.chats.count, chatCount)
        XCTAssertEqual(after.chats.reduce(0) { $0 + $1.messages.count }, messageCount)
        XCTAssertEqual(after.chats.reduce(0) { $0 + $1.history.count }, historyCount)
        XCTAssertEqual(try attachmentHashes(in: scratch), hashes)
    }

    private func attachmentHashes(in root: URL) throws -> [String: String] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw AgentError.message("Не удалось прочитать резервную копию")
        }
        var hashes: [String: String] = [:]
        for case let url as URL in walker where url.pathComponents.contains("Attachments") {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let data = try Data(contentsOf: url)
            hashes[String(url.path.dropFirst(root.path.count + 1))] = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
        }
        return hashes
    }
}
