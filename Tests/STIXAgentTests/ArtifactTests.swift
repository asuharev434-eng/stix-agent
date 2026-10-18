import XCTest
import WebKit
@testable import STIXAgent

final class ArtifactTests: XCTestCase {
    @MainActor func testNetworkIsolationRulesCompileInRealWebKit() async throws {
        let identifier = "STIXArtifactTest-" + UUID().uuidString
        let result: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: ArtifactSandbox.rules) { rule, error in
                if let error { continuation.resume(throwing: error) }
                else if let rule { continuation.resume(returning: rule) }
                else { continuation.resume(throwing: AgentError.message("WebKit returned no rule list")) }
            }
        }
        XCTAssertEqual(result.identifier, identifier)
        try await WKContentRuleListStore.default().removeContentRuleList(forIdentifier: identifier)
    }
    @MainActor func testMermaidActuallyRendersOffline() async throws {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), configuration: config)
        let rules: WKContentRuleList = try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "STIXMermaidRenderTest", encodedContentRuleList: ArtifactSandbox.rules) { rule, error in
                if let rule { continuation.resume(returning: rule) }
                else { continuation.resume(throwing: error ?? AgentError.message("No content rules")) }
            }
        }
        config.userContentController.add(rules)
        let html = IsolatedArtifactWebView(source: "flowchart LR\nA[Request] --> B[Tool] --> C[Result]", mermaid: true, dark: false).documentHTML()
        webView.loadHTMLString(html, baseURL: nil)
        let deadline = Date().addingTimeInterval(12)
        var rendered = false
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
            if (try? await webView.evaluateJavaScript("document.querySelector('#diagram svg') !== null")) as? Bool == true { rendered = true; break }
        }
        let diagnostic = (try? await webView.evaluateJavaScript("document.body.innerText")) as? String ?? "no DOM"
        XCTAssertTrue(rendered, String(diagnostic.prefix(1000)))
    }

}
