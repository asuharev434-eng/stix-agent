import SwiftUI
import AppKit

struct MemoryCard: View {
    @EnvironmentObject var store: AppStore
    @State private var newRecord = ""
    @State private var editingIndex: Int?
    @State private var editedRecord = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Память", systemImage: "brain").font(.headline)
            Text("Предпочтения, рабочие папки и договорённости. Сохраняются на этом Mac и используются в новых чатах.").font(.caption).foregroundStyle(.secondary)
            if (store.preferences.memory ?? []).isEmpty { Text("Пока ничего не сохранено").foregroundStyle(.secondary) }
            ForEach(Array((store.preferences.memory ?? []).enumerated()), id: \.offset) { index, text in
                HStack(alignment: .top) {
                    if editingIndex == index {
                        TextField("Запись", text: $editedRecord, axis: .vertical).textFieldStyle(.roundedBorder)
                        Button("Сохранить") { update(index, value: editedRecord); editingIndex = nil }
                        Button("Отмена") { editingIndex = nil }
                    } else {
                        Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Button { editingIndex = index; editedRecord = text } label: { Image(systemName: "pencil") }.help("Изменить запись")
                        Button { update(index, value: nil) } label: { Image(systemName: "trash") }.help("Удалить запись из памяти")
                    }
                }.font(.callout).padding(10).agentCard(cornerRadius: 12)
            }
            HStack {
                TextField("Что запомнить…", text: $newRecord, axis: .vertical).textFieldStyle(.roundedBorder)
                Button("Запомнить") {
                    do { try store.setMemory((store.preferences.memory ?? []) + [newRecord]); newRecord = "" }
                    catch { store.error = error.localizedDescription }
                }.disabled(newRecord.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !(store.preferences.memory ?? []).isEmpty {
                Button("Удалить всю память", role: .destructive) { try? store.setMemory([]); editingIndex = nil }.buttonStyle(.borderless)
            }
        }.padding(18).agentCard()
    }
    private func update(_ index: Int, value: String?) {
        var records = store.preferences.memory ?? []
        guard records.indices.contains(index) else { return }
        if let value { records[index] = value } else { records.remove(at: index) }
        do { try store.setMemory(records) } catch { store.error = error.localizedDescription }
    }
}

struct SkillsCard: View {
    @EnvironmentObject var store: AppStore
    @State private var editedName: String?
    @State private var source = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label("Скиллы", systemImage: "sparkles").font(.headline); Spacer(); Button { store.reloadSkills() } label: { Image(systemName: "arrow.clockwise") }.help("Перечитать локальные скиллы") }
            Text("Вызывайте через /skill/имя или $имя. Подходящие инструкции агент также может прочитать сам.").font(.caption).foregroundStyle(.secondary)
            ForEach(store.skills) { skill in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(skill.name).font(.callout.weight(.semibold)); Spacer()
                        Toggle("Включён", isOn: Binding(get: { store.skills.first(where: { $0.name == skill.name })?.enabled ?? false }, set: { enabled in
                            var disabled = store.preferences.disabledSkills ?? []
                            if enabled { disabled.remove(skill.name) } else { disabled.insert(skill.name) }
                            store.preferences.disabledSkills = disabled; store.reloadSkills(); store.save()
                        })).toggleStyle(.switch).controlSize(.mini)
                    }
                    Text(skill.description).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Использовать") { store.draft = "/skill/\(skill.name) " }.disabled(!skill.enabled)
                        Button("Инструкция") {
                            do { source = try SkillLibrary(paths: store.storage.paths).read(skill.name); editedName = skill.name } catch { store.error = error.localizedDescription }
                        }
                        Button("Папка") { NSWorkspace.shared.open(URL(fileURLWithPath: skill.path)) }
                        if skill.name != "skill-creator" {
                            Button("В Корзину", role: .destructive) {
                                do { try FileManager.default.trashItem(at: URL(fileURLWithPath: skill.path), resultingItemURL: nil); store.reloadSkills() } catch { store.error = error.localizedDescription }
                            }
                        }
                    }.buttonStyle(.borderless).font(.caption)
                }.padding(12).agentCard(cornerRadius: 14)
            }
            HStack {
                Button { store.draft = "/skill/skill-creator " } label: { Label("Создать скилл", systemImage: "plus") }
                Button("Импортировать папку…") { importSkill() }
            }
        }.padding(18).agentCard().onAppear { store.reloadSkills() }
            .sheet(isPresented: Binding(get: { editedName != nil }, set: { if !$0 { editedName = nil } })) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(editedName ?? "Скилл").font(.headline)
                    TextEditor(text: $source).font(.system(size: 12, design: .monospaced)).frame(minHeight: 300)
                    HStack { Button("Отмена") { editedName = nil }; Spacer(); Button("Сохранить") { saveSkill() }.keyboardShortcut(.defaultAction) }
                }.padding(24).frame(width: 660, height: 480)
            }
    }
    private func saveSkill() {
        guard let name = editedName else { return }
        guard store.vault.redact(source) == source else { store.error = "Секрет нельзя сохранить в скилл"; return }
        do { try SkillLibrary(paths: store.storage.paths).save(name: name, content: source); store.reloadSkills(); editedName = nil }
        catch { store.error = error.localizedDescription }
    }
    private func importSkill() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { _ = try SkillLibrary(paths: store.storage.paths).importFolder(url); store.reloadSkills() } catch { store.error = error.localizedDescription }
    }
}

struct ChatSearchCard: View {
    @EnvironmentObject var store: AppStore
    let initialQuery: String
    @State private var query = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Поиск по чатам", systemImage: "magnifyingglass").font(.headline)
            TextField("Текст сообщения или договорённости", text: $query).textFieldStyle(.roundedBorder)
            let hits = LocalChatSearch.search(query, in: store.chats)
            if !query.isEmpty && hits.isEmpty { Text("Ничего не найдено").foregroundStyle(.secondary) }
            ForEach(hits) { hit in
                Button {
                    store.selectChat(hit.chatID); store.focusedMessageID = hit.messageID
                } label: {
                    VStack(alignment: .leading, spacing: 5) { Text(hit.title).font(.callout.weight(.medium)); Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(4) }.frame(maxWidth: .infinity, alignment: .leading).padding(10).agentCard(cornerRadius: 12)
                }.buttonStyle(.plain)
            }
        }.padding(18).agentCard().onAppear { query = initialQuery }
    }
}
