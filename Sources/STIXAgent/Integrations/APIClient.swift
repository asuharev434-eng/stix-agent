import Foundation

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
struct APIClient {
    let vault: SecretVault
    static func requestURL(baseURL: String, path: String) throws -> URL {
        let base = try ApprovalPolicy.validateEndpoint(baseURL)
        guard !path.contains("://"), !path.hasPrefix("//"), !path.contains("\\"), !path.contains("#"),
              let url = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
              url.scheme == base.scheme, url.host == base.host, url.port == base.port,
              url.user == nil, url.password == nil else { throw AgentError.message("Запрос разрешён только к адресу подключения") }
        let rootPath = base.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !rootPath.isEmpty {
            let target = url.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            guard target == rootPath || target.hasPrefix(rootPath + "/") else { throw AgentError.message("Путь выходит за пределы API") }
        }
        return url
    }
    func request(connection: APIConnection, path: String, method: String, body: String?) async throws -> String {
        let url = try Self.requestURL(baseURL: connection.baseURL, path: path)
        guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"].contains(method) else { throw AgentError.message("Недопустимый HTTP-метод") }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body, !body.isEmpty {
            guard body.utf8.count <= 1_000_000 else { throw AgentError.message("Тело запроса превышает 1 МБ") }
            _ = try JSONValue.parse(body)
            request.httpBody = Data(body.utf8); request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if connection.auth != "none" {
            let key = try vault.get(connection.id)
            guard !key.contains("\n"), !key.contains("\r") else { throw AgentError.message("Ключ содержит недопустимый перенос строки") }
            switch connection.auth {
            case "bearer": request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            case "basic":
                if let colon = key.firstIndex(of: ":") { vault.remember(String(key[key.index(after: colon)...])) }
                request.setValue("Basic \(Data(key.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
            case "header": request.setValue(key, forHTTPHeaderField: connection.headerName)
            default: throw AgentError.message("Неподдерживаемая авторизация")
            }
        }
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.timeoutIntervalForResource = 90
        let session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_000_000 else { throw AgentError.message("Ответ API превышает 1 МБ") }
            data.append(byte)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? "[двоичный ответ: \(data.count) байт]"
        return vault.redact("HTTP \(status)\n\(String(text.prefix(50000)))")
    }
}
