import SwiftUI

struct InteractionView: View {
    @EnvironmentObject var store: AppStore
    let request: PendingInteraction
    @State private var secret = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(request.title, systemImage: request.kind == .secret ? "lock.shield" : request.kind == .approval ? "hand.raised" : "bubble.left.and.bubble.right").font(.system(size: 15, weight: .medium))
            if !request.detail.isEmpty { Text(request.detail).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled) }
            if request.kind == .secret {
                SecureField("Ключ или пароль", text: $secret).textFieldStyle(.roundedBorder).onSubmit { submitSecret() }.privacySensitive()
                HStack {
                    Button("Сохранить в Keychain") { submitSecret() }.disabled(secret.isEmpty).buttonStyle(.borderedProminent)
                    Button("Отмена") { secret = ""; store.respond(.deny) }
                }
                Text("Значение не попадёт в чат, журнал и контекст модели.").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if request.kind == .approval {
                ViewThatFits(in: .horizontal) {
                    HStack { approvalButtons }
                    VStack(alignment: .leading) { approvalButtons }
                }
            } else {
                FlowOptions(options: request.choices) { store.respond(.text($0)) }
                Text("Или напишите ответ в поле сообщения.").font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Отменить вопрос") { store.respond(.deny) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading).agentCard(cornerRadius: 22)
    }
    @ViewBuilder private var approvalButtons: some View {
        Button("Выполнить") { store.respond(.once) }.buttonStyle(.borderedProminent)
        Button("Для этой задачи") { store.respond(.task) }
        Button("Всегда для этого действия") { store.respond(.always) }
        Button("Отменить") { store.respond(.deny) }
    }
    private func submitSecret() { guard !secret.isEmpty else { return }; let value = secret; secret = ""; store.respond(.text(value)) }
}
struct FlowOptions: View {
    let options: [String]
    let choose: (String) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { ForEach(Array(options.enumerated()), id: \.offset) { _, option in Button(option) { choose(option) }.buttonStyle(.bordered) } }
    }
}
struct PermissionsCard: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Доступ к этому Mac", systemImage: "desktopcomputer").font(.system(size: 16, weight: .medium))
            Text("Выдайте доступ один раз, чтобы агент мог работать с вашими файлами. macOS покажет собственные запросы разрешений.").font(.system(size: 14)).foregroundStyle(.secondary).lineSpacing(3)
            HStack {
                Button("Выбрать папку") { store.chooseFiles(folderOnly: true) }
                Button("Полный доступ к диску") { store.openDiskAccess() }
                Button("Универсальный доступ") { store.requestAccessibility() }
            }.buttonStyle(.bordered)
            HStack {
                Button("Открыть LM Studio / Bionic") { LocalServices.openModelApp() }
                Button("Открыть ComfyUI") { LocalServices.openComfy() }
                Button("Проверить подключение") { Task { await store.boot() } }
            }.buttonStyle(.link).font(.system(size: 12))
            Text("Для управления приложениями macOS запросит Automation при первом соответствующем действии. Права администратора не запрашиваются заранее.").font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(22).frame(maxWidth: .infinity, alignment: .leading).agentCard(cornerRadius: 22)
    }
}
