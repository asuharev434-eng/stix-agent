import XCTest
@testable import STIXAgent

final class MCPAuthorizationTests: XCTestCase {
    func testChallengeAndWellKnownPaths() throws {
        let challenge = MCPAuthorization.challenge(#"Bearer resource_metadata="https://stixapp.ru/.well-known/oauth-protected-resource/mcp", scope="stix:read stix:write""#)
        XCTAssertEqual(challenge.metadata, "https://stixapp.ru/.well-known/oauth-protected-resource/mcp")
        XCTAssertEqual(challenge.scopes, ["stix:read", "stix:write"])
        XCTAssertNil(MCPAuthorization.challenge("Basic password=abc").metadata)
        XCTAssertEqual(MCPAuthorization.resourceMetadataURLs(endpoint: URL(string: "https://stixapp.ru/mcp")!, challengeURL: nil).map(\.path), ["/.well-known/oauth-protected-resource/mcp", "/.well-known/oauth-protected-resource"])
        XCTAssertEqual(MCPAuthorization.authorizationMetadataURLs(issuer: URL(string: "https://example.com/tenant")!).first?.path, "/.well-known/oauth-authorization-server/tenant")
        XCTAssertThrowsError(try MCPAuthorization.secureURL("http://example.com/mcp"))
    }
    func testMockDiscoveryAndRegistration() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockOAuthProtocol.self]
        let session = URLSession(configuration: configuration)
        let discovery = MCPAuthorizationDiscovery(session: session)
        let result = try await discovery.discover(endpoint: "https://stixapp.ru/mcp")
        XCTAssertEqual(result.resource.resource, "https://stixapp.ru/mcp")
        XCTAssertEqual(result.server.issuer, "https://stixapp.ru")
        XCTAssertEqual(result.suggestedScopes, ["stix:read"])
        let clientID = try await discovery.register(server: result.server)
        XCTAssertEqual(clientID, "native-client")
    }
    func testLegacyPluginDecodesWithoutOAuthAndRoundTripsNewMetadata() throws {
        let legacy = Data(#"{"id":"old","name":"Local","transport":"stdio","command":"/usr/bin/true","arguments":[],"url":"","enabled":true}"#.utf8)
        let plugin = try JSONDecoder().decode(PluginConfig.self, from: legacy)
        XCTAssertNil(plugin.oauth)
        var modern = plugin
        modern.transport = "http"; modern.url = "https://stixapp.ru/mcp"
        modern.oauth = OAuthConfiguration(authorizationEndpoint: "https://stixapp.ru/oauth/authorize", tokenEndpoint: "https://stixapp.ru/oauth/token", clientID: "client", scopes: ["stix:read"], resource: modern.url, issuer: "https://stixapp.ru")
        let copy = try JSONDecoder().decode(PluginConfig.self, from: JSONEncoder().encode(modern))
        XCTAssertEqual(copy, modern)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(copy), as: UTF8.self).contains("access_token"))
    }
}

private final class MockOAuthProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        let status: Int
        let body: String
        var headers = ["Content-Type": "application/json"]
        switch path {
        case "/mcp":
            status = 401; body = "{}"
            headers["WWW-Authenticate"] = #"Bearer resource_metadata="https://stixapp.ru/.well-known/oauth-protected-resource/mcp", scope="stix:read""#
        case "/.well-known/oauth-protected-resource/mcp":
            status = 200
            body = #"{"resource":"https://stixapp.ru/mcp","authorization_servers":["https://stixapp.ru"],"scopes_supported":["stix:read","stix:write"]}"#
        case "/.well-known/oauth-authorization-server":
            status = 200
            body = #"{"issuer":"https://stixapp.ru","authorization_endpoint":"https://stixapp.ru/oauth/authorize","token_endpoint":"https://stixapp.ru/oauth/token","registration_endpoint":"https://stixapp.ru/oauth/register","code_challenge_methods_supported":["S256"],"token_endpoint_auth_methods_supported":["none"]}"#
        case "/oauth/register":
            status = 201; body = #"{"client_id":"native-client","token_endpoint_auth_method":"none"}"#
        default: status = 404; body = "{}"
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
