import XCTest
import CoreGraphics
import ImageIO
@testable import STIXAgent

/// Opt-in, serial end-to-end checks through the real selected main model.
/// All files and history are isolated from the user's app data.
final class LiveCapabilityTests: XCTestCase {
    @MainActor private func fixture() async throws -> (AppStore, URL) {
        guard ProcessInfo.processInfo.environment["STIX_AGENT_CAPABILITY_AUDIT"] == "1" else { throw XCTSkip("Opt-in local capability audit") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("STIX-capabilities-" + UUID().uuidString)
        let store = AppStore(storage: .init(paths: .init(root: root.appendingPathComponent("state"))))
        store.preferences.lmEndpoint = "http://127.0.0.1:1235"
        store.preferences.comfyEndpoint = "http://127.0.0.1:8188"
        store.preferences.questionLevel = 0; store.preferences.maxToolRounds = 12
        store.models = try await LMStudioClient(endpoint: store.preferences.lmEndpoint).models()
        store.newChat(folder: root); store.setModel("qwen3-8b-abliterated", image: false)
        return (store, root)
    }
    @MainActor private func run(_ store: AppStore, prompt: String, allowedShell: String? = nil, timeout: Double = 480) async throws {
        store.draft = prompt; store.send()
        let deadline = Date().addingTimeInterval(timeout)
        while store.busy && Date() < deadline {
            if let pending = store.pending {
                // Only the literal harmless fixture command is approved; all other requests fail closed.
                if pending.kind == .approval, let allowedShell,
                   let raw = store.currentChat?.messages.last(where: { $0.toolName == "run_shell" })?.detail,
                   (try? JSONValue.parse(raw)["command"].string) == allowedShell { store.respond(.once) }
                else { store.respond(.deny) }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if store.busy { store.stop(); throw AgentError.message("Capability audit timed out") }
        XCTAssertEqual(store.currentChat?.model, "qwen3-8b-abliterated")
        XCTAssertEqual(store.jobs.last?.status, "done", store.currentChat?.messages.last?.text ?? "No result")
    }
    @MainActor private func record(_ store: AppStore, name: String) throws {
        let proof = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/capability-\(name).json")
        try FileManager.default.createDirectory(at: proof.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = JSONValue.object([
            "main": .string(store.currentChat?.model ?? ""),
            "status": .string(store.jobs.last?.status ?? ""),
            "tools": .array((store.currentChat?.messages.filter { $0.role == "tool" }.map { .object(["name": .string($0.toolName ?? ""), "status": .string($0.status ?? ""), "result": .string(String($0.text.prefix(4000)))]) }) ?? [])
        ])
        try Data(data.encoded.utf8).write(to: proof, options: .atomic)
    }
    @MainActor func testMainDelegatesTextCodeAndAnalysisThenUsesTerminalAndQueue() async throws {
        let (store, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        // Reuse the loaded compact model for these text-only roles while testing the full delegation path.
        store.preferences.modelRoles = ["writing": "qwen3-8b-abliterated", "coding": "qwen3-8b-abliterated", "reasoning": "qwen3-8b-abliterated"]
        let command = "printf STIX_TERMINAL_OK"
        try await run(store, prompt: "Проверка локальных инструментов. Выполни последовательно: 1) delegate_model role=writing: придумать короткий заголовок заметки о чае; 2) delegate_model role=coding: написать Python функцию add(a,b); 3) delegate_model role=reasoning: найти ошибку в Python 'def f(xs): return xs[0]' для пустого списка; 4) run_shell command='printf STIX_TERMINAL_OK'; 5) list_tasks. Не создавай файлы, не выполняй других команд и не задавай вопросов. Кратко проверь результаты специалистов.", allowedShell: command)
        try record(store, name: "text-code-terminal-tasks")
        let messages = store.currentChat?.messages ?? []
        let calls = store.currentChat?.history.flatMap(\.toolCalls) ?? []
        for role in ["writing", "coding", "reasoning"] {
            XCTAssertTrue(calls.contains { $0.name == "delegate_model" && (try? JSONValue.parse($0.arguments)["role"].string) == role }, "Missing role \(role)")
        }
        XCTAssertEqual(messages.filter { $0.toolName == "delegate_model" && $0.status == "done" }.count, 3)
        XCTAssertTrue(messages.contains { $0.toolName == "run_shell" && $0.text.contains("STIX_TERMINAL_OK") && $0.status == "done" })
        XCTAssertTrue(messages.contains { $0.toolName == "list_tasks" && $0.status == "done" })
    }
    @MainActor func testMainSearchesDuckDuckGoAndReadsSource() async throws {
        let (store, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try await run(store, prompt: "Через web_search найди официальный сайт языка Swift, query='Swift programming language official website', limit=3. Затем через read_web_page прочитай https://www.swift.org/ и назови язык со ссылкой на источник. Не открывай браузер и не используй shell.")
        try record(store, name: "web")
        for name in ["web_search", "read_web_page"] {
            XCTAssertTrue(store.currentChat?.messages.contains { $0.toolName == name && $0.status == "done" } == true, "Missing successful \(name)")
        }
        XCTAssertTrue(store.currentChat?.messages.last?.text.contains("swift.org") == true)
    }
    @MainActor func testMainDelegatesActualImageToVision() async throws {
        let (store, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fillEllipse(in: CGRect(x: 72, y: 72, width: 112, height: 112))
        let image = root.appendingPathComponent(UUID().uuidString + ".png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(image as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        store.attachments = [.init(path: image.path, kind: "image")]
        try await run(store, prompt: "Через delegate_model role=vision передай прикреплённое изображение image_paths массивом путей, спроси цвет и форму фигуры в центре. Я не сообщаю цвет и форму: ответ должен опираться на реальные пиксели. Не используй OCR и shell. Ответь по-русски.")
        try record(store, name: "vision")
        let specialist = store.currentChat?.messages.first { $0.toolName == "delegate_model" && $0.status == "done" }
        XCTAssertNotNil(specialist)
        let answer = (specialist?.text ?? "").lowercased()
        XCTAssertTrue(answer.contains("красн") || answer.contains("red"), answer)
        XCTAssertTrue(answer.contains("круг") || answer.contains("circle"), answer)
    }
    @MainActor func testMainPausesItsOwnDurableTask() async throws {
        let (store, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        store.draft = "Проверь list_tasks, затем приостанови текущую задачу через manage_task job_id=current action=pause. После этого ожидай явного продолжения пользователя. Не запускай других инструментов."; store.send()
        let deadline = Date().addingTimeInterval(240)
        while store.busy && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        if store.busy { store.stop(); XCTFail("Pause timed out") }
        try record(store, name: "pause-task")
        XCTAssertEqual(store.jobs.last?.status, "paused")
        XCTAssertTrue(store.currentChat?.history.flatMap(\.toolCalls).contains { $0.name == "manage_task" } == true)
        XCTAssertEqual(AppStore(storage: store.storage).jobs.last?.status, "paused")
    }
    @MainActor func testMainEditsOwnExistingImageWithoutReplacingOriginal() async throws {
        let (store, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let source = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/smoke-image.png")
        guard FileManager.default.fileExists(atPath: source.path) else { throw XCTSkip("Own red-mug fixture missing") }
        let original = root.appendingPathComponent("original.png")
        try FileManager.default.copyItem(at: source, to: original)
        let chat = try XCTUnwrap(store.selectedID)
        store.chats[0].imageModel = "sd_xl_base_1.0.safetensors"
        store.addMessage(.init(role: "assistant", text: "Ранее созданная тестовая картинка", attachments: [.init(path: original.path, kind: "image")]), to: chat)
        try await run(store, prompt: "Отредактируй последнюю картинку через generate_image с input_image=last: a blue ceramic mug on a white table. Нужен ровно один новый вариант. Не меняй исходный файл и заверши ответ после результата инструмента.", timeout: 600)
        try record(store, name: "main-edit")
        XCTAssertTrue(store.currentChat?.messages.contains { $0.toolName == "generate_image" && $0.status == "done" } == true)
        XCTAssertEqual(store.currentChat?.messages.filter { $0.toolName == "image" && $0.status == "done" }.count, 1)
        let edited = try XCTUnwrap(store.lastImagePath(chatID: chat))
        XCTAssertNotEqual(edited, original.path)
        XCTAssertEqual(try Data(contentsOf: original), try Data(contentsOf: source))
        let proof = source.deletingLastPathComponent().appendingPathComponent("capability-main-edit.png")
        try Data(contentsOf: URL(fileURLWithPath: edited)).write(to: proof, options: .atomic)
    }
    @MainActor func testMainGeneratesThenEditsLastImage() async throws {
        let (store, root) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let (bytes, _) = try await URLSession.shared.data(from: URL(string: store.preferences.comfyEndpoint + "/queue")!)
        let queue = try JSONDecoder().decode(JSONValue.self, from: bytes)
        guard queue["queue_running"].array?.isEmpty == true, queue["queue_pending"].array?.isEmpty == true else { throw XCTSkip("User generation active") }
        store.chats[0].imageModel = "sd_xl_base_1.0.safetensors"
        try await run(store, prompt: "Сделай тестовую картинку: вызови generate_image prompt='a red ceramic mug on a white table', width=512, height=512, steps=2. Только одна картинка, затем заверши ответ.", timeout: 300)
        XCTAssertNotNil(store.lastImagePath(chatID: store.chats[0].id))
        let original = store.lastImagePath(chatID: store.chats[0].id)
        try await run(store, prompt: "Отредактируй только что сгенерированную картинку через generate_image input_image=last, prompt='a blue ceramic mug on a white table', width=512, height=512, steps=2, denoise=0.5. Сохрани исходную картинку.", timeout: 300)
        try record(store, name: "image-edit")
        let edited = try XCTUnwrap(store.lastImagePath(chatID: store.chats[0].id))
        XCTAssertNotEqual(original, edited)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(original)))
        let proof = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("dist/capability-image-edit.png")
        try Data(contentsOf: URL(fileURLWithPath: edited)).write(to: proof, options: .atomic)
        try await ComfyClient(endpoint: store.preferences.comfyEndpoint).releaseModelsIfIdle()
    }
}
