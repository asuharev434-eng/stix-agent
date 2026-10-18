import Foundation

/// Conservative review hints, never automatic fact replacement. Only explicit
/// key:value facts in the same scope/owner/category are compared.
enum MemoryReview {
    static func notes(_ entries: [MemoryEntry]) -> [UUID: String] {
        var groups: [String: [(MemoryEntry, String)]] = [:]
        for entry in entries where entry.enabled {
            guard let colon = entry.text.firstIndex(of: ":") else { continue }
            let key = entry.text[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = entry.text[entry.text.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard (3...80).contains(key.count), !key.contains("\n"), !value.isEmpty else { continue }
            let group = entry.scope.rawValue + ":" + (entry.ownerID?.uuidString ?? "personal") + ":" + entry.category.rawValue + ":" + key
            groups[group, default: []].append((entry,value))
        }
        var result: [UUID:String] = [:]
        for values in groups.values where Set(values.map { $0.1 }).count > 1 {
            for (entry,value) in values {
                let others = values.filter { $0.1 != value }.prefix(3).map { "\($0.0.id): \($0.0.source)" }.joined(separator: "; ")
                result[entry.id] = "Возможное расхождение фактов. Сравните с: " + others
            }
        }
        return result
    }
}
