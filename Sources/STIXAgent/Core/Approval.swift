import Foundation
import CryptoKit

struct ApprovalPolicy {
    static func pluginToolName(pluginID: String, name: String) -> String {
        let digest = SHA256.hash(data: Data((pluginID + ":" + name).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "mcp_" + digest
    }
    static func scope(tool: String, arguments: JSONValue) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(arguments)) ?? Data()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return "\(tool):\(digest)"
    }
    static func validateEndpoint(_ raw: String, localOnly: Bool = false) throws -> URL {
        guard let url = URL(string: raw), let scheme = url.scheme, let host = url.host,
              ["http", "https"].contains(scheme), url.user == nil, url.password == nil,
              url.fragment == nil, url.query == nil else { throw AgentError.message("Укажите HTTP(S) URL без ключей и паролей") }
        if localOnly && !["127.0.0.1", "localhost", "::1"].contains(host) { throw AgentError.message("Локальный сервис должен использовать localhost") }
        if scheme == "http" && !["127.0.0.1", "localhost", "::1"].contains(host) { throw AgentError.message("Для внешнего сервиса требуется HTTPS") }
        return url
    }
}
