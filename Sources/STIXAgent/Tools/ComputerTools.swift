import AppKit
import ApplicationServices
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

/// Validation is pure and deliberately independent of macOS privacy permissions.
enum ComputerToolValidation {
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
    static func appleString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }
}

/// One retained instance owns the most recent AX and DOM snapshots. No coordinates or arbitrary JS are accepted.
@MainActor final class ComputerTools {
    static let definitions: [ToolDefinition] = [
        .init(name: "computer_snapshot", description: "Read bounded accessibility tree for bundle_id (default frontmost app). Returns snapshot_id and element IDs. Optional capture: none/window/screen; PNG stays local. Requires macOS Accessibility / Screen Recording permission.", parameters: ToolCatalog.schema(["bundle_id": "string", "max_elements": "integer", "max_depth": "integer", "capture": "string"], required: [])),
        .init(name: "computer_action", description: "Act on exact AX snapshot element. action: click/fill/scroll. snapshot_id and element_id required. fill uses text; scroll uses direction up/down/left/right. Secure fields are forbidden. Take a new snapshot after each action.", parameters: ToolCatalog.schema(["snapshot_id": "string", "element_id": "string", "action": "string", "text": "string", "direction": "string"], required: ["snapshot_id", "element_id", "action"])),
        .init(name: "browser_action", description: "Safari/Chrome browser tabs/read/open/click/fill through Apple Events. browser safari/chrome required. read needs window (1-based), tab (1-based); returns snapshot_id and element_id. open needs url and creates tab. click/fill need snapshot_id and element_id from read; fill needs text. Password/secret fields forbidden. No arbitrary JS. Browser must allow JavaScript from Apple Events for DOM actions.", parameters: ToolCatalog.schema(["browser": "string", "action": "string", "window": "integer", "tab": "integer", "url": "string", "snapshot_id": "string", "element_id": "string", "text": "string"], required: ["browser", "action"]))
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
    private let captureDirectory: URL
    init(captureDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("STIXAgent-Captures", isDirectory: true)) { self.captureDirectory = captureDirectory }

    func snapshot(_ args: JSONValue) async throws -> ToolOutcome {
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
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 1)
        axSnapshot = UUID().uuidString; axPID = app.processIdentifier; axCreated = Date(); elements.removeAll()
        let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let deadline = Date().addingTimeInterval(3)
        var rows: [JSONValue] = []
        var seen = Set<CFHashCode>()
        func visit(_ element: AXUIElement, _ level: Int, _ parent: String?) throws {
            try Task.checkCancellation()
            guard Date() < deadline, rows.count < limit, level <= depth, seen.insert(CFHash(element)).inserted else { return }
            let id = "e\(rows.count + 1)"
            let role = string(element, kAXRoleAttribute), subrole = string(element, kAXSubroleAttribute)
            let title = string(element, kAXTitleAttribute), description = string(element, kAXDescriptionAttribute)
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
        var result: [String: JSONValue] = ["snapshot_id": .string(axSnapshot), "bundle_id": .string(app.bundleIdentifier ?? ""), "elements": .array(rows), "bounded": .bool(rows.count >= limit || Date() >= deadline)]
        var attachments: [Attachment] = []
        if capture != "none" {
            let path = try await screenshot(pid: axPID, windowOnly: capture == "window")
            result["capture_path"] = .string(path)
            attachments.append(.init(path: path, kind: "image"))
        }
        return .init(text: JSONValue.object(result).encoded, attachments: attachments)
    }
    func action(_ args: JSONValue) throws -> ToolOutcome {
        try ComputerToolValidation.validate(args, allowed: ["snapshot_id", "element_id", "action", "text", "direction"])
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
        case "scroll":
            let directions = ["up": "AXScrollUpByPage", "down": "AXScrollDownByPage", "left": "AXScrollLeftByPage", "right": "AXScrollRightByPage"]
            guard let direction = args["direction"].string, let name = directions[direction] else { throw AgentError.message("direction: up/down/left/right") }
            status = AXUIElementPerformAction(element, name as CFString)
        default: throw AgentError.message("action: click/fill/scroll")
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
    func browserAction(_ args: JSONValue) throws -> ToolOutcome {
        try ComputerToolValidation.validate(args, allowed: ["browser", "action", "window", "tab", "url", "snapshot_id", "element_id", "text"])
        let browser = try args.requiredString("browser"), action = try args.requiredString("action")
        guard ["safari", "chrome"].contains(browser) else { throw AgentError.message("browser: safari/chrome") }
        let bundle = browser == "safari" ? "com.apple.Safari" : "com.google.Chrome"
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else { throw AgentError.message("Сначала запустите браузер \(browser)") }
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
            return .init(text: String(try appleEvent(script).prefix(30_000)))
        }
        if action == "open" {
            let url = try ComputerToolValidation.webURL(args.requiredString("url"))
            let expression = "make new tab at end of tabs of front window with properties {URL:\(ComputerToolValidation.appleString(url))}"
            let makeWindow = browser == "safari" ? "make new document" : "make new window"
            _ = try appleEvent("tell \(app)\nif (count of windows) is 0 then \(makeWindow)\n\(expression)\nend tell")
            dom = nil
            return .init(text: "Вкладка создана: \(url). Используйте tabs/read для проверки загрузки.")
        }
        if action == "read" {
            let window = try ComputerToolValidation.boundedInt(args["window"], fallback: 1, range: 1...1000)
            let tab = try ComputerToolValidation.boundedInt(args["tab"], fallback: 1, range: 1...1000)
            let raw = try browserJS(Self.readDOM, browser: browser, window: window, tab: tab)
            let result = try JSONValue.parse(raw)
            let id = UUID().uuidString
            var items: [String: JSONValue] = [:]
            for item in result["elements"].array ?? [] { if let key = item["id"].string { items[key] = item } }
            dom = .init(id: id, browser: browser, window: window, tab: tab, url: result["url"].string ?? "", items: items, created: Date())
            var output = result.object ?? [:]; output["snapshot_id"] = .string(id)
            return .init(text: JSONValue.object(output).encoded)
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
        let result = try browserJS(script, browser: browser, window: snapshot.window, tab: snapshot.tab)
        dom = nil
        let parsed = try JSONValue.parse(result)
        guard parsed["ok"].bool == true else { throw AgentError.message(parsed["error"].string ?? "Browser action failed") }
        return .init(text: "Действие выполнено; вызовите read для проверки результата.")
    }
    private func appleEvent(_ source: String) throws -> String {
        try Task.checkCancellation()
        guard let script = NSAppleScript(source: "with timeout of 15 seconds\n" + source + "\nend timeout") else { throw AgentError.message("Ошибка подготовки Apple Event") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error { throw AgentError.message("Apple Events: \(error[NSAppleScript.errorMessage] ?? "ошибка"). Разрешите Automation; для DOM включите Allow JavaScript from Apple Events в браузере.") }
        return result.stringValue ?? ""
    }
    private func browserJS(_ javascript: String, browser: String, window: Int, tab: Int) throws -> String {
        let app = browser == "safari" ? "com.apple.Safari" : "com.google.Chrome"
        let command = browser == "safari" ? "do JavaScript \(ComputerToolValidation.appleString(javascript)) in tab \(tab) of window \(window)" : "execute tab \(tab) of window \(window) javascript \(ComputerToolValidation.appleString(javascript))"
        return try appleEvent("tell application id \(ComputerToolValidation.appleString(app))\nreturn \(command)\nend tell")
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
