import AppKit
import Foundation

extension AppStore {
    func makeBackup(directory:URL?=nil) async throws->BackupRecord{
        guard canPersist,!busy else{throw AgentError.message("Дождитесь завершения задачи перед резервным копированием")}
        save();guard canPersist else{throw AgentError.message("История не сохранена")}
        busy=true;activity="Создаю и проверяю резервную копию…";defer{busy=false;activity="";startNextJob()}
        let storage=storage,target=directory ?? LocalBackups.defaultDirectory(paths:storage.paths)
        return try await fileWork{try storage.createBackup(in:target,automatic:false)}
    }
    func restoreSnapshot(_ snapshot:URL) async throws{
        guard canPersist,!busy else{throw AgentError.message("Сначала завершите текущую задачу")}
        _ = try await fileWork{try LocalBackups.verify(snapshot)}
        save();guard canPersist else{throw AgentError.message("Текущее состояние не сохранено")}
        let manifestBefore=try Data(contentsOf:storage.paths.root.appendingPathComponent("store.json"))
        canPersist=false;busy=true;activity="Проверяю и восстанавливаю данные…"
        let storage=storage,paths=storage.paths,directory=LocalBackups.defaultDirectory(paths:storage.paths)
        do{
            _ = try await fileWork{try storage.createBackup(in:directory,automatic:false)}
            _ = try await fileWork{try LocalBackups.restore(snapshot,paths:paths)}
            needsFeatureRelaunch=true
            try LocalFeatureHeadless.relaunch()
        }catch{
            busy=false;activity=""
            if (try? Data(contentsOf:paths.root.appendingPathComponent("store.json")))==manifestBefore{canPersist=true}
            else{needsFeatureRelaunch=true}
            throw error
        }
    }
    func importChat(from snapshot:URL,id:UUID) async throws{
        guard canPersist,!busy else{throw AgentError.message("Сначала завершите текущую задачу")}
        busy=true;defer{busy=false;startNextJob()};let paths=storage.paths
        let manifest=try await fileWork{try LocalBackups.verify(snapshot)}
        let state=try await fileWork{try SplitStore.load(root:snapshot.appendingPathComponent("Data"))}
        guard var chat=state.chats.first(where:{$0.id==id}) else{throw AgentError.message("Чат не найден в копии")}
        let oldID=chat.id;chat.id=UUID();chat.title=String((chat.title+" · восстановлен").prefix(100));chat.updatedAt=Date()
        var ids:[UUID:UUID]=[:],mapped:[String:String]=[:]
        func copy(_ original:Attachment)throws->Attachment{
            var attachment=original
            if let target=mapped[original.path]{attachment.path=target;return attachment}
            var relative:String?
            if original.path.hasPrefix(manifest.sourceRoot+"/"){relative=String(original.path.dropFirst(manifest.sourceRoot.count+1))}
            else{relative=manifest.externalAttachments[original.path]}
            guard let relative,manifest.files[relative] != nil,original.kind != "folder" else{return attachment}
            let source=try StoreFiles.url(relative,root:snapshot.appendingPathComponent("Data")),target=paths.chatAttachments(chat.id).appendingPathComponent("Restored-"+UUID().uuidString+"-"+source.lastPathComponent)
            try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try FileManager.default.copyItem(at:source,to:target);mapped[original.path]=target.path;attachment.path=target.path;return attachment
        }
        for i in chat.messages.indices{let old=chat.messages[i].id;chat.messages[i].id=UUID();ids[old]=chat.messages[i].id;chat.messages[i].undoID=nil;chat.messages[i].attachments=try chat.messages[i].attachments.map(copy)}
        chat.draftAttachments=try chat.draftAttachments?.map(copy)
        for i in chat.history.indices{chat.history[i].sourceMessageID=chat.history[i].sourceMessageID.flatMap{ids[$0]}}
        if let checkpoint=chat.contextCheckpoint{chat.messages.append(.init(role:"tool",text:"Прежнее резюме восстановленного чата",toolName:"context",detail:checkpoint.summary,status:"done"))};chat.contextCheckpoint=nil
        preserveDraft();chats.insert(chat,at:0)
        for var entry in state.memoryEntries ?? [] where entry.scope == .chat && entry.ownerID==oldID{entry.id=UUID();entry.ownerID=chat.id;if entry.sourceChatID==oldID{entry.sourceChatID=chat.id};memoryEntries.append(entry)}
        selectedID=chat.id;draft=chat.savedDraft ?? "";attachments=chat.draftAttachments ?? [];save()
        guard canPersist else{throw AgentError.message("Восстановленный чат не удалось сохранить")}
    }
    func exportCredentials(password:String)throws->Data{
        let ids=Set(preferences.secrets.map(\.id)+preferences.connections.filter{$0.auth != "none"}.map(\.id)+preferences.plugins.filter{$0.oauth != nil}.map{"mcp-oauth:"+$0.id})
        var values:[String:String]=[:]
        for id in ids{values[id]=try vault.get(id)}
        guard !values.isEmpty else{throw AgentError.message("Нет доступных ключей для экспорта")}
        return try CredentialArchive.seal(values,password:password)
    }
    func importCredentials(_ data:Data,password:String,replace:Bool)throws->Int{
        let values=try CredentialArchive.open(data,password:password)
        guard values.values.allSatisfy({!$0.isEmpty && $0.utf8.count<=16384}) else{throw AgentError.message("Недопустимые значения ключей")}
        var originals:[String:String]=[:],created:Set<String>=[],written:[String]=[]
        do{
            for(id,value)in values{
                let existing=try? vault.get(id)
                if let existing{if !replace{continue};originals[id]=existing}else{created.insert(id)}
                try vault.set(value,for:id);written.append(id)
            }
        }catch{
            var failures=0
            for id in written.reversed(){do{if let original=originals[id]{try vault.set(original,for:id)}else if created.contains(id){try vault.remove(id)}}catch{failures+=1}}
            throw AgentError.message(failures == 0 ? "Импорт ключей не завершён; прежние значения восстановлены" : "Импорт ключей прерван. Не удалось восстановить \(failures) значений Keychain; проверьте подключения")
        }
        return written.count
    }
}
