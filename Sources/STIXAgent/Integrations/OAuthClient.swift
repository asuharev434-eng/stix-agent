import Foundation
import AuthenticationServices
import AppKit
import CryptoKit
import Security

/// Public-client OAuth metadata only. Client secrets and tokens must never enter this file.
struct OAuthConfiguration: Codable, Equatable {
    var authorizationEndpoint: String
    var tokenEndpoint: String
    var clientID: String
    var scopes: [String]
    var redirectURI: String = "stixagent://oauth/callback"
    var resource: String? = nil
    var issuer: String? = nil

    func validate() throws {
        for endpoint in [authorizationEndpoint, tokenEndpoint] {
            guard let url = URL(string: endpoint), url.scheme == "https", let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil, url.fragment == nil, url.query == nil else {
                throw AgentError.message("OAuth требует HTTPS endpoint без query и fragment")
            }
        }
        for endpoint in [resource, issuer].compactMap({ $0 }) {
            guard let url = URL(string: endpoint), url.scheme == "https", let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil, url.fragment == nil, url.query == nil else {
                throw AgentError.message("OAuth resource и issuer требуют HTTPS")
            }
        }
        guard redirectURI == "stixagent://oauth/callback", !clientID.isEmpty, clientID.utf8.count <= 1024,
              !clientID.contains(where: { $0.isNewline || $0 == "\0" }), scopes.count <= 64,
              Set(scopes).count == scopes.count, scopes.allSatisfy({ scope in
                  !scope.isEmpty && scope.utf8.count <= 256 && scope.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) && $0.value != 0x22 && $0.value != 0x5C }
              }) else { throw AgentError.message("Некорректная конфигурация OAuth") }
    }
    static func load(directory: String) throws -> Self {
        let data = try Data(contentsOf: URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("oauth.json"))
        guard data.count <= 32768 else { throw AgentError.message("Конфигурация OAuth слишком велика") }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }
    var fingerprint: String {
        // Include the API-facing metadata in the token binding to prevent refresh-token forwarding after edits.
        var parts = [authorizationEndpoint, tokenEndpoint, clientID, redirectURI, scopes.joined(separator: " ")]
        if resource != nil || issuer != nil { parts += [resource ?? "", issuer ?? ""] }
        let value = parts.joined(separator: "\n")
        return Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString()
    }
}

enum OAuthPKCE {
    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw AgentError.message("Не удалось создать OAuth nonce") }
        return base64URL(Data(bytes))
    }
    static func base64URL(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func challenge(verifier: String) -> String { base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    static func authorizationURL(configuration: OAuthConfiguration, state: String, verifier: String) throws -> URL {
        try configuration.validate()
        guard state.count >= 32, (43...128).contains(verifier.count), verifier.range(of: "^[A-Za-z0-9._~-]+$", options: .regularExpression) != nil else { throw AgentError.message("Некорректный PKCE verifier") }
        var components = URLComponents(string: configuration.authorizationEndpoint)!
        components.queryItems = [
            .init(name: "response_type", value: "code"), .init(name: "client_id", value: configuration.clientID),
            .init(name: "redirect_uri", value: configuration.redirectURI), .init(name: "scope", value: configuration.scopes.joined(separator: " ")),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge(verifier: verifier)), .init(name: "code_challenge_method", value: "S256")
        ]
        if let resource = configuration.resource { components.queryItems?.append(.init(name: "resource", value: resource)) }
        guard let url = components.url else { throw AgentError.message("Некорректный адрес OAuth") }
        return url
    }
    static func code(callback: URL, expectedState: String, configuration: OAuthConfiguration) throws -> String {
        guard let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false),
              parts.scheme == "stixagent", parts.host == "oauth", parts.path == "/callback", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil else { throw AgentError.message("Некорректный OAuth callback") }
        let items = parts.queryItems ?? []
        let issuers = items.filter { $0.name == "iss" }
        guard issuers.count <= 1, issuers.first?.value == nil || issuers.first?.value == configuration.issuer else {
            throw AgentError.message("OAuth issuer не совпадает")
        }
        guard items.filter({ $0.name == "state" }).count == 1, items.first(where: { $0.name == "state" })?.value == expectedState,
              !items.contains(where: { $0.name == "error" }), items.filter({ $0.name == "code" }).count == 1,
              let code = items.first(where: { $0.name == "code" })?.value, !code.isEmpty, code.utf8.count <= 8192 else { throw AgentError.message("OAuth отклонён или state не совпадает") }
        return code
    }
}

private struct OAuthTokens: Codable {
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
    var configurationFingerprint: String
}

