import XCTest
@testable import STIXAgent

final class ChatSearchIndexTests: XCTestCase {
    func testDerivedIndexRebuildsAndFindsUnicodeSubstring() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var chat = Chat(title: "Source")
        chat.messages = [.init(role: "user", text: "РАБОЧАЯ папка и naïve notes")]
        let index = ChatSearchIndex(paths: .init(root: root))
        XCTAssertEqual(try index.search("рабочая", in: [chat]).first?.messageID, chat.messages[0].id)
        try FileManager.default.removeItem(at: root.appendingPathComponent("search.sqlite"))
        XCTAssertEqual(try index.search("naive", in: [chat]).count, 1)
        chat.messages = []
        XCTAssertTrue(try index.search("рабочая", in: [chat]).isEmpty)
        try Data("broken cache".utf8).write(to: root.appendingPathComponent("search.sqlite"))
        XCTAssertTrue(try index.search("рабочая", in: [chat]).isEmpty)
    }
}
