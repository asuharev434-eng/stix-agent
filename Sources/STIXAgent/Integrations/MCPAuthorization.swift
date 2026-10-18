import Foundation

struct MCPProtectedResource: Decodable {
    let resource: String
    let authorizationServers: [String]
    let scopesSupported: [String]?
    enum CodingKeys: String, CodingKey {
        case resource
        case authorizationServers = "authorization_servers"
        case scopesSupported = "scopes_supported"
    }
}

struct MCPAuthorizationServer: Decodable {
    let issuer: String
    let authorizationEndpoint: String
    let tokenEndpoint: String
    let registrationEndpoint: String?
    let scopesSupported: [String]?
    let codeChallengeMethodsSupported: [String]?
    let tokenEndpointAuthMethodsSupported: [String]?
    enum CodingKeys: String, CodingKey {
        case issuer
        case authorizationEndpoint = "authorization_endpoint"
        case tokenEndpoint = "token_endpoint"
        case registrationEndpoint = "registration_endpoint"
        case scopesSupported = "scopes_supported"
        case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        case tokenEndpointAuthMethodsSupported = "token_endpoint_auth_methods_supported"
    }
}

struct MCPDiscoveryResult {
    let resource: MCPProtectedResource
    let server: MCPAuthorizationServer
    let requiredScopes: [String]
    var availableScopes: [String] { Array(NSOrderedSet(array: requiredScopes + (resource.scopesSupported ?? server.scopesSupported ?? []))) as? [String] ?? requiredScopes }
    var suggestedScopes: [String] {
        if !requiredScopes.isEmpty { return requiredScopes }
        return availableScopes.filter { $0 == "read" || $0.hasSuffix(":read") }
    }
}

enum MCPAuthorization {
    static func secureURL(_ value: String) throws -> URL {
        guard let url = URL(string: value), url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw AgentError.message("MCP OAuth требует HTTPS без учётных данных в адресе")
        }
        return url
    }
    static func challenge(_ header: String?) -> (metadata: String?, scopes: [String]) {
        guard let header, header.utf8.count <= 8192, header.range(of: #"^Bearer(?:\s|$)"#, options: [.regularExpression, .caseInsensitive]) != nil else { return (nil, []) }
        func field(_ key: String) -> String? {
            let pattern = #"(?:^|[,\s])"# + NSRegularExpression.escapedPattern(for: key) + #"\s*=\s*"([^"\r\n]*)""#
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = expression.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
                  let range = Range(match.range(at: 1), in: header) else { return nil }
            return String(header[range])
        }
        return (field("resource_metadata"), field("scope")?.split(separator: " ").map(String.init) ?? [])
    }
    static func resourceMetadataURLs(endpoint: URL, challengeURL: String?) -> [URL] {
        var urls: [URL] = []
        if let challengeURL, let url = try? secureURL(challengeURL) { urls.append(url) }
        var base = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let path = base.percentEncodedPath
        base.percentEncodedPath = "/.well-known/oauth-protected-resource" + (path == "/" ? "" : path)
        if let url = base.url { urls.append(url) }
        base.percentEncodedPath = "/.well-known/oauth-protected-resource"
        if let url = base.url { urls.append(url) }
        return Array(NSOrderedSet(array: urls)) as? [URL] ?? urls
    }
    static func authorizationMetadataURLs(issuer: URL) -> [URL] {
        var parts = URLComponents(url: issuer, resolvingAgainstBaseURL: false)!
        let path = parts.percentEncodedPath == "/" ? "" : parts.percentEncodedPath
        parts.percentEncodedPath = "/.well-known/oauth-authorization-server" + path
        let oauth = parts.url!
        parts.percentEncodedPath = "/.well-known/openid-configuration" + path
        let oidcInserted = parts.url!
        parts.percentEncodedPath = path + "/.well-known/openid-configuration"
        return [oauth, oidcInserted, parts.url!]
    }
}

