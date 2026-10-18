import XCTest
@testable import STIXAgent

final class ChatActionsTests: XCTestCase {
    func testSearchIncludesTranscriptAndIgnoresCase() {
        var chat = Chat(title: "Проект")
        chat.messages = [.init(role: "assistant", text: "Смета для ювелирного магазина")]
        XCTAssertTrue(ChatTranscript.matches(chat, query: " ЮВЕЛИРНОГО "))
        XCTAssertTrue(ChatTranscript.matches(chat, query: "проект"))
        XCTAssertFalse(ChatTranscript.matches(chat, query: "другое"))
    }

    func testBranchPreservesOriginalAndCutsHistoryAtSelectedUserTurn() throws {
        let undo = UUID()
        let first = ChatMessage(role: "user", text: "Первая задача")
        let tool = ChatMessage(role: "tool", text: "Готово", undoID: undo)
        let local = ChatMessage(role: "user", text: "/help")
        let target = ChatMessage(role: "user", text: "Вторая задача", attachments: [.init(path: "/tmp/input.txt", kind: "file")])
        var chat = Chat(title: "Работа", folder: "/tmp/project", model: "local-model")
        chat.messages = [first, tool, local, target, .init(role: "assistant", text: "Старый ответ")]
        chat.history = [.init(role: "user", content: first.text), .init(role: "assistant", content: "Первый ответ"), .init(role: "user", content: "Вторая задача\n\nВложение (file): /tmp/input.txt"), .init(role: "assistant", content: "Старый ответ")]
        let branch = try XCTUnwrap(ChatTranscript.branch(chat, before: target.id))
        XCTAssertNotEqual(branch.id, chat.id)
        XCTAssertEqual(branch.folder, chat.folder)
        XCTAssertEqual(branch.model, chat.model)
        XCTAssertEqual(branch.messages.map(\.text), [first.text, tool.text, local.text])
        XCTAssertNil(branch.messages[1].undoID)
        XCTAssertEqual(branch.history, Array(chat.history.prefix(2)))
        XCTAssertEqual(chat.messages.count, 5)
        XCTAssertEqual(chat.messages[1].undoID, undo)
        XCTAssertNotEqual(branch.messages.first?.id, first.id)
    }

    func testBranchLocalCommandKeepsOnlyEarlierModelContext() throws {
        let first = ChatMessage(role: "user", text: "hello")
        let local = ChatMessage(role: "user", text: "/help")
        let later = ChatMessage(role: "user", text: "later")
        var chat = Chat()
        chat.messages = [first, local, later]
        chat.history = [.init(role: "user", content: "hello"), .init(role: "assistant", content: "hi"), .init(role: "user", content: "later")]
        XCTAssertEqual(try XCTUnwrap(ChatTranscript.branch(chat, before: local.id)).history.count, 2)
        XCTAssertNil(ChatTranscript.branch(chat, before: UUID()))
    }

    func testMarkdownExportIncludesRolesAndAttachmentPaths() {
        var chat = Chat(title: "Пример")
        chat.messages = [.init(role: "user", text: "Проверь", attachments: [.init(path: "/tmp/test.txt", kind: "file")])]
        let output = ChatTranscript.markdown(chat)
        XCTAssertTrue(output.hasPrefix("# Пример\n"))
        XCTAssertTrue(output.contains("## Вы"))
        XCTAssertTrue(output.contains("test.txt: /tmp/test.txt"))
    }
}
