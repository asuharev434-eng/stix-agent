import SwiftUI

struct ContextWindowControl: View {
    @EnvironmentObject var store: AppStore
    @State private var expanded = false
    private var window: ContextWindow? { store.selectedID.flatMap { store.contextWindow(chatID: $0, includeDraft: true) } }
    private var compacting: Bool { store.compactingChatID == store.selectedID && store.compactingChatID != nil }
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
            .popover(isPresented: $expanded, arrowEdge: .top) { details.padding(20).frame(width: 340) }
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
            if let checkpoint = store.currentChat?.contextCheckpoint, checkpoint.matches(store.currentChat?.history ?? []) {
                Label("Сжатий: \(checkpoint.revision) · \(checkpoint.createdAt.formatted(date: .omitted, time: .shortened))", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Автоматическое сжатие — при заполнении 75%. Задача, последние шаги и полная переписка сохраняются.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if compacting {
                HStack { ProgressView().controlSize(.small); Text(store.activity).font(.caption) }
            } else if let notice = store.selectedID.flatMap({ store.contextNotices[$0] }) {
                Text(notice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button {
                if let id = store.selectedID { store.requestContextCompaction(chatID: id) }
            } label: {
                Label(compacting ? "Сжимаю…" : "Сжать сейчас", systemImage: "arrow.down.right.and.arrow.up.left").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered).disabled(store.busy || store.currentChat?.model.isEmpty != false || store.currentChat.flatMap { ContextCompaction.plan(history: $0.history, checkpoint: $0.contextCheckpoint) } == nil)
        }
    }
    private func row(_ title: String, value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }.font(.callout)
    }
    private func number(_ value: Int) -> String { value.formatted(.number.grouping(.automatic)) }
}
