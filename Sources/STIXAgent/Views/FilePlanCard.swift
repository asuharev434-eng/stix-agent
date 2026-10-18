import SwiftUI

struct FilePlanCard: View {
    @EnvironmentObject var store: AppStore
    let planID: String
    let chatID: UUID
    @State private var detail: FileChangePlanner.Detail?
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("План файловых изменений", systemImage: "arrow.triangle.branch").font(.headline)
            if let detail {
                Text("\(detail.operations.count) операций · \(status(detail.status))").font(.callout).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(detail.operations.enumerated()), id: \.offset) { _, line in
                            Text(store.vault.redact(line)).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.frame(maxHeight: 170)
                if detail.status == "preview" {
                    Text("Источники и назначения будут сверены повторно. Изменённые файлы не перезапишутся.").font(.caption).foregroundStyle(.secondary)
                    Button("Применить \(detail.operations.count) операций") {
                        Task { await store.applyReviewedPlan(planID, chatID: chatID); await reload() }
                    }.buttonStyle(.borderedProminent).disabled(store.busy || !store.canPersist)
                } else if detail.receiptCount > 0 {
                    Text("Отмена доступна в карточках выполненных действий и задачи.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.orange) }
        }.padding(18).agentCard().task(id: store.busy) { if !store.busy { await reload() } }
    }
    private func reload() async {
        let paths = store.storage.paths
        do { detail = try await fileWork { try FileChangePlanner(paths: paths).detail(id: planID) }; failure = nil }
        catch { failure = store.vault.redact(error.localizedDescription) }
    }
    private func status(_ value: String) -> String {
        ["preview": "ожидает применения", "applying": "прервано во время применения", "applied": "применён", "rolledBack": "отменён", "rollbackFailed": "отмена требует внимания"][value] ?? value
    }
}

extension AppStore {
    /// Clicking the native preview is the user's explicit approval of this exact plan.
    func applyReviewedPlan(_ id: String, chatID: UUID) async {
        guard canPersist, !busy, let chat = chats.first(where: { $0.id == chatID }) else { return }
        let paths = storage.paths, folder = chat.folder ?? FileManager.default.homeDirectoryForCurrentUser.path
        let sourceMessageID = recordHumanActionRequest("Применить файловый план " + id, chatID: chatID)
        guard canPersist else { return }
        let job = AgentJob(chatID: chatID, prompt: "Применить файловый план " + id, status: "running", started: true, inputRecorded: true, sourceMessageID: sourceMessageID, phase: "Применяю проверенный план")
        jobs.append(job); busy = true; activeChatID = chatID; activeJobID = job.id; save()
        let execution = Task { @MainActor in
            defer { busy = false; activeChatID = nil; activeJobID = nil; activity = ""; task = nil; save(); startNextJob() }
            guard canPersist else { return }
            do {
                let result = try await fileWork { try FileChangePlanner(paths: paths).apply(id: id, workingDirectory: folder) }
                result.results.compactMap(\.undo).forEach(registerUndo)
                for item in result.results {
                    if let receipt = item.undo {
                        let checks = try await verifyMutation(receipt)
                        let passed = checks.allSatisfy(\.passed)
                        addMessage(.init(role: "tool", text: item.text + "\n" + checks.map { ($0.passed ? "✓ " : "⚠ ") + $0.detail }.joined(separator: "\n"), toolName: "apply_changes", status: passed ? "done" : "error", undoID: receipt.id), to: chatID)
                        completedTaskStep()
                    }
                }
                updateJob(job.id, status: "done")
                let checks = jobs.first(where: { $0.id == job.id })?.verifications ?? []
                recordHumanActionResult("План применён: " + id + "\nОпераций: \(result.results.count)\n" + result.results.map(\.text).joined(separator: "\n") + "\nПроверки:\n" + checks.map { ($0.passed ? "✓ " : "⚠ ") + $0.subject + ": " + $0.detail }.joined(separator: "\n"), chatID: chatID)
                addMessage(.init(role: "assistant", text: "План применён: \(result.results.count) операций. Результаты проверок показаны в карточках; отмена доступна в карточке задачи."), to: chatID)
            } catch {
                if let failure = error as? FileChangePlanner.ApplyFailure { failure.undoRecords.forEach(registerUndo) }
                if jobs.first(where: { $0.id == job.id })?.status == "running" { updateJob(job.id, status: Task.isCancelled ? "interrupted" : "failed") }
                recordHumanActionResult("План " + id + " не завершён: " + vault.redact(error.localizedDescription), chatID: chatID)
                addMessage(.init(role: "assistant", text: vault.redact(error.localizedDescription), status: "error"), to: chatID)
            }
        }
        task = execution
        await execution.value
    }
}