/// Discovery is read-only. Registration is a separate explicit step after the user chooses scopes.
struct MCPAuthorizationDiscovery {
    let session: URLSession
    init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let settings = URLSessionConfiguration.ephemeral
            settings.httpCookieStorage = nil; settings.urlCredentialStorage = nil
            settings.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: settings, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
    }
    func discover(endpoint: String) async throws -> MCPDiscoveryResult {
        let url = try MCPAuthorization.secureURL(endpoint)
        var probe = URLRequest(url: url, timeoutInterval: 20)
        probe.httpMethod = "POST"
        probe.setValue("application/json", forHTTPHeaderField: "Content-Type")
        probe.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        probe.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"STIX Agent","version":"1.0"}}}"#.utf8)
        let (_, probeResponse) = try await fetch(probe)
        let challenge = MCPAuthorization.challenge(probeResponse.value(forHTTPHeaderField: "WWW-Authenticate"))
        var resource: MCPProtectedResource?
        for metadataURL in MCPAuthorization.resourceMetadataURLs(endpoint: url, challengeURL: challenge.metadata) {
            do {
                let (data, response) = try await fetch(URLRequest(url: metadataURL, timeoutInterval: 20))
                guard (200..<300).contains(response.statusCode) else { continue }
                let value = try JSONDecoder().decode(MCPProtectedResource.self, from: data)
                guard value.resource == url.absoluteString, !value.authorizationServers.isEmpty, value.authorizationServers.count <= 8 else { continue }
                resource = value; break
            } catch { continue }
        }
        guard let resource else { throw AgentError.message("MCP не предоставил подходящие OAuth resource metadata") }
        for issuerName in resource.authorizationServers {
            guard let issuerURL = try? MCPAuthorization.secureURL(issuerName) else { continue }
            for metadataURL in MCPAuthorization.authorizationMetadataURLs(issuer: issuerURL) {
                do {
                    let (data, response) = try await fetch(URLRequest(url: metadataURL, timeoutInterval: 20))
                    guard (200..<300).contains(response.statusCode) else { continue }
                    let server = try JSONDecoder().decode(MCPAuthorizationServer.self, from: data)
                    guard server.issuer == issuerName,
                          (try? MCPAuthorization.secureURL(server.authorizationEndpoint)) != nil,
                          (try? MCPAuthorization.secureURL(server.tokenEndpoint)) != nil,
                          server.codeChallengeMethodsSupported?.contains("S256") == true,
                          server.tokenEndpointAuthMethodsSupported?.contains("none") != false else { continue }
                    return .init(resource: resource, server: server, requiredScopes: challenge.scopes)
                } catch { continue }
            }
        }
        throw AgentError.message("MCP OAuth metadata недоступны или не поддерживают PKCE S256")
    }
    func register(server: MCPAuthorizationServer) async throws -> String {
        guard let endpoint = server.registrationEndpoint else { throw AgentError.message("Сервер требует заранее зарегистрированный client ID") }
        let url = try MCPAuthorization.secureURL(endpoint)
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "STIX Agent",
            "redirect_uris": ["stixagent://oauth/callback"],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none"
        ])
        let (data, response) = try await fetch(request)
        guard (200..<300).contains(response.statusCode) else { throw AgentError.message("MCP OAuth отказал в регистрации клиента") }
        struct Reply: Decodable { let client_id: String; let token_endpoint_auth_method: String? }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        guard !reply.client_id.isEmpty, reply.client_id.utf8.count <= 1024,
              reply.token_endpoint_auth_method == nil || reply.token_endpoint_auth_method == "none" else {
            throw AgentError.message("Некорректная регистрация MCP OAuth")
        }
        return reply.client_id
    }
    private func fetch(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.url == request.url, !(300..<400).contains(http.statusCode) else {
            throw AgentError.message("MCP OAuth: перенаправление или некорректный ответ")
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 65_536 else { throw AgentError.message("MCP OAuth metadata слишком велики") }
            data.append(byte)
        }
        return (data, http)
    }
}
