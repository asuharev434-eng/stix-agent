import SwiftUI

struct PluginsCard: View {
    @EnvironmentObject private var store: AppStore
    let chatID: UUID
    var initialURL: String = ""
    @State private var name = ""
    @State private var endpoint = ""
    @State private var clientID = ""
    @State private var discovery: MCPDiscoveryResult?
    @State private var scopes = Set<String>()
    @State private var reconnectID: String?
    @State private var working = false
    @State private var notice = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("MCP-плагины", systemImage: "puzzlepiece.extension").font(.headline)
            Text("Добавьте адрес MCP. Права выбираются здесь, вход откроется в системном окне. Токены хранятся только в Keychain.")
                .font(.subheadline).foregroundStyle(.secondary)
            ForEach(store.preferences.plugins) { plugin in
                HStack(spacing: 10) {
                    Image(systemName: plugin.enabled ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(plugin.enabled ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(plugin.name).fontWeight(.medium)
                        Text(plugin.transport == "http" ? plugin.url : plugin.command)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled)
                    }
                    Spacer()
                    if let oauth = plugin.oauth {
                        Button("Войти снова") {
                            reconnectID = plugin.id; name = plugin.name; endpoint = plugin.url
                            clientID = oauth.clientID; discovery = nil; scopes = Set(oauth.scopes)
                        }.disabled(working)
                    }
                    Button(plugin.enabled ? "Отключить" : "Включить") {
                        Task { await change(plugin, action: plugin.enabled ? "disable" : "enable") }
                    }.disabled(working)
                    Button(role: .destructive) { Task { await change(plugin, action: "remove") } } label: {
                        Image(systemName: "trash")
                    }.disabled(working).help("Удалить плагин и его OAuth токены")
                }.buttonStyle(.borderless).padding(12).agentCard(cornerRadius: 14)
            }
            Divider()
            Text(reconnectID == nil ? "Подключить MCP с OAuth" : "Переподключить MCP").font(.subheadline.weight(.semibold))
            TextField("Название, например STIX", text: $name)
            TextField("https://example.com/mcp", text: $endpoint)
                .textContentType(.URL).autocorrectionDisabled()
                .onChange(of: endpoint) { _, _ in discovery = nil }
            HStack {
                Button("Найти параметры OAuth") { Task { await discover() } }
                    .disabled(working || endpoint.isEmpty)
                if working { ProgressView().controlSize(.small) }
            }
            if let discovery {
                Text("Авторизация: \(discovery.server.issuer)").font(.caption).textSelection(.enabled)
                Text("Окно входа: \(discovery.server.authorizationEndpoint)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Обмен токена: \(discovery.server.tokenEndpoint)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Выберите права для этого подключения:").font(.subheadline)
                if discovery.availableScopes.isEmpty { Text("Сервер не объявил дополнительные права").foregroundStyle(.secondary) }
                ForEach(discovery.availableScopes, id: \.self) { scope in
                    Toggle(scope, isOn: Binding(get: { scopes.contains(scope) }, set: { value in
                        if value { scopes.insert(scope) } else if !discovery.requiredScopes.contains(scope) { scopes.remove(scope) }
                    }))
                    .disabled(discovery.requiredScopes.contains(scope))
                }
                TextField("Client ID (если выдан заранее; иначе создадим автоматически)", text: $clientID)
                    .autocorrectionDisabled()
                Button(reconnectID == nil ? "Подключить через OAuth" : "Войти и обновить подключение") {
                    Task { await connect(discovery) }
                }.buttonStyle(.borderedProminent).disabled(working)
            }
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20).agentCard(cornerRadius: 22)
        .onAppear {
            if endpoint.isEmpty, !initialURL.isEmpty {
                endpoint = initialURL
                Task { await discover() }
            }
        }
    }
    private func discover() async {
        working = true; defer { working = false }
        do {
            let result = try await MCPAuthorizationDiscovery().discover(endpoint: endpoint.trimmingCharacters(in: .whitespacesAndNewlines))
            discovery = result
            scopes = Set(result.suggestedScopes).union(scopes.intersection(result.availableScopes))
            notice = "Параметры найдены. Проверьте права перед входом."
        } catch { notice = store.vault.redact(error.localizedDescription); discovery = nil }
    }
    private func connect(_ result: MCPDiscoveryResult) async {
        working = true; defer { working = false }
        do {
            let selected = result.availableScopes.filter { scopes.contains($0) }
            guard Set(result.requiredScopes).isSubset(of: Set(selected)) else { throw AgentError.message("Не выбраны обязательные права") }
            let id = reconnectID ?? String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12))
            let registeredID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
            let client = registeredID.isEmpty ? try await MCPAuthorizationDiscovery().register(server: result.server) : registeredID
            var oauth = OAuthConfiguration(authorizationEndpoint: result.server.authorizationEndpoint,
                                           tokenEndpoint: result.server.tokenEndpoint, clientID: client, scopes: selected)
            oauth.resource = result.resource.resource; oauth.issuer = result.server.issuer
            try oauth.validate()
            let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty, displayName.utf8.count <= 120 else { throw AgentError.message("Укажите короткое название плагина") }
            let config = PluginConfig(id: id, name: displayName, transport: "http", command: "", arguments: [],
                                      url: result.resource.resource, enabled: true, oauth: oauth)
            let credentialKey = "mcp-oauth:" + id
            let previousCredential = try? store.vault.get(credentialKey)
            do {
                try await OAuthClient.shared.authorize(configuration: oauth, credentialID: credentialKey, vault: store.vault)
                try await store.activatePlugin(config)
            } catch {
                if let previousCredential { try? store.vault.set(previousCredential, for: credentialKey) }
                else { try? store.vault.remove(credentialKey) }
                throw error
            }
            if let index = store.preferences.plugins.firstIndex(where: { $0.id == id }) { store.preferences.plugins[index] = config }
            else { store.preferences.plugins.append(config) }
            store.save()
            _ = store.recordHumanActionRequest("MCP подключён: \(displayName)", chatID: chatID)
            store.recordHumanActionResult("Доступно инструментов: \(store.pluginTools[id]?.count ?? 0)", chatID: chatID)
            notice = "Подключено: \(displayName) · \(store.pluginTools[id]?.count ?? 0) инструментов"
            reconnectID = nil; discovery = nil; clientID = ""
        } catch { notice = store.vault.redact(error.localizedDescription) }
    }
    private func change(_ plugin: PluginConfig, action: String) async {
        working = true; defer { working = false }
        do {
            if action == "enable" {
                try await store.activatePlugin(plugin)
                if let index = store.preferences.plugins.firstIndex(where: { $0.id == plugin.id }) { store.preferences.plugins[index].enabled = true }
            } else {
                if action == "remove", plugin.oauth != nil { try store.vault.remove("mcp-oauth:" + plugin.id) }
                if let client = store.plugins.removeValue(forKey: plugin.id) { await client.close() }
                store.pluginTools.removeValue(forKey: plugin.id)
                if let index = store.preferences.plugins.firstIndex(where: { $0.id == plugin.id }) {
                    if action == "remove" {
                        store.preferences.plugins.remove(at: index)
                    } else { store.preferences.plugins[index].enabled = false }
                }
            }
            store.save()
            notice = action == "remove" ? "Плагин удалён" : action == "disable" ? "Плагин отключён" : "Плагин включён"
        } catch { notice = store.vault.redact(error.localizedDescription) }
    }
}
