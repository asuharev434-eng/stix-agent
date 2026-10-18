import Foundation

/// An immutable local audit trail. Restoring creates another revision rather than rewriting history.
struct MemoryRevision: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var createdAt = Date()
    var before: MemoryEntry?
    var after: MemoryEntry?
    var action: String
    var entry: MemoryEntry? { after ?? before }

    func validated() throws {
        guard before != nil || after != nil, before?.id == after?.id || before == nil || after == nil,
              before?.scope == after?.scope || before == nil || after == nil,
              before?.ownerID == after?.ownerID || before == nil || after == nil else {
            throw AgentError.message("Повреждена версия памяти")
        }
        try before?.validated(); try after?.validated()
    }
}
