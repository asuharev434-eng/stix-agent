import SwiftUI

struct TaskQueueView: View {
    @EnvironmentObject var store: AppStore
    @State private var editingJob: AgentJob?
    @State private var editedPrompt = ""

    private var jobs: [AgentJob] {
        let current = store.jobs.filter { $0.chatID == store.selectedID && $0.hidden != true }
        let active = current.filter { ["queued", "running", "paused", "interrupted"].contains($0.status) }
        let recent = current.filter { !["queued", "running", "paused", "interrupted"].contains($0.status) }.suffix(2)
        return active + recent
    }
    private var collapsed: Bool { store.currentChat?.tasksCollapsed == true }
    private var runningJob: AgentJob? { jobs.first { $0.status == "running" } }
    private var queuedIDs: [UUID] { jobs.filter { $0.status == "queued" }.map(\.id) }

    var body: some View {
        if !jobs.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 6) {
                    Button { if let id = store.selectedID { store.toggleTaskPanel(chatID: id) } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            Text("Задачи")
                            Text("\(jobs.count)").foregroundStyle(.tertiary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(collapsed ? "Развернуть задачи" : "Свернуть задачи")
                    if !queuedIDs.isEmpty { Text("\(queuedIDs.count) в очереди").foregroundStyle(.tertiary) }
                    Spacer()
                    if jobs.contains(where: { ["done", "cancelled", "failed"].contains($0.status) }) {
                        Button { if let id = store.selectedID { store.dismissCompletedTasks(chatID: id) } } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless).help("Убрать завершённые карточки; история сохранится")
                            .accessibilityLabel("Закрыть завершённые задачи")
                    }
                }.font(.system(size: store.textSize(11), weight: .medium)).foregroundStyle(.secondary)
                if collapsed, let job = runningJob {
                    HStack(spacing: 9) {
                        if let progress = job.progress { ProgressView(value: progress).frame(width: 80) }
                        else { ProgressView().controlSize(.mini) }
                        Text(job.phase ?? "Выполняется").lineLimit(1).font(.system(size: store.textSize(11))).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                }
                if !collapsed {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(jobs) { job in
                            TaskProgressView(job: job, edit: { beginEditing(job) },
                                             canMoveEarlier: queuedIDs.first != job.id,
                                             canMoveLater: queuedIDs.last != job.id)
                        }
                    }
                }.scrollIndicators(.hidden).frame(maxHeight: jobs.count == 1 ? 132 : 230)
                }
            }.padding(.bottom, 12)
                .sheet(item: $editingJob) { job in
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Изменить задачу").font(.title3.weight(.semibold))
                        Text("Изменения применятся до запуска задачи.").foregroundStyle(.secondary)
                        TextEditor(text: $editedPrompt).font(.body).frame(minHeight: 130)
                            .padding(8).agentCard(cornerRadius: 12)
                            .accessibilityLabel("Текст задачи")
                        if !job.attachments.isEmpty {
                            Label("Вложений: \(job.attachments.count)", systemImage: "paperclip").foregroundStyle(.secondary)
                        }
                        HStack {
                            Spacer()
                            Button("Отмена", role: .cancel) { editingJob = nil }.keyboardShortcut(.cancelAction)
                            Button("Сохранить") {
                                if store.editQueuedJob(job.id, prompt: editedPrompt) { editingJob = nil }
                            }.keyboardShortcut(.defaultAction)
                                .disabled(editedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && job.attachments.isEmpty)
                        }
                    }.padding(24).frame(width: 500)
                }
        }
    }

    private func beginEditing(_ job: AgentJob) {
        editedPrompt = job.prompt
        editingJob = job
    }
}

