import SwiftUI
import WebKit
import AppKit

struct ArtifactView: View {
    let attachment: Attachment
    @Environment(\.colorScheme) private var colorScheme
    @State private var source = ""
    @State private var error: String?
    @State private var showSource = false
    @State private var expanded = false
    private var isMermaid: Bool { attachment.kind == "mermaid" || ["mmd", "mermaid"].contains(URL(fileURLWithPath: attachment.path).pathExtension.lowercased()) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: isMermaid ? "point.3.connected.trianglepath.dotted" : "rectangle.and.text.magnifyingglass").foregroundStyle(.secondary)
                Text(attachment.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                Button { showSource.toggle() } label: { Image(systemName: showSource ? "eye" : "chevron.left.forwardslash.chevron.right") }.help("Исходный код")
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.help("Изменить высоту")
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: attachment.path)]) } label: { Image(systemName: "folder") }.help("Показать в Finder")
                Menu { Button("Открыть файл во внешнем приложении") { NSWorkspace.shared.open(URL(fileURLWithPath: attachment.path)) } } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 18)
            }.buttonStyle(.borderless).padding(12)
            Divider()
            if let error { ContentUnavailableView("Предпросмотр недоступен", systemImage: "doc.text", description: Text(error)).frame(height: 180) }
            else if showSource { ScrollView([.horizontal, .vertical]) { Text(source).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).padding(15).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: expanded ? 650 : 400) }
            else { IsolatedArtifactWebView(source: source, mermaid: isMermaid, dark: colorScheme == .dark).frame(height: expanded ? 650 : 400) }
            HStack(spacing: 5) { Image(systemName: "lock.shield"); Text("Изолированный предпросмотр · без доступа к сети и файлам"); Spacer() }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
        }.background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 13)).clipShape(RoundedRectangle(cornerRadius: 13)).overlay(RoundedRectangle(cornerRadius: 13).stroke(.primary.opacity(0.09)))
            .task(id: attachment.path) { load() }
    }
    private func load() {
        do {
            let url = URL(fileURLWithPath: attachment.path)
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: 2 * 1024 * 1024 + 1) ?? Data()
            guard bytes.count <= 2 * 1024 * 1024 else { throw AgentError.message("Файл превышает лимит предпросмотра 2 МБ") }
            guard let decoded = String(data: bytes, encoding: .utf8) else { throw AgentError.message("Требуется текстовый файл UTF-8") }
            source = decoded; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct IsolatedArtifactWebView: NSViewRepresentable {
    let source: String
    let mermaid: Bool
    let dark: Bool
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        let key = "\(dark)-\(mermaid)-\(source)"
        guard context.coordinator.key != key else { return }
        context.coordinator.key = key
        let document = documentHTML()
        // All URL-based subresources are blocked independently of untrusted markup/CSP.
        let rules = ArtifactSandbox.rules
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "STIXArtifactNoNetwork-v1", encodedContentRuleList: rules) { list, error in
            guard context.coordinator.key == key else { return }
            if let list {
                view.configuration.userContentController.add(list)
                view.loadHTMLString(document, baseURL: nil)
            } else {
                view.loadHTMLString("<html><body>Изолированный предпросмотр недоступен: не удалось включить защиту сети.</body></html>", baseURL: nil)
                NSLog("Artifact isolation rule compilation failed: %@", error?.localizedDescription ?? "unknown")
            }
        }
    }
    func documentHTML() -> String {
        let background = dark ? "#1c1c1e" : "#ffffff"
        let foreground = dark ? "#eeeeef" : "#202124"
        let csp = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; media-src 'none'; worker-src 'none'"
        var content = source
        if mermaid {
            let scriptURL = Bundle.module.url(forResource: "mermaid-10.9.3.min", withExtension: "js", subdirectory: "Resources")
            if let scriptURL, let script = try? String(contentsOf: scriptURL, encoding: .utf8) {
                let encoded = String(data: (try? JSONEncoder().encode(source)) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
                content = "<div id='diagram'></div><pre id='failure' style='white-space:pre-wrap'></pre><script>\(script)</script><script>try { mermaid.initialize({startOnLoad:false,securityLevel:'strict',theme:'\(dark ? "dark" : "default")'}); const source=\(encoded.replacingOccurrences(of: "<", with: "\\u003c")); mermaid.render('stixDiagram',source).then(r=>{document.getElementById('diagram').innerHTML=r.svg}).catch(e=>{document.getElementById('failure').textContent='Не удалось отобразить Mermaid: '+e.message+'\\n\\n'+source}); } catch(e) { document.getElementById('failure').textContent='Ошибка схемы: '+e.message; }</script>"
            } else { content = "<p>Локальная библиотека Mermaid недоступна. Исходный код:</p><pre>\(escape(source))</pre>" }
        }
        let child = "<!doctype html><html><head><meta http-equiv='Content-Security-Policy' content=\"\(csp)\"><meta name='color-scheme' content='\(dark ? "dark" : "light")'><style>html{color-scheme:\(dark ? "dark" : "light");background:\(background);color:\(foreground);font:14px -apple-system,system-ui}body{margin:16px}svg{max-width:100%;height:auto}pre{white-space:pre-wrap}</style></head><body>\(content)</body></html>"
        // This WebView never loads app pages or local URLs and has no native bridge.
        // A leading immutable CSP plus URL content blocking isolates untrusted scripts.
        return child

    }
    private func escape(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var key = ""
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = navigationAction.request.url
            let initial = navigationAction.navigationType == .other && ["about:blank", "about:srcdoc"].contains(url?.absoluteString ?? "")
            decisionHandler(initial ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
    }
}

enum ArtifactSandbox {
    // WebKit's URL-filter regex subset rejects alternation; keep schemes in separate rules.
    static let rules = """
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^about:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":"^blob:"},"action":{"type":"ignore-previous-rules"}}]
    """
}
