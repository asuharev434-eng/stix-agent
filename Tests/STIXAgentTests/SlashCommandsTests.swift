import XCTest
@testable import STIXAgent

final class SlashCommandsTests: XCTestCase {
    private let plugin = PluginConfig(id: "local notes/1", name: "Заметки", transport: "stdio", command: "unused", arguments: [], url: "", enabled: true)
    func testSlashFiltersCommandsAndPluginsAndStopsAfterPromptStarts() throws {
        let items = SlashCommands.items(plugins: [plugin], canSteer: true)
        XCTAssertTrue(SlashCommands.matches(draft: "/", items: items).contains { $0.id == "models" })
        XCTAssertEqual(SlashCommands.matches(draft: "/im", items: items).map(\.id), ["image", "image2image"])
        XCTAssertEqual(SlashCommands.matches(draft: "/зам", items: items).last?.title, "Заметки")
        XCTAssertTrue(SlashCommands.matches(draft: "/image red mug", items: items).isEmpty)
        XCTAssertTrue(SlashCommands.matches(draft: "ordinary text", items: items).isEmpty)
        XCTAssertEqual(SlashCommands.matches(draft: "/theme ", items: items).count, 3)
        XCTAssertFalse(SlashCommands.items(plugins: [], canSteer: false).contains { $0.id == "steer" })
    }
    func testPluginCommandRoundTripsIDAndRequiresEnabledPluginAndTask() throws {
        let item = try XCTUnwrap(SlashCommands.items(plugins: [plugin], canSteer: false).first { $0.id.hasPrefix("plugin:") })
        let expanded = try XCTUnwrap(SlashCommands.pluginPrompt(item.command + " Найди заметку", plugins: [plugin]))
        XCTAssertTrue(expanded.contains("id=local notes/1")); XCTAssertTrue(expanded.contains("Найди заметку"))
        XCTAssertThrowsError(try SlashCommands.pluginPrompt(item.command, plugins: [plugin]))
        var disabled = plugin; disabled.enabled = false
        XCTAssertThrowsError(try SlashCommands.pluginPrompt(item.command + " task", plugins: [disabled]))
        XCTAssertNil(try SlashCommands.pluginPrompt("/models", plugins: [plugin]))
    }
    @MainActor func testTasksCommandReopensPanelAndClosedCardsWithoutStartingModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root))), chat = try XCTUnwrap(store.selectedID)
        store.jobs = [.init(chatID: chat, prompt: "done", status: "done"), .init(chatID: chat, prompt: "active", status: "running")]
        let done = store.jobs[0].id, active = store.jobs[1].id
        store.dismissTask(done); store.dismissTask(active)
        XCTAssertEqual(store.jobs[0].hidden, true); XCTAssertNil(store.jobs[1].hidden)
        XCTAssertEqual(store.jobs.count, 2)
        store.toggleTaskPanel(chatID: chat)
        XCTAssertEqual(AppStore(storage: store.storage).currentChat?.tasksCollapsed, true)
        store.draft = "/tasks"; store.send()
        XCTAssertEqual(store.currentChat?.tasksCollapsed, false)
        XCTAssertTrue(store.jobs.allSatisfy { $0.hidden == false })
        XCTAssertFalse(store.busy); XCTAssertNil(store.task)
    }
}
