import Foundation
import XCTest
@testable import STIXAgent

/// Opt-in end-to-end audit through an imported GGUF and the native image engine.
/// It never reads the user's app profile or contacts LM Studio/ComfyUI.
final class OfflineParityTests: XCTestCase {
    @MainActor private func fixture() async throws -> (AppStore, LocalModelLibrary, URL, String) {
        let environment = ProcessInfo.processInfo.environment
        guard let source = environment["STIX_TEST_OFFLINE_MODEL"],
              let bridge = environment["STIX_TEST_LLAMA_BRIDGE"] else {
            throw XCTSkip("Set STIX_TEST_OFFLINE_MODEL and STIX_TEST_LLAMA_BRIDGE")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("STIX-offline-parity-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = AppStore(storage: StateStorage(paths: .init(root: root.appendingPathComponent("Data"))))
        let library = LocalModelLibrary(bundled: nil, directory: root.appendingPathComponent("Models"),
                                        libraryURL: URL(fileURLWithPath: bridge))
        store.builtInTextEngine = library
        let record = try await library.importFile(URL(fileURLWithPath: source))
        let model = "builtin-text:" + record.id
        store.models = try await library.models()
        store.preferences.defaultModel = model
        store.preferences.questionLevel = 0
        store.preferences.maxToolRounds = 8
        if let resources = environment["STIX_TEST_COREML_RESOURCES"] {
            let image = CoreMLImageEngine(resources: URL(fileURLWithPath: resources))
            store.builtInImageEngine = image
            store.checkpoints = try await image.models().map(\.id)
            store.preferences.defaultImageModel = store.checkpoints.first
        }
        store.newChat(folder: root)
        return (store, library, root, model)
    }

    @MainActor private func run(_ store: AppStore, _ prompt: String, timeout: TimeInterval = 240,
                                allowedShell: String? = nil) async throws -> AgentJob {
        store.draft = prompt
        store.send()
        let deadline = Date().addingTimeInterval(timeout)
        while store.busy && Date() < deadline {
            if store.pending?.kind == .approval {
                if let allowedShell,
                   let raw = store.currentChat?.messages.last(where: { $0.toolName == "run_shell" })?.detail,
                   (try? JSONValue.parse(raw)["command"].string) == allowedShell {
                    store.respond(.once)
                } else { store.respond(.deny) }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        if store.busy { store.stop(); throw AgentError.message("Offline audit timed out: " + prompt) }
        return try XCTUnwrap(store.jobs.last)
    }

    @MainActor func testImportedGGUFLocalToolMatrix() async throws {
        guard ProcessInfo.processInfo.environment["STIX_TEST_TOOL_MATRIX"] == "1" else {
            throw XCTSkip("Set STIX_TEST_TOOL_MATRIX=1 for the live tool matrix")
        }
        let (store, library, root, model) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try "OFFLINE_SEARCH_MARKER".write(to: root.appendingPathComponent("seed.txt"), atomically: true, encoding: .utf8)
        store.preferences.modelRoles = ["coding": model]
        let command = "printf OFFLINE_SHELL_OK"
        let cases: [(String, String, String?)] = [
            ("list_files", "Используй list_files с path='.' и назови найденный seed.txt. Не используй другие инструменты.", nil),
            ("search_files", "Используй search_files с path='.' и query='OFFLINE_SEARCH_MARKER'. Назови найденный файл.", nil),
            ("move_file", "Используй move_file: перемести seed.txt в moved.txt в рабочей папке. Не используй терминал.", nil),
            ("run_shell", "Выполни ровно run_shell command='printf OFFLINE_SHELL_OK'. Сообщи вывод. Не используй другие команды.", command),
            ("list_tasks", "Используй list_tasks и кратко сообщи число задач. Не делай других действий.", nil),
            ("delegate_model", "Используй delegate_model role=coding task='Напиши Python функцию add(a,b)' reason='Проверка локального специалиста'. Ответь по результату.", nil),
            ("manage_memory", "Запомни через manage_memory action=remember scope=chat category=notes text='Тестовое предпочтение OFFLINE_MEMORY_MARKER'. Это мои тестовые данные; не задавай вопросов.", nil),
            ("list_model_capabilities", "Используй list_model_capabilities и кратко сообщи доступные локальные модели.", nil),
            ("show_file", "Используй show_file path='moved.txt', чтобы показать файл в этом чате.", nil),
            ("read_document", "Используй read_document path='moved.txt', чтобы прочитать текстовый файл.", nil),
            ("set_preference", "Используй set_preference key='theme' value='dark' для этого тестового профиля.", nil),
            ("present_artifact", "Используй present_artifact kind='markdown' title='offline-audit' content='# Offline audit' для показа документа в чате.", nil)
        ]
        var results: [JSONValue] = []
        let filter = ProcessInfo.processInfo.environment["STIX_TEST_TOOL_CASES"]
            .map { Set($0.split(separator: ",").map(String.init)) }
        for (expected, prompt, allowedShell) in cases where filter?.contains(expected) != false {
            store.newChat(folder: root)
            let job = try await run(store, prompt, timeout: 180, allowedShell: allowedShell)
            let calls = store.currentChat?.history.flatMap(\.toolCalls).map(\.name) ?? []
            results.append(.object([
                "expected": .string(expected), "status": .string(job.status),
                "called": .bool(calls.contains(expected)),
                "calls": .array(calls.map(JSONValue.string)),
                "answer": .string(String((store.currentChat?.messages.last?.text ?? "").prefix(1000)))
            ]))
        }
        let report = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/reports/offline-tools-" + URL(fileURLWithPath: ProcessInfo.processInfo.environment["STIX_TEST_OFFLINE_MODEL"] ?? "model").deletingPathExtension().lastPathComponent + ".json")
        try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(JSONValue.array(results).encoded.utf8).write(to: report, options: .atomic)
        await library.releaseAll()
        XCTAssertTrue(results.allSatisfy { $0["status"].string == "done" && $0["called"].bool == true }, "See " + report.path)
        if filter?.contains("move_file") != false {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("moved.txt").path))
        }
    }

    @MainActor func testImportedGGUFAgentAndImageCycle() async throws {
        let (store, library, root, model) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("agent-audit.txt")
        let fileJob = try await run(store, "Создай файл agent-audit.txt в рабочей папке с точным текстом OFFLINE_AGENT_OK через write_file. Затем прочитай его через read_file и сообщи содержимое. Не используй терминал и не задавай вопросов.")
        let fileText = (try? String(contentsOf: target, encoding: .utf8)) ?? ""
        let fileTools = store.currentChat?.history.flatMap(\.toolCalls).map(\.name) ?? []
        let fileArguments = store.currentChat?.history.flatMap(\.toolCalls).map(\.arguments) ?? []
        var result: [String: JSONValue] = [
            "model": .string(model),
            "file_status": .string(fileJob.status),
            "file_contents": .string(fileText),
            "tool_calls": .array(fileTools.map(JSONValue.string)),
            "tool_arguments": .array(fileArguments.map(JSONValue.string)),
            "history_saved": .bool(store.canPersist),
            "last_answer": .string(String((store.currentChat?.messages.last?.text ?? "").prefix(4000))),
            "offered_tools": .array(store.toolsForRequest(chatID: try XCTUnwrap(store.selectedID), system: store.systemPrompt(chatID: try XCTUnwrap(store.selectedID)), currentRequest: "Создай файл agent-audit.txt в рабочей папке с точным текстом OFFLINE_AGENT_OK через write_file. Затем прочитай его через read_file и сообщи содержимое.").map { .string($0.name) })
        ]
        if !store.checkpoints.isEmpty {
            if let chatID = store.selectedID, let chatIndex = store.index(chatID) {
                store.chats[chatIndex].imagePromptModel = "unavailable-local-image-prompt"
                store.preferences.lmEndpoint = "http://127.0.0.1:19099"
            }
            let imageJob = try await run(store, "/image --size 512x512 --steps 4 --seed 14561 a red ceramic mug on a wooden table", timeout: 360)
            let first = store.lastImagePath(chatID: try XCTUnwrap(store.selectedID))
            result["image_status"] = .string(imageJob.status)
            result["image_created"] = .bool(first.map(FileManager.default.fileExists(atPath:)) ?? false)
            result["image_prompt_fallback"] = .bool(store.currentChat?.messages.last(where: { $0.toolName == "image" })?.detail?.contains(model) == true)
            if let first {
                let editJob = try await run(store, "/image --input last --size 512x512 --steps 8 --denoise 0.85 a blue ceramic mug on a wooden table", timeout: 360)
                let edited = store.lastImagePath(chatID: try XCTUnwrap(store.selectedID))
                result["edit_status"] = .string(editJob.status)
                result["edit_created"] = .bool(edited != nil && edited != first)
                result["original_preserved"] = .bool(FileManager.default.fileExists(atPath: first))
                if let directory = ProcessInfo.processInfo.environment["STIX_TEST_IMAGE_OUTPUT"], let edited {
                    let output = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: first), to: output.appendingPathComponent("generated.png"))
                    try FileManager.default.copyItem(at: URL(fileURLWithPath: edited), to: output.appendingPathComponent("edited.png"))
                }
            }
        }
        let report = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("dist/reports/offline-parity-" + URL(fileURLWithPath: ProcessInfo.processInfo.environment["STIX_TEST_OFFLINE_MODEL"] ?? "model").deletingPathExtension().lastPathComponent + ".json")
        try FileManager.default.createDirectory(at: report.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(JSONValue.object(result).encoded.utf8).write(to: report, options: .atomic)
        await library.releaseAll()
        XCTAssertEqual(fileJob.status, "done")
        XCTAssertEqual(fileText, "OFFLINE_AGENT_OK")
        XCTAssertTrue(fileTools.contains("write_file"))
        XCTAssertTrue(fileTools.contains("read_file"))
        XCTAssertTrue(store.canPersist)
        if !store.checkpoints.isEmpty {
            XCTAssertEqual(result["image_status"], .string("done"))
            XCTAssertEqual(result["edit_status"], .string("done"))
            XCTAssertEqual(result["image_created"], .bool(true))
            XCTAssertEqual(result["image_prompt_fallback"], .bool(true))
            XCTAssertEqual(result["edit_created"], .bool(true))
            XCTAssertEqual(result["original_preserved"], .bool(true))
        }
    }
}
