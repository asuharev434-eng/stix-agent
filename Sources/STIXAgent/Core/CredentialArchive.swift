import Foundation
import CryptoKit
import CommonCrypto

/// Separate, password-encrypted transfer. Never part of ordinary data snapshots.
enum CredentialArchive {
    private struct Envelope: Codable { var version = 1; var salt: Data; var rounds: Int; var ciphertext: Data }
    static func seal(_ credentials: [String:String], password: String) throws -> Data {
        guard password.count >= 12, password.utf8.count <= 1024, credentials.count <= 1000 else { throw AgentError.message("Пароль архива: от 12 символов; максимум 1000 ключей") }
        let salt = Data((0..<32).map { _ in UInt8.random(in: 0...255) }), rounds = 600_000
        let key = try derive(password, salt: salt, rounds: rounds)
        let data = try StoreFiles.encode(credentials)
        guard data.count <= 4_000_000 else { throw AgentError.message("Архив ключей слишком большой") }
        let box = try AES.GCM.seal(data, using: key, authenticating: Data("STIX credentials v1".utf8))
        guard let combined = box.combined else { throw AgentError.message("Не удалось зашифровать ключи") }
        return try StoreFiles.encode(Envelope(salt: salt, rounds: rounds, ciphertext: combined))
    }
    static func open(_ data: Data, password: String) throws -> [String:String] {
        guard data.count <= 6_000_000, password.utf8.count <= 1024 else { throw AgentError.message("Недопустимый архив ключей") }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1, envelope.salt.count == 32, envelope.rounds == 600_000 else { throw AgentError.message("Неизвестный формат архива ключей") }
            let bytes = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.ciphertext), using: derive(password, salt: envelope.salt, rounds: envelope.rounds), authenticating: Data("STIX credentials v1".utf8))
            let result = try JSONDecoder().decode([String:String].self, from: bytes)
            guard result.count <= 1000, result.keys.allSatisfy({ !$0.isEmpty && $0.count <= 200 }) else { throw AgentError.message("Недопустимый архив ключей") }
            return result
        } catch { throw AgentError.message("Архив повреждён или пароль неверен") }
    }
    private static func derive(_ password: String, salt: Data, rounds: Int) throws -> SymmetricKey {
        let secret = Array(password.utf8), bytes = Array(salt)
        var key = [UInt8](repeating: 0, count: 32)
        let status = secret.withUnsafeBytes { secret in bytes.withUnsafeBytes { salt in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), secret.baseAddress?.assumingMemoryBound(to: Int8.self), secret.count, salt.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds), &key, key.count)
        } }
        guard status == kCCSuccess else { throw AgentError.message("Не удалось вывести ключ шифрования") }
        return SymmetricKey(data: key)
    }
}
