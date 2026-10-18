import Foundation
import Security

final class SecretVault: @unchecked Sendable {
    private let service = "studio.stix.agent.credentials"
    private let lock = NSLock()
    private var knownValues: [String] = []
    func set(_ value: String, for id: String) throws {
        guard !value.isEmpty, value.utf8.count <= 16384 else { throw AgentError.message("Секрет должен содержать от 1 до 16384 байт") }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id]
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let result = SecItemAdd(insert as CFDictionary, nil)
            guard result == errSecSuccess else { throw AgentError.message("Keychain: \(result)") }
        } else if status != errSecSuccess { throw AgentError.message("Keychain: \(status)") }
        remember(value)
    }
    func get(_ id: String) throws -> String {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw AgentError.message("Секрет недоступен в Keychain (\(status))") }
        remember(value); return value
    }
    func remove(_ id: String) throws {
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: id] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AgentError.message("Keychain: \(status)") }
    }
    func remember(_ value: String) {
        guard !value.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        if !knownValues.contains(value) { knownValues.append(value) }
    }
    private func representations(of value: String) -> [String] {
        let escaped = (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? value
        return [value, escaped, Data(value.utf8).base64EncodedString(), value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? value]
    }
    func redactStreaming(_ text: String) -> String {
        lock.lock(); let values = knownValues; lock.unlock()
        var visible = text
        for value in values {
            let variants = representations(of: value)
            for candidate in variants where !candidate.isEmpty {
                let maximum = min(candidate.count - 1, visible.count)
                if maximum > 0 {
                    for length in stride(from: maximum, through: 1, by: -1) where visible.hasSuffix(candidate.prefix(length)) {
                        visible = String(visible.dropLast(length)); break
                    }
                }
            }
        }
        // A potential credential prefix is held until the final, fully redacted reply.
        if let range = visible.range(of: #"\bsk-(?:proj-)?[A-Za-z0-9_-]*$"#, options: .regularExpression) { visible.removeSubrange(range) }
        return redact(visible)
    }
    func redact(_ text: String) -> String {
        lock.lock(); let values = knownValues.sorted { $0.count > $1.count }; lock.unlock()
        var result = text
        for value in values {
            for representation in representations(of: value) {
                result = result.replacingOccurrences(of: representation, with: "[секрет скрыт]")
            }
        }
        // Mask common accidentally pasted credentials even before they enter Keychain.
        for pattern in [#"\bsk-(?:proj-)?[A-Za-z0-9_-]{16,}"#, #"(?i)(authorization\s*[:=]\s*(?:bearer|basic)\s+)[^\s\"']+"#] {
            result = result.replacingOccurrences(of: pattern, with: "[секрет скрыт]", options: .regularExpression)
        }
        return result
    }
}
