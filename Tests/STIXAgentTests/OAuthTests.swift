import XCTest
@testable import STIXAgent

final class OAuthTests: XCTestCase {
    private var configuration: OAuthConfiguration {
        .init(authorizationEndpoint: "https://identity.example/authorize", tokenEndpoint: "https://identity.example/token", clientID: "desktop", scopes: ["read", "offline_access"])
    }
    func testRFC7636Challenge() {
        XCTAssertEqual(OAuthPKCE.challenge(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }
    func testRandomAndAuthorizationURL() throws {
        let verifier = try OAuthPKCE.random(), state = try OAuthPKCE.random()
        XCTAssertEqual(verifier.count, 43)
        XCTAssertNotEqual(verifier, state)
        let url = try OAuthPKCE.authorizationURL(configuration: configuration, state: state, verifier: verifier)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(items.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
        XCTAssertEqual(items.first(where: { $0.name == "scope" })?.value, "read offline_access")
        XCTAssertFalse(url.absoluteString.contains(verifier))
        XCTAssertThrowsError(try OAuthPKCE.authorizationURL(configuration: configuration, state: state, verifier: "short"))
    }
    func testEndpointAndScopeValidation() throws {
        try configuration.validate()
        for endpoint in ["http://identity.example/token", "https://user:password@identity.example/token", "https://identity.example/token?secret=abc", "file:///tmp/token"] {
            var config = configuration; config.tokenEndpoint = endpoint
            XCTAssertThrowsError(try config.validate())
        }
        for scopes in [["read write"], ["read", "read"], [""], ["read\nwrite"], ["read\"all"], ["read\\all"]] {
            var config = configuration; config.scopes = scopes
            XCTAssertThrowsError(try config.validate())
        }
        var config = configuration; config.redirectURI = "https://evil.example/callback"
        XCTAssertThrowsError(try config.validate())
    }
    func testCallbackRejectsStateConfusionAndDuplicateParameters() throws {
        let state = "expected"
        XCTAssertEqual(try OAuthPKCE.code(callback: URL(string: "stixagent://oauth/callback?state=expected&code=ok")!, expectedState: state, configuration: configuration), "ok")
        for value in ["stixagent://oauth/callback?state=wrong&code=ok", "stixagent://oauth/callback?state=expected&state=wrong&code=ok", "stixagent://oauth/callback?state=expected&code=ok&code=bad", "stixagent://evil/callback?state=expected&code=ok", "stixagent://oauth/callback?state=expected&error=denied&code=ok", "stixagent://oauth/callback?state=expected&code=ok#fragment"] {
            XCTAssertThrowsError(try OAuthPKCE.code(callback: URL(string: value)!, expectedState: state, configuration: configuration))
        }
    }
    func testConfigurationContainsOnlyPublicMetadataAndBindsTokens() throws {
        let json = String(decoding: try JSONEncoder().encode(configuration), as: UTF8.self)
        XCTAssertFalse(json.contains("access_token"))
        XCTAssertFalse(json.contains("refresh_token"))
        XCTAssertFalse(json.contains("client_secret"))
        var changed = configuration; changed.tokenEndpoint = "https://other.example/token"
        XCTAssertNotEqual(changed.fingerprint, configuration.fingerprint)
        changed = configuration; changed.scopes.append("write")
        XCTAssertNotEqual(changed.fingerprint, configuration.fingerprint)
    }
    func testEnvironmentValidationProtectsExecutionConfiguration() throws {
        try CredentialEnvironment.validate(environment: ["SERVICE_API_KEY": "secret", "STIX_TOKEN": "token"])
        for name in ["PATH", "HOME", "DYLD_INSERT_LIBRARIES", "LD_PRELOAD", "NODE_OPTIONS", "BASH_ENV", "GIT_CONFIG_COUNT", "GIT_SSH_COMMAND", "PYTHONPATH", "bad-name", "lowercase", ""] {
            XCTAssertThrowsError(try CredentialEnvironment.validate(environment: [name: "value"]), name)
        }
        XCTAssertThrowsError(try CredentialEnvironment.validate(environment: ["API_KEY": "bad\0value"]))
        XCTAssertThrowsError(try CredentialEnvironment.validate(environment: ["API_KEY": ""]))
    }
}
