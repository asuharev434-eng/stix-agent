import SwiftUI
import AppKit

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
            let hits = (try? ChatSearchIndex(paths: store.storage.paths).search(query, in: store.chats)) ?? LocalChatSearch.search(query, in: store.chats)
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