struct TaskProgressView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let job: AgentJob
    let edit: () -> Void
    let canMoveEarlier: Bool
    let canMoveLater: Bool

    private var running: Bool { job.status == "running" }
    private var queued: Bool { job.status == "queued" }
    private var fraction: Double? {
        if job.status == "done" { return 1 }
        guard let progress = job.progress, progress.isFinite else { return nil }
        return min(1, max(0, progress))
    }
    private var status: String {
        ["queued": "В очереди", "running": "Выполняется", "paused": "Приостановлена",
         "interrupted": "Прервана", "done": "Готово", "cancelled": "Отменена", "failed": "Ошибка"][job.status] ?? job.status
    }
    private var symbol: String {
        ["queued": "clock", "running": "sparkle", "paused": "pause.circle", "interrupted": "pause.circle",
         "done": "checkmark.circle.fill", "cancelled": "xmark.circle", "failed": "exclamationmark.circle"][job.status] ?? "circle"
    }
    private var tint: Color { job.status == "done" ? .green : job.status == "failed" ? .orange : running ? .accentColor : .secondary }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint).frame(width: 18).padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(job.prompt.isEmpty ? "Задача с вложениями" : job.prompt)
                        .font(.system(size: store.textSize(12), weight: running ? .medium : .regular))
                        .lineLimit(running ? 2 : 1)
                    HStack(spacing: 7) {
                        Text(status)
                        if !job.attachments.isEmpty { Label("\(job.attachments.count)", systemImage: "paperclip") }
                        if let steps = job.completedSteps, steps > 0 { Text("Шагов: \(steps)") }
                        if running, let startedAt = job.startedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { context in
                                Text(elapsed(since: startedAt, now: context.date)).monospacedDigit()
                            }
                        }
                    }.font(.system(size: store.textSize(10))).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                controls
            }
            if running {
                Text(job.phase ?? store.activity).font(.system(size: store.textSize(11)))
                    .foregroundStyle(.secondary).lineLimit(2)
            }
            HStack(spacing: 9) {
                progressBar
                if let fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: store.textSize(10), weight: .medium)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let corrections = job.pendingCorrections, !corrections.isEmpty {
                Label("Уточнений к следующему шагу: \(corrections.count)", systemImage: "text.bubble")
                    .font(.system(size: store.textSize(10))).foregroundStyle(.secondary)
                    .help(corrections.joined(separator: "\n"))
            }
        }.padding(12).agentCard(cornerRadius: 16)
            .contextMenu { if queued { queueActions } }
    }

    private var controls: some View {
        HStack(spacing: 9) {
            if (job.undoIDs ?? []).contains(where: { store.undos[$0] != nil }) && ["done", "paused", "interrupted"].contains(job.status) {
                Button { store.undoJob(job.id) } label: { Image(systemName: "arrow.uturn.backward") }
                    .help("Отменить все изменения задачи").accessibilityLabel("Отменить изменения задачи")
            }
            if queued {
                Menu { queueActions } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().help("Управление очередью").accessibilityLabel("Управление очередью")
            } else if running {
                Button { store.pauseTask() } label: { Image(systemName: "pause.fill") }
                    .help("Приостановить задачу").accessibilityLabel("Приостановить задачу")
            } else if ["paused", "interrupted", "failed"].contains(job.status) {
                Button { store.resumeJob(job.id) } label: { Image(systemName: "play.fill") }
                    .help("Продолжить задачу").accessibilityLabel("Продолжить задачу")
            }
            if ["done", "cancelled", "failed"].contains(job.status) {
                Button { store.dismissTask(job.id) } label: { Image(systemName: "xmark") }
                    .help("Закрыть карточку; результат и история сохранятся").accessibilityLabel("Закрыть карточку задачи")
            }
            if ["queued", "running", "paused", "interrupted"].contains(job.status) {
                Button { store.cancelJob(job.id) } label: { Image(systemName: "xmark") }
                    .help(queued ? "Удалить из очереди" : "Отменить задачу").accessibilityLabel(queued ? "Удалить из очереди" : "Отменить задачу")
            }
        }.buttonStyle(.borderless).font(.system(size: store.textSize(11))).foregroundStyle(.secondary)
    }

    @ViewBuilder private var queueActions: some View {
        Button("Изменить…", systemImage: "pencil", action: edit)
        Button("Раньше", systemImage: "arrow.up") { store.moveQueuedJob(job.id, offset: -1) }.disabled(!canMoveEarlier)
        Button("Позже", systemImage: "arrow.down") { store.moveQueuedJob(job.id, offset: 1) }.disabled(!canMoveLater)
        if store.busy && store.activeChatID == job.chatID {
            Button("Применить к текущей", systemImage: "text.bubble") { store.steerQueuedJob(job.id) }
                .disabled(!job.attachments.isEmpty)
        }
        Divider()
        Button("Удалить из очереди", systemImage: "trash", role: .destructive) { store.cancelJob(job.id) }
    }

    private var progressBar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.12))
                if let fraction {
                    Capsule().fill(tint.gradient).frame(width: geometry.size.width * fraction)
                } else if running {
                    TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
                        let travel = reduceMotion ? 0.35 : (sin(context.date.timeIntervalSinceReferenceDate * 1.8) + 1) / 2
                        Capsule().fill(tint.gradient).frame(width: geometry.size.width * 0.3)
                            .offset(x: geometry.size.width * 0.7 * travel)
                    }
                }
            }
        }.frame(height: running ? 5 : 3)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Прогресс задачи")
            .accessibilityValue(fraction.map { "\(Int($0 * 100)) процентов" } ?? status)
    }

    private func elapsed(since date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
