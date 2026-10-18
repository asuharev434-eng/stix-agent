import SwiftUI
import AppKit

struct MemoryCard: View {
    @EnvironmentObject var store: AppStore
    let chatID: UUID
    @State private var scope: MemoryScope = .personal
    @State private var category: MemoryCategory = .preferences
    @State private var text = ""
    @State private var editing: UUID?
    @State private var always = true
    private var chat: Chat? { store.chats.first { $0.id == chatID } }
    private var records: [MemoryEntry] { store.memoryRecords(scope: scope, chatID: chatID) }
    private var project: MemoryProject? { store.projects.first { $0.id == chat?.projectID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Память", systemImage: "brain").font(.headline)
            Picker("Область памяти", selection: $scope) {
                ForEach(MemoryScope.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented)
            Text(scope == .personal ? "Личные факты и предпочтения. В другие чаты попадают только релевантные или закреплённые записи." : scope == .project ? "Знания этой рабочей папки доступны её чатам. Переписка и резюме чатов остаются раздельными." : "Заметки доступны только этому чату. Резюме контекста и журнал действий хранятся отдельно.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if scope == .project, let project {
                Label(project.title, systemImage: "folder").font(.callout.weight(.medium))
                Text(project.folder).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if scope == .project && project == nil {
                Text("Этот чат пока не привязан к проекту.").foregroundStyle(.secondary)
                Button("Выбрать рабочую папку") { store.chooseFiles(folderOnly: true) }
            } else {
                if records.isEmpty { Text("Пока нет записей в этой области").foregroundStyle(.secondary) }
                ForEach(records) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(record.category.title).font(.caption.weight(.medium))
                            if record.isCore { Image(systemName: "pin.fill").font(.caption2).help("Всегда учитывать в этой области, в пределах бюджета") }
                            Spacer()
                            Button { editing = record.id; text = record.text; category = record.category; always = record.isCore } label: { Image(systemName: "pencil") }.help("Изменить запись")
                            Button { perform { try store.forgetMemory(record.id, scope: scope, chatID: chatID) } } label: { Image(systemName: "trash") }.help("Удалить запись")
                        }
                        Text(store.vault.redact(record.text)).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(record.source) · \(record.updatedAt.timeIntervalSince1970 == 0 ? "дата неизвестна" : record.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption2).foregroundStyle(.secondary)
                        if let id = record.sourceChatID, let source = store.chats.first(where: { $0.id == id }) {
                            Button("Источник: " + source.title) { store.selectChat(id) }.font(.caption).buttonStyle(.link)
                        }
                    }.padding(12).agentCard(cornerRadius: 12)
                }
                Divider()
                Picker("Раздел", selection: $category) { ForEach(MemoryCategory.allowed(scope)) { Text($0.title).tag($0) } }.labelsHidden().frame(maxWidth: 220, alignment: .leading)
                TextField("Что запомнить…", text: $text, axis: .vertical).textFieldStyle(.roundedBorder)
                Toggle("Всегда учитывать в этой области", isOn: $always).font(.caption)
                HStack {
                    Button(editing == nil ? "Запомнить" : "Сохранить изменения") { saveRecord() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if editing != nil { Button("Отмена") { editing = nil; text = "" } }
                    Spacer()
                    if !records.isEmpty { Button("Очистить эту область", role: .destructive) { perform { try store.clearMemory(scope: scope, chatID: chatID) }; editing = nil; text = "" }.buttonStyle(.borderless) }
                }
            }
        }.padding(18).agentCard()
            .onChange(of: category) { _, value in if editing == nil { always = value == .preferences || value == .overview || value == .notes } }
            .onChange(of: scope) { _, value in category = value == .personal ? .preferences : MemoryCategory.allowed(value)[0]; text = ""; editing = nil; always = category == .preferences || category == .overview || category == .notes }
    }
    private func perform(_ action: () throws -> Void) { do { try action() } catch { store.error = store.vault.redact(error.localizedDescription) } }
    private func saveRecord() {
        perform {
            if let editing, var record = records.first(where: { $0.id == editing }) {
                record.text = text.trimmingCharacters(in: .whitespacesAndNewlines); record.category = category; record.alwaysInclude = always
                try store.updateMemory(record, chatID: chatID)
            } else { try store.remember(text, scope: scope, category: category, chatID: chatID, always: always) }
            text = ""; editing = nil
        }
    }
}
