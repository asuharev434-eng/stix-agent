import XCTest
@testable import STIXAgent

final class WebSearchTests: XCTestCase {
    func testLiveDuckDuckGoSearchWithoutInferenceServers() async throws {
        guard ProcessInfo.processInfo.environment["STIX_TEST_LIVE_WEB_SEARCH"] == "1" else {
            throw XCTSkip("Set STIX_TEST_LIVE_WEB_SEARCH=1 for the network smoke test")
        }
        let results = try await WebSearchClient().search(query: "Swift programming language official documentation", limit: 3)
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.url.hasPrefix("https://") || $0.url.hasPrefix("http://") })
    }

    func testParseActualDuckMarkupRedirectSnippetAndEntities() throws {
        let html = #"""
        <div class="result"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.swift.org%2Fdocumentation%2F&amp;rut=opaque">Swift &amp; <b>Documentation</b></a>
        <a class="result__snippet">Local &#x41;PI &quot;reference&quot;</a></div>
        <a class="result__a" href="javascript:alert(1)">bad</a><a class="result__a" href="http://127.0.0.1/secret">internal</a>
        """#
        let results = try WebSearchClient.parseResults(html, limit: 5)
        XCTAssertEqual(results.count, 1); XCTAssertEqual(results[0].url, "https://www.swift.org/documentation/")
        XCTAssertEqual(results[0].title, "Swift & Documentation"); XCTAssertEqual(results[0].snippet, "Local API \"reference\"")
    }
    func testChallengeAndPublicURLGuards() throws {
        XCTAssertThrowsError(try WebSearchClient.parseResults("<form id='challenge-form'>captcha</form>", limit: 5))
        for url in ["file:///etc/passwd", "http://127.0.0.1", "http://169.254.169.254/latest", "http://user:pass@example.com", "https://x.local/path", "http://[::1]/", "http://[::ffff:7f00:1]/", "https://example.com:8188"] { XCTAssertThrowsError(try WebSearchClient.publicURL(url), url) }
        for address in ["10.1.2.3", "192.168.1.1", "172.16.0.1", "::1", "::ffff:127.0.0.1", "::ffff:7f00:1", "fe80::123", "fd12::34", "::127.0.0.1"] { XCTAssertFalse(WebSearchClient.isPublicAddress(address), address) }
        XCTAssertNoThrow(try WebSearchClient.publicURL("https://www.swift.org/documentation/"))
        XCTAssertTrue(WebSearchClient.isPublicAddress("1.1.1.1")); XCTAssertTrue(WebSearchClient.isPublicAddress("2606:4700::1111"))
    }
    func testReaderStripsActiveContentAndKeepsUnicodeText() {
        let input = "<html><script>\nSECRET_JS\n</script><style>\np {color:red}\n</style><p>Привет &amp; Swift</p><p>&#1052;&#1080;&#1088;</p></html>"
        let result = WebSearchClient.text(input)
        XCTAssertFalse(result.contains("SECRET_JS")); XCTAssertFalse(result.contains("color:red")); XCTAssertTrue(result.contains("Привет & Swift")); XCTAssertTrue(result.contains("Мир"))
    }
    @MainActor func testWebToolsCanBeDisabledThroughChat() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(storage: .init(paths: .init(root: root)))
        XCTAssertTrue(store.allTools().contains { $0.name == "web_search" })
        _ = try store.applyPreference(key: "web_search_enabled", value: "false", chatID: try XCTUnwrap(store.selectedID))
        XCTAssertFalse(store.allTools().contains { $0.name == "web_search" })
    }
}
