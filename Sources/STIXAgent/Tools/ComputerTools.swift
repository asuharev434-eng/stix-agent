import AppKit
import ApplicationServices
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

/// Validation is pure and deliberately independent of macOS privacy permissions.
enum ComputerToolValidation {
    static let browserActions = ["tabs", "read", "open", "click", "fill"]
    static func browserAction(_ args: JSONValue) throws {
        guard browserActions.contains(try args.requiredString("action")) else { throw AgentError.message("browser action: tabs/read/open/click/fill. Изменение настроек браузера этим инструментом не поддерживается.") }
    }
    static func javascriptUnavailable(_ message: String) -> Bool {
        let text = (message.components(separatedBy: ". Разрешите Automation;").first ?? message).lowercased()
        return text.contains("javascript") && ["disabled", "отключен", "отключён", "not allowed", "not enabled", "allow javascript", "разрешить javascript"].contains(where: text.contains)
    }
    static func validate(_ args: JSONValue, allowed: Set<String>) throws {
        guard let object = args.object, Set(object.keys).isSubset(of: allowed) else { throw AgentError.message("Неизвестные аргументы computer/browser") }
    }
    static func boundedInt(_ value: JSONValue, fallback: Int, range: ClosedRange<Int>) throws -> Int {
        if value == .null { return fallback }
        guard let n = value.int, range.contains(n) else { throw AgentError.message("Число вне допустимого диапазона \(range)") }
        return n
    }
    static func webURL(_ value: String) throws -> String {
        guard !value.contains(where: { $0.isWhitespace || $0.isNewline }), let u = URLComponents(string: value),
              ["http", "https"].contains(u.scheme?.lowercased() ?? ""), let host = u.host, !host.isEmpty,
              u.user == nil, u.password == nil else { throw AgentError.message("Допустим только HTTP(S) URL без логина и пароля") }
        return value
    }
    static func isSecret(_ value: String) -> Bool {
        let compact = value.lowercased().filter { $0.isLetter || $0.isNumber }
        return ["password", "passwd", "secret", "apikey", "token", "onetimecode", "verificationcode", "creditcard", "ccnumber", "cccsv", "cccsc"].contains { compact.contains($0) }
    }
    static func bundleID(_ value: String) throws -> String {
        guard value.utf8.count <= 255, !value.contains(where: { $0.isWhitespace }), value.range(of: #"^[A-Za-z0-9][A-Za-z0-9-]*(\.[A-Za-z0-9][A-Za-z0-9-]*)+$"#, options: .regularExpression) != nil else { throw AgentError.message("Нужен bundle_id установленного приложения") }
        return value
    }
    static func key(_ name: String, modifiers: String) throws -> (CGKeyCode, CGEventFlags) {
        let keys: [String: CGKeyCode] = ["return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "a": 0, "c": 8, "v": 9, "x": 7, "z": 6, "s": 1, "f": 3, "w": 13, "t": 17, "l": 37, "n": 45]
        let names = modifiers.isEmpty ? [] : modifiers.split(separator: ",", omittingEmptySubsequences: false).map { String($0).trimmingCharacters(in: .whitespaces).lowercased() }
        let flags: [String: CGEventFlags] = ["command": .maskCommand, "shift": .maskShift, "option": .maskAlternate, "control": .maskControl]
        guard let code = keys[name], Set(names).count == names.count, names.allSatisfy({ flags[$0] != nil }), name.count != 1 || names.contains("command") || names.contains("control") else { throw AgentError.message("Недопустимая клавиша/модификаторы; буквенные клавиши только с command/control") }
        return (code, names.reduce(CGEventFlags()) { $0.union(flags[$1]!) })
    }
    static func appleString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

/// One retained instance owns the most recent AX and DOM snapshots. No coordinates or arbitrary JS are accepted.
@MainActor final class ComputerTools {
    static let definitions: [ToolDefinition] = [
        .init(name: "open_application", description: "Launch and focus an installed macOS application using its exact bundle_id. Returns pid; take a fresh computer_snapshot before interacting.", parameters: ToolCatalog.schema(["bundle_id": "string"], required: ["bundle_id"])),
        .init(name: "computer_snapshot", description: "Read bounded accessibility tree for bundle_id (default frontmost app). Returns snapshot_id and element IDs. Optional capture: none/window/screen; PNG stays local. Requires macOS Accessibility / Screen Recording permission.", parameters: ToolCatalog.schema(["bundle_id": "string", "max_elements": "integer", "max_depth": "integer", "capture": "string"], required: [])),
        .init(name: "computer_action", description: "Act on exact AX snapshot element. action: click/fill/scroll/key. key uses named key and comma-separated modifiers (command/shift/option/control), requires the snapshot app to be frontmost with a non-secure focused element. Letter shortcuts require command/control. snapshot_id and element_id required. fill uses text; scroll uses direction up/down/left/right. Secure fields are forbidden. Take a new snapshot after each action.", parameters: ToolCatalog.schema(["snapshot_id": "string", "element_id": "string", "action": "string", "text": "string", "direction": "string", "key": "string", "modifiers": "string"], required: ["snapshot_id", "element_id", "action"])),
        .init(name: "browser_action", description: "Safari/Chrome browser tabs/read/open/click/fill through Apple Events. browser safari/chrome required. read needs window (1-based), tab (1-based); returns snapshot_id and element_id. open needs url and creates tab. click/fill need snapshot_id and element_id from read; fill needs text. Password/secret fields forbidden. No arbitrary JS. When JavaScript from Apple Events is disabled, read automatically selects the requested tab and uses macOS Accessibility; its snapshot IDs also work with browser click/fill. Settings changes are unsupported.", parameters: ToolCatalog.schema(["browser": "string", "action": "string", "window": "integer", "tab": "integer", "url": "string", "snapshot_id": "string", "element_id": "string", "text": "string"], required: ["browser", "action"]))
    ]
    private var axSnapshot = ""
    private var axPID: pid_t = 0
    private var elements: [String: AXUIElement] = [:]
    private var axCreated = Date.distantPast
    private struct DOMSnapshot {
        var id: String; var browser: String; var window: Int; var tab: Int; var url: String
        var items: [String: JSONValue]; var created: Date
    }
    private var dom: DOMSnapshot?
    private struct AccessibleBrowserSnapshot { let browser: String; let id: String; let url: String; let tab: Int }
    private var accessibleBrowser: AccessibleBrowserSnapshot?
    private let captureDirectory: URL
    init(captureDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("STIXAgent-Captures", isDirectory: true)) { self.captureDirectory = captureDirectory }

    func snapshot(_ args: JSONValue) async throws -> ToolOutcome {
        accessibleBrowser = nil
        try ComputerToolValidation.validate(args, allowed: ["bundle_id", "max_elements", "max_depth", "capture"])
        let limit = try ComputerToolValidation.boundedInt(args["max_elements"], fallback: 150, range: 1...500)
        let depth = try ComputerToolValidation.boundedInt(args["max_depth"], fallback: 8, range: 1...15)
        let capture = args["capture"].string ?? "none"
        guard ["none", "window", "screen"].contains(capture) else { throw AgentError.message("capture: none/window/screen") }
        guard AXIsProcessTrusted() else { throw AgentError.message("Разрешите STIX Agent в System Settings → Privacy & Security → Accessibility") }
        let app: NSRunningApplication?
        if let bundle = args["bundle_id"].string { app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first }
        else { app = NSWorkspace.shared.frontmostApplication }
        guard let app, !app.isTerminated else { throw AgentError.message("Приложение не запущено") }
        let pid = app.processIdentifier
        axSnapshot = ""; elements.removeAll()
        let worker = Task.detached(priority: .userInitiated) { try Self.captureTree(pid: pid, limit: limit, depth: depth) }
        let tree = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
        try Task.checkCancellation()
        axSnapshot = UUID().uuidString; axPID = pid; axCreated = Date(); elements = tree.elements
        var result: [String: JSONValue] = ["snapshot_id": .string(axSnapshot), "bundle_id": .string(app.bundleIdentifier ?? ""), "elements": .array(tree.rows), "bounded": .bool(tree.bounded)]
        var attachments: [Attachment] = []
        if capture != "none" {
            let path = try await screenshot(pid: axPID, windowOnly: capture == "window")
            result["capture_path"] = .string(path)
            attachments.append(.init(path: path, kind: "image"))
        }
        return .init(text: JSONValue.object(result).encoded, attachments: attachments)
    }
    private struct AXTree: @unchecked Sendable {
        let rows: [JSONValue]
        let elements: [String: AXUIElement]
        let bounded: Bool
    }
    nonisolated private static func captureTree(pid: pid_t, limit: Int, depth: Int) throws -> AXTree {
        let root = AXUIElementCreateApplication(pid)
        let deadline = Date().addingTimeInterval(3)
        var exhausted = false
        func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
            guard !Task.isCancelled, Date() < deadline else { exhausted = true; return nil }
            AXUIElementSetMessagingTimeout(element, Float(min(0.15, max(0.001, deadline.timeIntervalSinceNow))))
            var value: CFTypeRef?
            return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
        }
        func string(_ element: AXUIElement, _ key: String) -> String { attribute(element, key) as? String ?? "" }
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        var elements: [String: AXUIElement] = [:]
        var rows: [JSONValue] = []
        var seen = Set<CFHashCode>()
        func visit(_ element: AXUIElement, _ level: Int, _ parent: String?) throws {
            try Task.checkCancellation()
            guard Date() < deadline, rows.count < limit, level <= depth, seen.insert(CFHash(element)).inserted else { return }
            let id = "e\(rows.count + 1)"
            let role = string(element, kAXRoleAttribute), subrole = string(element, kAXSubroleAttribute)
            let title = string(element, kAXTitleAttribute), description = string(element, kAXDescriptionAttribute)
            guard !exhausted, Date() < deadline else { exhausted = true; return }
            let secure = subrole == kAXSecureTextFieldSubrole || ComputerToolValidation.isSecret(title + " " + description + " " + string(element, kAXIdentifierAttribute))
            var row: [String: JSONValue] = ["id": .string(id), "role": .string(role), "depth": .number(Double(level)), "secure": .bool(secure)]
            if let parent { row["parent"] = .string(parent) }
            if !secure {
                row["title"] = .string(String(title.prefix(500))); row["description"] = .string(String(description.prefix(500)))
                if let value = attribute(element, kAXValueAttribute) as? String { row["value"] = .string(String(value.prefix(1000))) }
                elements[id] = element
            }
            rows.append(.object(row))
            if !secure { for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(limit) { try visit(child, level + 1, id) } }
        }
        for window in windows.prefix(20) { try visit(window, 0, nil) }
        try Task.checkCancellation()
        return AXTree(rows: rows, elements: elements, bounded: exhausted || rows.count >= limit || Date() >= deadline)
    }
    func openApplication(_ args: JSONValue) async throws -> ToolOutcome {
        try ComputerToolValidation.validate(args, allowed: ["bundle_id"])
        let bundle = try ComputerToolValidation.bundleID(args.requiredString("bundle_id"))
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { throw AgentError.message("Приложение не установлено: " + bundle) }
        try Task.checkCancellation()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let app = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        try Task.checkCancellation()
        axSnapshot = ""; elements.removeAll(); dom = nil
        return .init(text: "Открыто: " + bundle + " | pid=" + String(app.processIdentifier) + ". Запросите computer_snapshot для проверки окна.")
    }
    func action(_ args: JSONValue) async throws -> ToolOutcome {
        try ComputerToolValidation.validate(args, allowed: ["snapshot_id", "element_id", "action", "text", "direction", "key", "modifiers"])
        let id = try args.requiredString("snapshot_id"), elementID = try args.requiredString("element_id"), action = try args.requiredString("action")
        guard id == axSnapshot, Date().timeIntervalSince(axCreated) < 120, let element = elements[elementID],
              NSRunningApplication(processIdentifier: axPID)?.isTerminated == false else { throw AgentError.message("Снимок устарел: вызовите computer_snapshot") }
        guard AXIsProcessTrusted() else { throw AgentError.message("Недоступно разрешение Accessibility") }
        let identity = [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute].map { string(element, $0) }.joined(separator: " ")
        guard string(element, kAXSubroleAttribute) != kAXSecureTextFieldSubrole, !ComputerToolValidation.isSecret(identity) else { throw AgentError.message("Действия с защищённым полем запрещены") }
        let status: AXError
        switch action {
        case "click": status = AXUIElementPerformAction(element, kAXPressAction as CFString)
        case "fill":
            guard [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(string(element, kAXRoleAttribute)),
                  let text = args["text"].string, text.utf8.count <= 20_000 else { throw AgentError.message("Нужно текстовое поле и text до 20 КБ") }
            var settable = DarwinBoolean(false)
            guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue else { throw AgentError.message("Поле недоступно для записи") }
            status = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        case "key":
            // Clicking our approval card can temporarily focus STIX Agent. Restore
            // only that focus transition; never steal focus from another user app.
            if let ownID = Bundle.main.bundleIdentifier,
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ownID,
               let target = NSRunningApplication(processIdentifier: axPID), !target.isTerminated {
                target.activate()
                try await Task.sleep(nanoseconds: 150_000_000)
                try Task.checkCancellation()
            }
            guard args["text"] == .null, NSWorkspace.shared.frontmostApplication?.processIdentifier == axPID else { throw AgentError.message("Клавиши требуют активного приложения снимка; text запрещён") }
            let (code, flags) = try ComputerToolValidation.key(args.requiredString("key"), modifiers: args["modifiers"].string ?? "")
            let application = AXUIElementCreateApplication(axPID)
            AXUIElementSetMessagingTimeout(application, 0.15)
            guard let focused = attribute(application, kAXFocusedUIElementAttribute), CFGetTypeID(focused) == AXUIElementGetTypeID() else { throw AgentError.message("Не удалось проверить активное поле") }
            let focusedElement = unsafeBitCast(focused, to: AXUIElement.self)
            AXUIElementSetMessagingTimeout(focusedElement, 0.15)
            let focusedIdentity = [kAXTitleAttribute, kAXDescriptionAttribute, kAXIdentifierAttribute].map { string(focusedElement, $0) }.joined(separator: " ")
            guard attribute(focusedElement, kAXRoleAttribute) as? String != nil, string(focusedElement, kAXSubroleAttribute) != kAXSecureTextFieldSubrole, !ComputerToolValidation.isSecret(focusedIdentity) else { throw AgentError.message("Защищённое или непроверенное активное поле: клавиши запрещены") }
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true), let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { throw AgentError.message("Не удалось создать событие клавиши") }
            try Task.checkCancellation()
            down.flags = flags; up.flags = flags
            down.postToPid(axPID); up.postToPid(axPID)
            status = .success
        case "scroll":
            let directions = ["up": "AXScrollUpByPage", "down": "AXScrollDownByPage", "left": "AXScrollLeftByPage", "right": "AXScrollRightByPage"]
            guard let direction = args["direction"].string, let name = directions[direction] else { throw AgentError.message("direction: up/down/left/right") }
            status = AXUIElementPerformAction(element, name as CFString)
        default: throw AgentError.message("action: click/fill/scroll/key")
        }
        axSnapshot = ""; elements.removeAll()
        guard status == .success else { throw AgentError.message("Accessibility action failed: \(status.rawValue); приложение может не поддерживать это действие") }
        return .init(text: "Действие выполнено; запросите новый снимок для проверки результата.")
    }
    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?; return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }
    private func string(_ element: AXUIElement, _ key: String) -> String { attribute(element, key) as? String ?? "" }
    private func screenshot(pid: pid_t, windowOnly: Bool) async throws -> String {
        guard CGPreflightScreenCaptureAccess() else { throw AgentError.message("Разрешите Screen Recording для STIX Agent в System Settings") }
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let filter: SCContentFilter
        let config = SCStreamConfiguration()
        if windowOnly {
            guard let window = content.windows.first(where: { $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 1 }) else { throw AgentError.message("Окно для снимка не найдено") }
            filter = SCContentFilter(desktopIndependentWindow: window)
            config.width = min(Int(window.frame.width * 2), 4096); config.height = min(Int(window.frame.height * 2), 4096)
        } else {
            guard let display = content.displays.first else { throw AgentError.message("Экран не найден") }
            filter = SCContentFilter(display: display, excludingWindows: [])
            config.width = min(display.width, 4096); config.height = min(display.height, 4096)
        }
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = captureDirectory.appendingPathComponent(UUID().uuidString + ".png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw AgentError.message("Не удалось создать PNG") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AgentError.message("Не удалось сохранить PNG") }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url.path
    }
    func browserAction(_ args: JSONValue) async throws -> ToolOutcome {
        try ComputerToolValidation.browserAction(args)
        try ComputerToolValidation.validate(args, allowed: ["browser", "action", "window", "tab", "url", "snapshot_id", "element_id", "text"])
        let browser = try args.requiredString("browser"), action = try args.requiredString("action")
        guard ["safari", "chrome"].contains(browser) else { throw AgentError.message("browser: safari/chrome") }
        let bundle = browser == "safari" ? "com.apple.Safari" : "com.google.Chrome"
        if NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty {
            guard action == "open" else { throw AgentError.message("Сначала запустите браузер " + browser) }
            _ = try ComputerToolValidation.webURL(args.requiredString("url"))
            _ = try await openApplication(.object(["bundle_id": .string(bundle)]))
        }
        let app = "application id " + ComputerToolValidation.appleString(bundle)
        if action == "tabs" {
            let script = """
            set output to ""
            tell \(app)
                repeat with wi from 1 to count of windows
                    repeat with ti from 1 to count of tabs of window wi
                        set t to tab ti of window wi
                        set output to output & wi & ":" & ti & " | " & \(browser == "safari" ? "name" : "title") of t & " | " & URL of t & linefeed
                    end repeat
                end repeat
            end tell
            return output
            """
            return .init(text: String((try await appleEvent(script)).prefix(30_000)))
        }
        if action == "open" {
            let url = try ComputerToolValidation.webURL(args.requiredString("url"))
            let expression = "make new tab at end of tabs of front window with properties {URL:\(ComputerToolValidation.appleString(url))}"
            let makeWindow = browser == "safari" ? "make new document" : "make new window"
            _ = try await appleEvent("tell \(app)\nif (count of windows) is 0 then \(makeWindow)\n\(expression)\nend tell")
            dom = nil; accessibleBrowser = nil
            return .init(text: "Вкладка создана: \(url). Используйте tabs/read для проверки загрузки.")
        }
        if action == "read" {
            let window = try ComputerToolValidation.boundedInt(args["window"], fallback: 1, range: 1...1000)
            let tab = try ComputerToolValidation.boundedInt(args["tab"], fallback: 1, range: 1...1000)
            let raw: String
            do { raw = try await browserJS(Self.readDOM, browser: browser, window: window, tab: tab) }
            catch {
                if Task.isCancelled { throw CancellationError() }
                guard ComputerToolValidation.javascriptUnavailable(error.localizedDescription) else { throw error }
                return try await accessibleBrowserRead(browser: browser, window: window, tab: tab)
            }
            accessibleBrowser = nil
            let result = try JSONValue.parse(raw)
            let id = UUID().uuidString
            var items: [String: JSONValue] = [:]
            for item in result["elements"].array ?? [] { if let key = item["id"].string { items[key] = item } }
            dom = .init(id: id, browser: browser, window: window, tab: tab, url: result["url"].string ?? "", items: items, created: Date())
            var output = result.object ?? [:]; output["snapshot_id"] = .string(id)
            return .init(text: JSONValue.object(output).encoded)
        }
        if let fallback = accessibleBrowser, fallback.browser == browser, args["snapshot_id"].string == fallback.id {
            let currentURL = try await appleEvent("tell \(app) to return URL of tab \(fallback.tab) of window 1")
            guard currentURL == fallback.url else { accessibleBrowser = nil; throw AgentError.message("Вкладка изменилась. Выполните read повторно.") }
            var actionArgs: [String: JSONValue] = ["snapshot_id": .string(fallback.id), "element_id": args["element_id"], "action": .string(action)]
            if let text = args["text"].string { actionArgs["text"] = .string(text) }
            defer { accessibleBrowser = nil }
            return try await self.action(.object(actionArgs))
        }
        guard ["click", "fill"].contains(action), let snapshot = dom,
              snapshot.browser == browser, try args.requiredString("snapshot_id") == snapshot.id,
              Date().timeIntervalSince(snapshot.created) < 120,
              let item = snapshot.items[try args.requiredString("element_id")] else { throw AgentError.message("Нужно read и действительный snapshot_id/element_id; action: tabs/read/open/click/fill") }
        let text = args["text"].string ?? ""
        guard text.utf8.count <= 20_000 else { throw AgentError.message("text превышает 20 КБ") }
        if action == "fill", args["text"].string == nil { throw AgentError.message("Для fill нужен text") }
        let payload: JSONValue = .object(["action": .string(action), "url": .string(snapshot.url), "item": item, "text": .string(text)])
        // Only this fixed, reviewed program can execute. Arguments are serialized as JSON, then escaped for AppleScript.
        let script = "(() => { const p = \(payload.encoded); \(Self.actDOM) })()"
        let result = try await browserJS(script, browser: browser, window: snapshot.window, tab: snapshot.tab)
        dom = nil
        let parsed = try JSONValue.parse(result)
        guard parsed["ok"].bool == true else { throw AgentError.message(parsed["error"].string ?? "Browser action failed") }
        return .init(text: "Действие выполнено; вызовите read для проверки результата.")
    }
    /// Uses the existing AX permission when DOM scripting is disabled. Select the
    /// exact requested tab first; metadata comes from Apple Events without JS.
    private func accessibleBrowserRead(browser: String, window: Int, tab: Int) async throws -> ToolOutcome {
        let bundle = browser == "safari" ? "com.apple.Safari" : "com.google.Chrome"
        let app = "application id " + ComputerToolValidation.appleString(bundle)
        let select = browser == "safari" ? "set current tab of targetWindow to targetTab" : "set active tab index of targetWindow to \(tab)"
        let title = browser == "safari" ? "name" : "title"
        let metadata = try await appleEvent("""
        tell \(app)
            set targetWindow to window \(window)
            set targetTab to tab \(tab) of targetWindow
            \(select)
            set index of targetWindow to 1
            activate
            return (URL of targetTab) & linefeed & (\(title) of targetTab)
        end tell
        """)
        let lines = metadata.components(separatedBy: "\n")
        let url = String((lines.first ?? "").prefix(8192)), pageTitle = String(lines.dropFirst().joined(separator: "\n").prefix(1000))
        var output: [String: JSONValue] = ["mode": .string("accessibility"), "url": .string(url), "title": .string(pageTitle), "note": .string("JavaScript браузера отключён. Выбрана запрошенная вкладка; используются системные элементы macOS. Для click/fill используйте snapshot_id/element_id ниже; произвольные скрипты и изменение настроек недоступны.")]
        dom = nil
        if AXIsProcessTrusted() {
            let capture = try await snapshot(.object(["bundle_id": .string(bundle), "max_elements": .number(300), "max_depth": .number(12)]))
            let tree = try JSONValue.parse(capture.text)
            output["snapshot_id"] = tree["snapshot_id"]; output["elements"] = tree["elements"]; output["bounded"] = tree["bounded"]
            accessibleBrowser = .init(browser: browser, id: axSnapshot, url: url, tab: tab)
        } else { output["note"] = .string("Прочитаны URL и заголовок без JavaScript. Для текста и элементов страницы разрешите Универсальный доступ STIX Agent в macOS.") }
        return .init(text: JSONValue.object(output).encoded)
    }
    private final class CancellationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        func check() throws { lock.lock(); let value = cancelled; lock.unlock(); if value { throw CancellationError() } }
    }
    nonisolated private static let appleEventsQueue = DispatchQueue(label: "studio.stix.agent.apple-events", qos: .userInitiated)
    private func appleEvent(_ source: String) async throws -> String {
        try Task.checkCancellation()
        let gate = CancellationGate()
        let result: String = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                Self.appleEventsQueue.async {
                    do { try gate.check(); continuation.resume(returning: try Self.sendAppleEvent(source)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { gate.cancel() })
        try Task.checkCancellation()
        return result
    }
    nonisolated private static func sendAppleEvent(_ source: String) throws -> String {
        try Task.checkCancellation()
        guard let script = NSAppleScript(source: "with timeout of 15 seconds\n" + source + "\nend timeout") else { throw AgentError.message("Ошибка подготовки Apple Event") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error { throw AgentError.message("Apple Events: \(error[NSAppleScript.errorMessage] ?? "ошибка"). Разрешите Automation; для DOM включите Allow JavaScript from Apple Events в браузере.") }
        return result.stringValue ?? ""
    }
    private func browserJS(_ javascript: String, browser: String, window: Int, tab: Int) async throws -> String {
        let app = browser == "safari" ? "com.apple.Safari" : "com.google.Chrome"
        let command = browser == "safari" ? "do JavaScript \(ComputerToolValidation.appleString(javascript)) in tab \(tab) of window \(window)" : "execute tab \(tab) of window \(window) javascript \(ComputerToolValidation.appleString(javascript))"
        return try await appleEvent("tell application id \(ComputerToolValidation.appleString(app))\nreturn \(command)\nend tell")
    }
    private static let domHelpers = #"""
    const secret = e => /password|passwd|secret|apikey|token|onetimecode|verificationcode|creditcard|ccnumber|cccsc|cccsv/.test([e.type,e.id,e.name,e.autocomplete,e.getAttribute('aria-label'),e.getAttribute('placeholder')].join('').toLowerCase().replace(/[^a-z0-9]/g,''));
    const signature = e => [e.tagName,e.type||'',e.id||'',e.name||'',e.getAttribute('aria-label')||'',(e.innerText||'').slice(0,160)].join('|');
    const selector = e => {const path=[];let n=e;while(n && n.nodeType===1){let i=1;for(let s=n.previousElementSibling;s;s=s.previousElementSibling)if(s.tagName===n.tagName)i++;path.unshift(n.tagName.toLowerCase()+':nth-of-type('+i+')');n=n.parentElement;}return path.join(' > ');};
    """#
    private static var readDOM: String {
        #"(() => {"# + domHelpers + #"""
        const all=Array.from(document.querySelectorAll('a,button,input,textarea,select,[role="button"],[contenteditable="true"]')).filter(e=>e.getClientRects().length && !secret(e));
        const elements=all.slice(0,250).map((e,i)=>({id:'b'+(i+1),selector:selector(e),signature:signature(e),tag:e.tagName,type:e.type||'',label:(e.innerText||e.getAttribute('aria-label')||e.placeholder||'').slice(0,300)}));
        const clone=document.body?document.body.cloneNode(true):null;
        if(clone)clone.querySelectorAll('script,style,input,textarea,select,[contenteditable],[hidden],[aria-hidden="true"]').forEach(e=>e.remove());
        return JSON.stringify({url:location.href,title:document.title,text:(clone?clone.textContent:'').slice(0,20000),elements,bounded:all.length>250});
        })()
        """#
    }
    private static var actDOM: String {
        domHelpers + #"""
        const fail=error=>JSON.stringify({ok:false,error});
        if(location.href!==p.url)return fail('Page changed; read again');
        const e=document.querySelector(p.item.selector);
        if(!e || signature(e)!==p.item.signature || !e.getClientRects().length)return fail('Element changed; read again');
        if(secret(e))return fail('Protected fields are forbidden');
        if(e.disabled || e.getAttribute('aria-disabled')==='true')return fail('Element disabled');
        if(p.action==='click'){e.click();return JSON.stringify({ok:true});}
        if(!['INPUT','TEXTAREA'].includes(e.tagName)||['password','hidden','file','submit','button','checkbox','radio'].includes(e.type)||e.readOnly)return fail('Not an editable text field');
        const proto=e.tagName==='TEXTAREA'?HTMLTextAreaElement.prototype:HTMLInputElement.prototype;
        const setter=Object.getOwnPropertyDescriptor(proto,'value').set;
        setter.call(e,p.text);e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));
        return JSON.stringify({ok:true});
        """#
    }
}
