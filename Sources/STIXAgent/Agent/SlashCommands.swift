import Foundation

struct SlashCommandItem: Identifiable, Equatable {
    let id: String
    let command: String
    let title: String
    let detail: String
    let icon: String
    var takesText = false
    var enabled = true
}

enum SlashCommands {
    static func items(plugins: [PluginConfig], canSteer: Bool, skills: [LocalSkill] = []) -> [SlashCommandItem] {
        var items: [SlashCommandItem] = [
            .init(id:"workflows",command:"/workflows",title:"Сценарии с формами",detail:"Повторяемые задачи и параметры",icon:"slider.horizontal.3"),
            .init(id:"automations",command:"/automations",title:"Автоматизации",detail:"Расписание и наблюдение за папками",icon:"clock.arrow.circlepath"),
            .init(id:"documents",command:"/documents",title:"Поиск документов",detail:"Локальные папки и источники",icon:"doc.text.magnifyingglass"),
            .init(id:"gallery",command:"/gallery",title:"Галерея результатов",detail:"Изображения, документы и код",icon:"square.grid.2x2"),
            .init(id:"resources",command:"/resources",title:"Ресурсы Mac",detail:"Память и режим экономии",icon:"gauge.with.dots.needle.33percent"),
            .init(id:"backups",command:"/backups",title:"Резервные копии и перенос",detail:"Данные приложения и защищённый перенос ключей",icon:"externaldrive"),
            .init(id: "doctor", command: "/doctor", title: "Проверить приложение", detail: "Сервисы, модели, права и место на диске", icon: "stethoscope"),
            .init(id: "image", command: "/image", title: "Создать или изменить картинку", detail: "Описание → локальный ComfyUI", icon: "photo", takesText: true),
            .init(id: "models", command: "/models", title: "Модели для задач", detail: "Назначить локальных специалистов", icon: "square.stack.3d.up"),
            .init(id: "compact", command: "/compact", title: "Сжать контекст", detail: "Сохранить рабочее резюме и освободить окно модели", icon: "arrow.down.right.and.arrow.up.left"),
            .init(id: "skills", command: "/skills", title: "Скиллы", detail: "Локальные инструкции и создание скиллов", icon: "sparkles"),
            .init(id: "memory", command: "/memory", title: "Память", detail: "Просмотреть, изменить или удалить записи", icon: "brain"),
            .init(id: "search", command: "/search", title: "Поиск по чатам", detail: "Найти сообщения в локальной истории", icon: "magnifyingglass", takesText: true),
            .init(id: "diagnostics", command: "/diagnostics", title: "Диагностика", detail: "Модели, память Mac, ComfyUI и очередь", icon: "stethoscope"),
            .init(id: "tasks", command: "/tasks", title: "Показать задачи", detail: "Развернуть панель и вернуть закрытые карточки", icon: "list.bullet.rectangle"),
            .init(id: "plugins", command: "/plugins", title: "Плагины", detail: "Подключённые MCP-плагины", icon: "puzzlepiece.extension"),
            .init(id: "connections", command: "/connections", title: "Подключения API", detail: "Сервисы и документация", icon: "network"),
            .init(id: "dark", command: "/theme dark", title: "Тёмная тема", detail: "Внешний вид приложения", icon: "moon"),
            .init(id: "light", command: "/theme light", title: "Светлая тема", detail: "Внешний вид приложения", icon: "sun.max"),
            .init(id: "system", command: "/theme system", title: "Системная тема", detail: "Как в macOS", icon: "circle.lefthalf.filled"),
            .init(id: "permissions", command: "/permissions", title: "Доступ к Mac", detail: "Системные разрешения", icon: "hand.raised"),
            .init(id: "help", command: "/help", title: "Справка", detail: "Как пользоваться агентом", icon: "questionmark.circle")
        ]
        if canSteer { items += [
            .init(id: "pause", command: "/pause", title: "Приостановить", detail: "Сохранить задачу для продолжения", icon: "pause"),
            .init(id: "skip", command: "/skip", title: "Пропустить следующий шаг", detail: "Следующий вызов инструмента не выполнится", icon: "forward.end")
        ] }
        if canSteer { items.insert(.init(id: "steer", command: "/steer", title: "Уточнить текущую задачу", detail: "Скорректировать следующие действия", icon: "text.bubble", takesText: true), at: 1) }
        items += plugins.map { plugin in
            let encoded = plugin.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? plugin.id
            return .init(id: "plugin:" + plugin.id, command: "/plugin/" + encoded, title: plugin.name,
                         detail: plugin.enabled ? "Плагин · опишите задачу" : "Плагин отключён", icon: "puzzlepiece.extension", takesText: true, enabled: plugin.enabled)
        }
        items += skills.map { .init(id: "skill:" + $0.name, command: "/skill/" + $0.name, title: $0.name, detail: $0.description, icon: "sparkles", takesText: true, enabled: $0.enabled) }
        return items
    }
    static func matches(draft: String, items: [SlashCommandItem]) -> [SlashCommandItem] {
        guard draft.hasPrefix("/"), !draft.contains("\n"), draft.count <= 200 else { return [] }
        let query = draft.lowercased()
        let term = String(query.dropFirst())
        return items.filter { item in
            item.command.lowercased().hasPrefix(query) ||
                (!term.isEmpty && !term.contains(" ") && (item.title.localizedStandardContains(term) || item.id.localizedStandardContains(term)))
        }
    }
    static func pluginPrompt(_ text: String, plugins: [PluginConfig]) throws -> String? {
        guard text.hasPrefix("/plugin/") else { return nil }
        let parts = text.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        let encodedID = String(parts[0].dropFirst(8))
        guard let id = encodedID.removingPercentEncoding, let plugin = plugins.first(where: { $0.id == id && $0.enabled }) else {
            throw AgentError.message("Плагин не найден или отключён. Откройте /plugins.")
        }
        guard parts.count == 2, !parts[1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentError.message("После команды плагина опишите задачу.")
        }
        return "Пользователь выбрал MCP-плагин \(plugin.name) (id=\(plugin.id)). Для этой задачи используй его подключённые инструменты; если они недоступны, сообщи об этом. Задача пользователя:\n\(parts[1])"
    }
}

