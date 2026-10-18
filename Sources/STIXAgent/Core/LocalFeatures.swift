import Foundation

enum ResourceMode: String, Codable, CaseIterable { case automatic, economy, performance
    var title: String { self == .automatic ? "Автоматически" : self == .economy ? "Экономия" : "Производительность" }
}
struct FeatureConfiguration: Codable {
    var version = 1
    var resourceMode: ResourceMode = .automatic
    var automaticBackups = true
    var quickCaptureEnabled = true
    var workflows: [LocalWorkflow] = [.photoPreparation]
    var automations: [LocalAutomation] = []
    var documentFolders: [String] = []
    var imageRecipes: [ImageRecipe] = []
    func validated() throws {
        guard version == 1, workflows.count <= 100, automations.count <= 100, documentFolders.count <= 100,
              Set(workflows.map(\.id)).count == workflows.count, Set(automations.map(\.id)).count == automations.count else { throw AgentError.message("Некорректная конфигурация локальных функций") }
        for workflow in workflows { try workflow.validated() }
        for rule in automations { try rule.validated() }
        for folder in documentFolders { guard folder.hasPrefix("/"), !folder.contains("\0") else { throw AgentError.message("Нужен абсолютный путь папки документов") } }
    }
}
struct WorkflowField: Codable, Identifiable {
    enum Kind: String, Codable { case text, file, folder, number, choice, toggle }
    var id: String { key }
    var key: String
    var label: String
    var kind: Kind
    var required = false
    var minimum: Double? = nil
    var maximum: Double? = nil
    var choices: [String]? = nil
    var defaultValue: JSONValue? = nil
}
struct WorkflowStep: Codable {
    var tool: String
    var arguments: JSONValue
}
struct LocalWorkflow: Codable, Identifiable {
    var id = UUID()
    var name: String
    var prompt: String
    var fields: [WorkflowField] = []
    var skill: String? = nil
    var steps: [WorkflowStep]? = nil
    func validated() throws {
        guard !name.isEmpty, name.count <= 100, prompt.count <= 16000, fields.count <= 20, Set(fields.map(\.key)).count == fields.count, (steps?.count ?? 0) <= 20 else { throw AgentError.message("Недопустимый сценарий") }
        for field in fields {
            guard field.key.range(of: "^[a-z][a-z0-9_]{0,39}$", options: .regularExpression) != nil, !field.label.isEmpty, field.label.count <= 100,
                  field.minimum?.isFinite != false, field.maximum?.isFinite != false,
                  (field.minimum ?? -Double.greatestFiniteMagnitude) <= (field.maximum ?? Double.greatestFiniteMagnitude),
                  field.kind != .choice || (field.choices?.isEmpty == false && (field.choices?.count ?? 0) <= 30) else { throw AgentError.message("Недопустимое поле формы") }
        }
        if let skill, !SkillLibrary.validName(skill) { throw AgentError.message("Некорректное имя скилла") }
        let allowed = Set(["list_files", "read_file", "read_document", "preview_changes", "verify_result", "prepare_images"])
        for step in steps ?? [] { guard allowed.contains(step.tool), step.arguments.object != nil else { throw AgentError.message("Для фиксированных шагов доступны чтение, проверка, предпросмотр и prepare_images. Произвольные команды выполняйте через изолированный запуск или обычного агента") } }
    }
    func input(_ values: [String:JSONValue]) throws -> [String:JSONValue] {
        try validated()
        guard Set(values.keys).isSubset(of: Set(fields.map(\.key))) else { throw AgentError.message("Неизвестные поля формы") }
        var result: [String:JSONValue] = [:]
        for field in fields {
            guard let value = values[field.key] ?? field.defaultValue, value != .null, value.string != "" else {
                if field.required { throw AgentError.message("Заполните: " + field.label) }; continue
            }
            switch field.kind {
            case .number:
                guard case .number(let number) = value, number.isFinite, number >= (field.minimum ?? -Double.greatestFiniteMagnitude), number <= (field.maximum ?? Double.greatestFiniteMagnitude) else { throw AgentError.message("Недопустимое число: " + field.label) }
            case .toggle: guard value.bool != nil else { throw AgentError.message("Ожидается переключатель: " + field.label) }
            default:
                guard let text = value.string, text.count <= 8000, !text.contains("\0") else { throw AgentError.message("Недопустимое значение: " + field.label) }
                if field.kind == .choice { guard field.choices?.contains(text) == true else { throw AgentError.message("Выберите вариант: " + field.label) } }
                if field.kind == .file || field.kind == .folder {
                    var isDirectory: ObjCBool = false
                    guard text.hasPrefix("/"), FileManager.default.fileExists(atPath: text, isDirectory: &isDirectory), isDirectory.boolValue == (field.kind == .folder) else { throw AgentError.message("Путь недоступен: " + field.label) }
                }
            }
            result[field.key] = value
        }
        return result
    }
    static let photoPreparation = LocalWorkflow(id: UUID(uuidString: "AEEB6F65-ACDB-4090-A2CD-54F7BB393CE9")!, name: "Подготовить фотографии", prompt: "Подготовить копии фотографий; исходники сохранить", fields: [
        .init(key: "source", label: "Папка фотографий", kind: .folder, required: true),
        .init(key: "destination", label: "Папка результата", kind: .folder, required: true),
        .init(key: "width", label: "Максимальная сторона, px", kind: .number, required: true, minimum: 64, maximum: 8192, defaultValue: .number(1600)),
        .init(key: "format", label: "Формат", kind: .choice, required: true, choices: ["jpeg", "png"], defaultValue: .string("jpeg")),
        .init(key: "quality", label: "Качество JPEG, 0–1", kind: .number, required: true, minimum: 0.1, maximum: 1, defaultValue: .number(0.85))
    ], steps: [.init(tool: "prepare_images", arguments: .object(["source": .string("{{source}}"), "destination": .string("{{destination}}"), "width": .string("{{width}}"), "format": .string("{{format}}"), "quality": .string("{{quality}}")]))])
}
struct LocalAutomation: Codable, Identifiable {
    enum Trigger: String, Codable { case daily, folder }
    var id = UUID()
    var name: String
    var chatID: UUID
    var prompt: String
    var trigger: Trigger
    var hour: Int = 9
    var minute: Int = 0
    var timeZone: String = TimeZone.current.identifier
    var folder: String? = nil
    var fileExtension: String? = nil
    var enabled = true
    var createdAt = Date()
    func validated() throws {
        guard !name.isEmpty, name.count <= 100, !prompt.isEmpty, prompt.count <= 16000, (0...23).contains(hour), (0...59).contains(minute), TimeZone(identifier: timeZone) != nil else { throw AgentError.message("Недопустимая автоматизация") }
        if trigger == .folder { guard let folder, folder.hasPrefix("/"), !folder.contains("\0") else { throw AgentError.message("Выберите папку наблюдения") } }
        if let fileExtension { guard fileExtension.range(of: "^[A-Za-z0-9]{1,12}$", options: .regularExpression) != nil else { throw AgentError.message("Расширение без точки") } }
    }
}
struct ImageRecipe: Codable, Identifiable {
    var id = UUID()
    var chatID: UUID
    var attachmentPaths: [String]
    var request: ImageRequest
    var model: String
    var workflow: JSONValue?
    var createdAt = Date()
}
