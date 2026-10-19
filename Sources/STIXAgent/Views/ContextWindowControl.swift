import SwiftUI

struct ContextWindowControl: View {
    @EnvironmentObject var store: AppStore
    @State private var expanded = false
    private var window: ContextWindow? { store.selectedID.flatMap { store.contextWindow(chatID: $0, includeDraft: true) } }
    private var compacting: Bool { store.compactingChatID == store.selectedID && store.compactingChatID != nil }
    private var queued: Bool { store.pendingCompactionChatID == store.selectedID && store.pendingCompactionChatID != nil }
    private var tint: Color { (window?.fraction ?? 0) >= 0.9 ? .orange : .secondary }
    var body: some View {
        Button { expanded.toggle() } label: {
            ZStack {
                Circle().stroke(.primary.opacity(0.09), lineWidth: 2.5)
                if compacting { ProgressView().controlSize(.mini) }
                else {
                    Circle().trim(from: 0, to: window?.fraction ?? 0).stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round)).rotationEffect(.degrees(-90))
                    Text("\(window?.percentage ?? 0)").font(.system(size: 9, weight: .medium, design: .rounded)).monospacedDigit()
                }
            }.frame(width: 29, height: 29).padding(3).contentShape(Circle())
        }.buttonStyle(.plain)
            .accessibilityLabel("Контекстное окно")
            .accessibilityValue(compacting ? "Сжатие контекста" : "Примерно \(window?.percentage ?? 0) процентов, включая резерв ответа")
            .help("Контекстное окно · ≈\(window?.percentage ?? 0)% с учётом резерва ответа")
            .popover(isPresented: $expanded, arrowEdge: .top) { ScrollView { details.padding(20) }.frame(width: 430, height: 580) }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Контекстное окно").font(.headline)
                Spacer()
                Text("≈\(window?.percentage ?? 0)%").font(.headline).monospacedDigit()
            }
            if let window {
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.accentColor).frame(width: geometry.size.width * min(1, Double(window.inputTokens) / Double(window.limit)))
                        Rectangle().fill(Color.primary.opacity(0.18)).frame(width: geometry.size.width * min(1 - min(1, Double(window.inputTokens) / Double(window.limit)), Double(window.reserveTokens) / Double(window.limit)))
                        Spacer(minLength: 0)
                    }.background(.primary.opacity(0.05)).clipShape(Capsule())
                }.frame(height: 7)
                row("Окно модели", value: "\(window.knownLimit ? "" : "до ")\(number(window.limit))")
                row("Инструкции и инструменты", value: "≈" + number(window.systemTokens + window.toolTokens))
                row("Переписка и вложения", value: "≈" + number(window.historyTokens))
                row("Резерв ответа", value: number(window.reserveTokens))
                row("Свободно", value: "≈" + number(window.remainingTokens))
                Text(window.knownLimit ? "Лимит загруженной модели получен от локального API. Число токенов приблизительное, с запасом." : "Размер окна пока взят из метаданных модели или оценён в 32K. После загрузки уточняется через локальный API. Число токенов приблизительное.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            if let id = store.selectedID, let snapshot = store.requestSnapshots[id] {
                Text("Последний запрос: " + snapshot.model).font(.subheadline.weight(.medium))
                Text(snapshot.createdAt.formatted(date: .omitted, time: .standard) + " · сообщений: \(snapshot.messageCount)").font(.caption).foregroundStyle(.secondary)
                contextSection("Инструкции", text: snapshot.instructions)
                contextSection("Подключённая память", text: snapshot.memory)
                contextSection("Инструменты", text: snapshot.tools)
                contextSection("Резюме контекста", text: snapshot.summary.isEmpty ? "Резюме не использовалось" : snapshot.summary)
                contextSection("Сообщения и результаты", text: snapshot.transcript)
                Text("Это окончательно сформированный запрос основной модели в текущем запуске приложения; доставка и успешный ответ зависят от локального сервера. Оценка окна выше отражает текущее состояние и черновик; она может отличаться от этого запроса.").font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("После следующего ответа здесь появится фактический состав запроса основной модели. Снимок хранится только до закрытия приложения.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            if let checkpoint = store.currentChat?.contextCheckpoint, checkpoint.matches(store.currentChat?.history ?? []) {
                Label("Сжатий: \(checkpoint.revision) · \(checkpoint.createdAt.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if store.currentChat?.isClean == true {
                Text("Чистый чат: системные инструкции, память, инструменты и сжатие отключены. При создании контекст равен нулю; затем он содержит только сообщения этого чата.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Автоматическое сжатие старой переписки — при заполнении 75%. Задача, последние шаги и полная переписка сохраняются. Инструкции и инструменты сжатию не подлежат.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if compacting {
                    HStack { ProgressView().controlSize(.small); Text(store.activity).font(.caption) }
                } else if let notice = store.selectedID.flatMap({ store.contextNotices[$0] }) {
                    Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Button {
                    if let id = store.selectedID { store.requestContextCompaction(chatID: id) }
                } label: {
                    Label(compacting ? "Сжимаю…" : queued ? "Сжатие в очереди" : store.busy ? "Сжать после задачи" : "Сжать сейчас", systemImage: "arrow.down.right.and.arrow.up.left").frame(maxWidth: .infinity)
                }.buttonStyle(.bordered).disabled(compacting || queued || !store.canPersist || store.currentChat == nil)
            }
        }
    }
    private func contextSection(_ title: String, text: String) -> some View {
        DisclosureGroup(title) {
            ScrollView { Text(text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 220)
        }.font(.callout)
    }
    private func row(_ title: String, value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }.font(.callout)
    }
    private func number(_ value: Int) -> String { value.formatted(.number.grouping(.automatic)) }
}
