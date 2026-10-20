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

        // A resumed session can enqueue work in its first chat even when the
        // saved journal contains jobs from many other chats.
        var queued = after
        let activeChat = try XCTUnwrap(queued.chats.first)
        queued.jobs = (queued.jobs ?? []) + [AgentJob(chatID: activeChat.id, prompt: "storage-roundtrip-fixture")]
        try StateStorage(paths: paths).save(queued)
        let reloaded = try XCTUnwrap(StateStorage(paths: paths).load())
        XCTAssertEqual(reloaded.jobs?.count, (after.jobs?.count ?? 0) + 1)
        XCTAssertEqual(try attachmentHashes(in: scratch), hashes)

        var edited = reloaded
        var editRequest = ImageRequest(prompt: "Change the cup to blue")
        editRequest.inputImagePath = "/tmp/source.png"
        editRequest.width = 512; editRequest.height = 512; editRequest.denoise = 0.55
        editRequest.explicitOptions = ["input", "size", "denoise"]
        edited.features?.imageRecipes.append(.init(chatID: activeChat.id, attachmentPaths: ["/tmp/result.png"],
                                                   request: editRequest, model: "builtin-image:sd15-palettized-512", workflow: nil))
        try StateStorage(paths: paths).save(edited)
        let imageReloaded = try XCTUnwrap(StateStorage(paths: paths).load())
        XCTAssertEqual(imageReloaded.features?.imageRecipes.count, (reloaded.features?.imageRecipes.count ?? 0) + 1)
        var preferences = imageReloaded
        preferences.preferences.alwaysApprovals.formUnion(["write_file", "move_file", "list_files"])
        preferences.preferences.disabledSkills = ["unused-one", "unused-two"]
        try StateStorage(paths: paths).save(preferences)
        XCTAssertEqual(try StateStorage(paths: paths).load()?.preferences.alwaysApprovals,
                       preferences.preferences.alwaysApprovals)
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