@MainActor
final class OAuthClient: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = OAuthClient()
    private var sessions: [UUID: ASWebAuthenticationSession] = [:]
    private var refreshes: [String: Task<String, Error>] = [:]

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApp.keyWindow ?? NSApp.windows.first ?? ASPresentationAnchor()
    }
    func authorize(configuration: OAuthConfiguration, credentialID: String, vault: SecretVault) async throws {
        let verifier = try OAuthPKCE.random(), state = try OAuthPKCE.random()
        let url = try OAuthPKCE.authorizationURL(configuration: configuration, state: state, verifier: verifier)
        let callback = try await authenticate(url: url)
        let code = try OAuthPKCE.code(callback: callback, expectedState: state, configuration: configuration)
        let tokens = try await exchange(configuration: configuration, fields: ["grant_type": "authorization_code", "code": code, "code_verifier": verifier, "redirect_uri": configuration.redirectURI], previousRefresh: nil, vault: vault)
        try save(tokens, credentialID: credentialID, vault: vault)
    }
    private func authenticate(url: URL) async throws -> URL {
        let id = UUID()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "stixagent") { [weak self] callback, _ in
                    Task { @MainActor in
                        self?.sessions.removeValue(forKey: id)
                        if let callback { continuation.resume(returning: callback) }
                        else { continuation.resume(throwing: AgentError.message("Авторизация OAuth отменена")) }
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                sessions[id] = session
                if !session.start() {
                    sessions.removeValue(forKey: id)
                    continuation.resume(throwing: AgentError.message("Не удалось открыть OAuth"))
                }
            }
        }, onCancel: { Task { @MainActor [weak self] in self?.sessions[id]?.cancel() } })
    }
    func accessToken(configuration: OAuthConfiguration, credentialID: String, vault: SecretVault) async throws -> String {
        try configuration.validate()
        let saved = try JSONDecoder().decode(OAuthTokens.self, from: Data(vault.get(credentialID).utf8))
        guard saved.configurationFingerprint == configuration.fingerprint else { throw AgentError.message("Конфигурация OAuth изменилась. Войдите повторно") }
        vault.remember(saved.accessToken)
        if let refresh = saved.refreshToken { vault.remember(refresh) }
        if saved.expiresAt.timeIntervalSinceNow > 60 { return saved.accessToken }
        if let existing = refreshes[credentialID] { return try await existing.value }
        let task = Task { try await self.refresh(configuration: configuration, credentialID: credentialID, vault: vault) }
        refreshes[credentialID] = task
        defer { refreshes.removeValue(forKey: credentialID) }
        return try await task.value
    }
    func refresh(configuration: OAuthConfiguration, credentialID: String, vault: SecretVault) async throws -> String {
        try configuration.validate()
        let saved = try JSONDecoder().decode(OAuthTokens.self, from: Data(vault.get(credentialID).utf8))
        guard saved.configurationFingerprint == configuration.fingerprint, let refresh = saved.refreshToken else { throw AgentError.message("Требуется повторная авторизация OAuth") }
        vault.remember(refresh)
        let tokens = try await exchange(configuration: configuration, fields: ["grant_type": "refresh_token", "refresh_token": refresh], previousRefresh: refresh, vault: vault)
        try save(tokens, credentialID: credentialID, vault: vault)
        return tokens.accessToken
    }
    private func save(_ tokens: OAuthTokens, credentialID: String, vault: SecretVault) throws {
        vault.remember(tokens.accessToken)
        if let refresh = tokens.refreshToken { vault.remember(refresh) }
        try vault.set(String(decoding: JSONEncoder().encode(tokens), as: UTF8.self), for: credentialID)
    }
    private func exchange(configuration: OAuthConfiguration, fields: [String: String], previousRefresh: String?, vault: SecretVault) async throws -> OAuthTokens {
        try configuration.validate()
        func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))! }
        var values = fields; values["client_id"] = configuration.clientID
        if let resource = configuration.resource { values["resource"] = resource }
        var request = URLRequest(url: URL(string: configuration.tokenEndpoint)!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(values.sorted { $0.key < $1.key }.map { "\(encode($0.key))=\(encode($0.value))" }.joined(separator: "&").utf8)
        let settings = URLSessionConfiguration.ephemeral
        settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil; settings.timeoutIntervalForResource = 60
        let session = URLSession(configuration: settings, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw AgentError.message("OAuth token endpoint отклонил запрос") }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 32768 else { throw AgentError.message("Ответ OAuth слишком велик") }
            data.append(byte)
        }
        struct Reply: Decodable { var access_token: String; var refresh_token: String?; var token_type: String; var expires_in: Double? }
        let reply: Reply
        do { reply = try JSONDecoder().decode(Reply.self, from: data) }
        catch { throw AgentError.message("Некорректный ответ OAuth") }
        guard reply.token_type.lowercased() == "bearer", !reply.access_token.isEmpty, reply.access_token.utf8.count <= 8192,
              !reply.access_token.contains(where: { $0.isWhitespace || $0 == "\0" }),
              reply.refresh_token.map({ !$0.isEmpty && $0.utf8.count <= 8192 && !$0.contains("\0") }) ?? true,
              (reply.expires_in ?? 3600).isFinite, (reply.expires_in ?? 3600) > 0 else { throw AgentError.message("Некорректный OAuth token") }
        vault.remember(reply.access_token)
        if let refresh = reply.refresh_token { vault.remember(refresh) }
        return OAuthTokens(accessToken: reply.access_token, refreshToken: reply.refresh_token ?? previousRefresh, expiresAt: Date().addingTimeInterval(min(reply.expires_in ?? 3600, 31_536_000)), configurationFingerprint: configuration.fingerprint)
    }
}
