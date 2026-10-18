import SwiftUI
import AppKit

struct BackupsCard:View{
    @EnvironmentObject var store:AppStore
    let chatID:UUID
    @State private var records:[BackupRecord]=[]
    @State private var notice=""
    @State private var restore:BackupRecord?
    @State private var restoreChat:BackupRecord?
    @State private var transfer=false
    var body:some View{
        VStack(alignment:.leading,spacing:12){
            Label("Резервные копии и перенос",systemImage:"externaldrive").font(.headline)
            Text("Полные локальные снимки проверяются по контрольным суммам. Копируются история, память, скиллы, настройки, вложения и квитанции отмены. Рабочие папки проектов остаются ссылками. Ключи Keychain переносятся отдельно в зашифрованном архиве.").font(.caption).foregroundStyle(.secondary)
            Toggle("Ежедневная автоматическая копия",isOn:Binding(get:{store.features.automaticBackups},set:{store.features.automaticBackups=$0;store.save()}))
            Text("Автоматические копии создаются при открытом приложении, когда оно свободно; сохраняются последние 7. Ручные копии не удаляются.").font(.caption2).foregroundStyle(.secondary)
            HStack{
                Button("Создать копию"){create(directory:nil)}.disabled(store.busy || !store.canPersist)
                Button("Копия на диск…"){let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.canCreateDirectories=true;if panel.runModal() == .OK,let url=panel.url{create(directory:url)}}.disabled(store.busy || !store.canPersist)
                Button("Открыть папку"){NSWorkspace.shared.open(LocalBackups.defaultDirectory(paths:store.storage.paths))}
            }
            Button("Открыть копию с другого Mac…"){
                let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.treatsFilePackagesAsDirectories=true
                if panel.runModal() == .OK,let url=panel.url{Task{do{let manifest=try await fileWork{try LocalBackups.verify(url)};restore=BackupRecord(url:url,createdAt:manifest.createdAt,automatic:manifest.automatic,fileCount:manifest.files.count)}catch{notice=store.vault.redact(error.localizedDescription)}}}
            }.disabled(store.busy || !store.canPersist)
            ForEach(Array(records.prefix(12))){record in
                HStack{VStack(alignment:.leading){Text(record.createdAt.formatted()).font(.callout);Text("\(record.fileCount) файлов · \(record.automatic ? "автоматическая" : "ручная")").font(.caption).foregroundStyle(.secondary)};Spacer();Menu("Восстановить"){Button("Выбранный чат как новый…"){restoreChat=record};Button("Все данные…"){restore=record}}.disabled(store.busy || !store.canPersist)}
            }
            Button("Защищённый перенос ключей…"){transfer=true}
            if store.needsFeatureRelaunch{Button("Перезапустить приложение"){do{try LocalFeatureHeadless.relaunch()}catch{notice=error.localizedDescription}}.buttonStyle(.borderedProminent)}
            if !notice.isEmpty{Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)}
            Text("После переноса на другой Mac переукажите недоступные рабочие папки и интерпретаторы. История остаётся сохранённой; индекс документов строится заново.").font(.caption2).foregroundStyle(.secondary)
        }.padding(18).agentCard().task{reload()}
            .sheet(item:$restore){record in
                VStack(alignment:.leading,spacing:16){
                    Text("Восстановить все данные?").font(.headline)
                    Text("Снимок: \(record.createdAt.formatted()) · \(record.fileCount) файлов. Текущее состояние сначала будет сохранено в отдельную копию. Затем приложение перезапустится. Значения Keychain не изменяются.")
                    HStack{Button("Отмена"){restore=nil};Spacer();Button("Сохранить текущее и восстановить"){
                        restore=nil;Task{do{try await store.restoreSnapshot(record.url)}catch{notice=store.vault.redact(error.localizedDescription)}}
                    }.buttonStyle(.borderedProminent)}
                }.padding(24).frame(width:500)
            }
            .sheet(item:$restoreChat){record in ChatRestoreSheet(record:record){restoreChat=nil}.environmentObject(store)}
            .sheet(isPresented:$transfer){CredentialTransferSheet().environmentObject(store)}
    }
    private func create(directory:URL?){Task{do{let record=try await store.makeBackup(directory:directory);notice="Проверено \(record.fileCount) файлов: "+record.url.path;reload()}catch{notice=store.vault.redact(error.localizedDescription)}}}
    private func reload(){do{records=try LocalBackups.list(in:LocalBackups.defaultDirectory(paths:store.storage.paths))}catch{notice=store.vault.redact(error.localizedDescription)}}
}
private struct ChatRestoreSheet:View{
    @EnvironmentObject var store:AppStore
    let record:BackupRecord
    let close:()->Void
    @State private var chats:[Chat]=[]
    @State private var selected:UUID?
    @State private var notice=""
    var body:some View{
        VStack(alignment:.leading,spacing:16){
            Text("Восстановить чат как новый").font(.headline)
            Text("Текущие чаты и память останутся на месте. Восстановленные действия не получают активных кнопок отмены старых файловых операций.").font(.caption).foregroundStyle(.secondary)
            Picker("Чат",selection:$selected){Text("Выберите…").tag(nil as UUID?);ForEach(chats){Text($0.title).tag(Optional($0.id))}}
            if !notice.isEmpty{Text(notice).font(.caption).foregroundStyle(.orange)}
            HStack{Button("Отмена",action:close);Spacer();Button("Восстановить"){
                if let selected{Task{do{try await store.importChat(from:record.url,id:selected);close()}catch{notice=store.vault.redact(error.localizedDescription)}}}
            }.disabled(selected==nil || store.busy)}
        }.padding(24).frame(width:500).task{do{_ = try await fileWork{try LocalBackups.verify(record.url)};chats=try await fileWork{try SplitStore.load(root:record.url.appendingPathComponent("Data"))}.chats}catch{notice=error.localizedDescription}}
    }
}
private struct CredentialTransferSheet:View{
    @EnvironmentObject var store:AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var password=""
    @State private var repeatPassword=""
    @State private var replace=false
    @State private var notice=""
    @State private var working=false
    var body:some View{
        VStack(alignment:.leading,spacing:14){
            Text("Защищённый перенос ключей").font(.headline)
            Text("Значения не передаются модели и не появляются в чате. Архив шифруется AES-GCM; пароль выводит ключ через PBKDF2-SHA256. Храните пароль отдельно от архива.").font(.caption).foregroundStyle(.secondary)
            SecureField("Пароль архива, минимум 12 символов",text:$password).textContentType(.password)
            SecureField("Повтор пароля для экспорта",text:$repeatPassword).textContentType(.password)
            Toggle("Заменять существующие ключи при импорте",isOn:$replace)
            HStack{
                Button("Экспортировать…"){
                    guard password==repeatPassword,password.count>=12 else{notice="Пароли должны совпадать и содержать минимум 12 символов";return}
                    let panel=NSSavePanel();panel.nameFieldStringValue="STIX-credentials.stixkeys"
                    if panel.runModal() == .OK,let url=panel.url{working=true;Task{defer{password="";repeatPassword="";working=false};do{let data=try store.exportCredentials(password:password);try data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path);notice="Зашифрованный архив сохранён"}catch{notice="Не удалось экспортировать ключи. Проверьте доступ к Keychain и пароль."}}}
                }
                Button("Импортировать…"){
                    let panel=NSOpenPanel();panel.canChooseDirectories=false
                    if panel.runModal() == .OK,let url=panel.url{working=true;Task{defer{password="";repeatPassword="";working=false};do{let count=try store.importCredentials(Data(contentsOf:url),password:password,replace:replace);notice="Импортировано ключей: \(count)"}catch{notice=error.localizedDescription}}}
                }
                Spacer();Button("Закрыть"){password="";repeatPassword="";dismiss()}
            }.disabled(working)
            if working{ProgressView().controlSize(.small)}
            if !notice.isEmpty{Text(notice).font(.caption).foregroundStyle(.secondary)}
        }.textFieldStyle(.roundedBorder).padding(24).frame(width:560)
            .onDisappear{password="";repeatPassword=""}
    }
}
