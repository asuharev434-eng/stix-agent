import Foundation

/// Only models initially unloaded when this application requested them are owned.
/// Preloaded models (including Bionic's own selection) and remote servers are never
/// unloaded. No process termination or undocumented compatibility API is used.
actor ModelResidency {
    static let shared = ModelResidency()
    private var candidates: [String: Set<String>] = [:]
    private var unavailableUntil: [String: Date] = [:]

    func prepare(client: LMStudioClient, model: String) async throws -> Int? {
        guard (try? ModelOrchestrator.validateEndpoint(client.endpoint)) != nil else { return nil }
        if let until = unavailableUntil[client.endpoint], until > Date() { return nil }
        let snapshot: JSONValue
        do { snapshot = try await client.nativeModelSnapshot() }
        catch {
            if Task.isCancelled { throw CancellationError() }
            unavailableUntil[client.endpoint] = Date().addingTimeInterval(60)
            return nil
        }
        guard let models = snapshot["models"].array else { return nil }
        var owned = candidates[client.endpoint] ?? []
        for previous in owned where previous != model {
            guard let item = models.first(where: { $0["key"].string == previous }) else { continue }
            if (item["loaded_instances"].array ?? []).contains(where: { $0["id"].string == model }) { continue }
            for id in Self.instancesToRelease(item, requestedModel: model, ownedKeys: owned) {
                do { try await client.unloadNativeInstance(id) }
                catch {
                    if Task.isCancelled { throw CancellationError() }
                    // A supported API rejecting unload must be visible: loading another
                    // large model despite failure could exhaust unified memory.
                    throw AgentError.message("Не удалось освободить предыдущую модель через локальный API: \(error.localizedDescription)")
                }
            }
            owned.remove(previous)
        }
        if let item = models.first(where: { $0["key"].string == model }), item["loaded_instances"].array?.isEmpty == true { owned.insert(model) }
        candidates[client.endpoint] = owned
        let selected = models.first { $0["key"].string == model || ($0["loaded_instances"].array ?? []).contains(where: { $0["id"].string == model }) }
        return (selected?["loaded_instances"].array ?? []).compactMap { $0["config"]["context_length"].int }.filter { $0 > 0 }.min()
    }

    static func instancesToRelease(_ item: JSONValue, requestedModel: String, ownedKeys: Set<String>) -> [String] {
        guard let key = item["key"].string, key != requestedModel, ownedKeys.contains(key), item["type"].string == "llm" else { return [] }
        return (item["loaded_instances"].array ?? []).compactMap { $0["id"].string }.filter { !$0.isEmpty && $0 != requestedModel }
    }
}
