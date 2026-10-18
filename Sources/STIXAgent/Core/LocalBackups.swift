import Foundation
import CryptoKit
import Darwin

struct BackupRecord: Identifiable { var id: String { url.lastPathComponent }; var url: URL; var createdAt: Date; var automatic: Bool; var fileCount: Int }
struct BackupManifest: Codable {
    var version = 1
    var createdAt = Date()
    var automatic: Bool
    var sourceRoot: String
    var files: [String:String]
    var externalAttachments: [String:String]
    var unavailableAttachments: [String]
}

enum LocalBackups {
    static func defaultDirectory(paths: AppStoragePaths) -> URL { paths.root.deletingLastPathComponent().appendingPathComponent(paths.root.lastPathComponent + " Backups", isDirectory: true) }
    private static func digest(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }; var hash = SHA256()
        while let data = try handle.read(upToCount: 262144), !data.isEmpty { try Task.checkCancellation(); hash.update(data: data) }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    static func create(paths: AppStoragePaths, state: PersistedState, in directory: URL, automatic: Bool) throws -> BackupRecord {
        let fm = FileManager.default, root = try StoreFiles.canonical(paths.root)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let destination = try StoreFiles.canonical(directory)
        guard destination.path != root.path, !destination.path.hasPrefix(root.path + "/") else { throw AgentError.message("Резервные копии должны храниться вне папки данных") }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let stage = destination.appendingPathComponent(".creating-" + UUID().uuidString)
        let dataRoot = stage.appendingPathComponent("Data"); try fm.createDirectory(at: dataRoot, withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
        var complete = false; defer { if !complete { try? fm.removeItem(at:stage) } }
        var files:[String:String]=[:], bytes:Int64=0
        func copy(_ source: URL, relative: String) throws {
            let values = try source.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw AgentError.message("В резервной копии запрещены ссылки и специальные файлы") }
            bytes += Int64(values.fileSize ?? 0)
            guard bytes <= 5_368_709_120, files.count < 50000 else { throw AgentError.message("Резервная копия превышает 5 ГБ или 50000 файлов") }
            let target = try StoreFiles.url(relative, root:dataRoot)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories:true, attributes:[.posixPermissions:0o700])
            try fm.copyItem(at:source,to:target)
            let hash = try digest(target); guard try digest(source) == hash else { throw AgentError.message("Файл изменился при резервном копировании: " + source.lastPathComponent) }
            files[relative]=hash
        }
        guard let entries = fm.enumerator(at:root,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.isDirectoryKey]) else { throw AgentError.message("Не удалось прочитать данные приложения") }
        for case let source as URL in entries {
            try Task.checkCancellation()
            let relative = String(source.path.dropFirst(root.path.count + 1))
            if [".Transactions","Automation"].contains(relative) { entries.skipDescendants(); continue }
            if [".store.lock","search.sqlite","documents.sqlite"].contains(relative) || relative.hasSuffix(".log") || relative.hasSuffix(".sqlite-wal") || relative.hasSuffix(".sqlite-shm") { continue }
            let values = try source.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.isDirectoryKey])
            guard values.isSymbolicLink != true else { throw AgentError.message("Резервное копирование остановлено: найдена символическая ссылка") }
            if values.isRegularFile == true { try copy(source,relative:relative) }
        }
        // Automation cursors and inbox are protected by their own shared process lock.
        let automation = root.appendingPathComponent("Automation")
        if fm.fileExists(atPath:automation.path) {
            let fd = open(try StoreFiles.url("Automation/.lock",root:root).path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
            guard fd >= 0 else { throw AgentError.message("Не удалось заблокировать очередь автоматизаций") }; defer {close(fd)}
            guard flock(fd,LOCK_EX)==0 else {throw AgentError.message("Очередь автоматизаций занята")}; defer{flock(fd,LOCK_UN)}
            if let entries=fm.enumerator(at:automation,includingPropertiesForKeys:[.isRegularFileKey]) {
                for case let file as URL in entries where file.lastPathComponent != ".lock" {
                    if try file.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile == true {try copy(file,relative:String(file.path.dropFirst(root.path.count+1)))}
                }
            }
        }
        var external:[String:String]=[:], missing:[String]=[]
        let references=state.chats.flatMap { $0.messages.flatMap(\.attachments) + ($0.draftAttachments ?? []) } + (state.jobs ?? []).flatMap(\.attachments)
        for path in Set(references.filter{$0.kind != "folder"}.map(\.path)).sorted() {
            let source=URL(fileURLWithPath:path).resolvingSymlinksInPath().standardizedFileURL
            guard !source.path.hasPrefix(root.path+"/") else {continue}
            guard fm.fileExists(atPath:source.path) else {missing.append(path);continue}
            let relative="PortableAttachments/"+UUID().uuidString+"/"+source.lastPathComponent
            try copy(source,relative:relative);external[path]=relative
        }
        let manifest=BackupManifest(automatic:automatic,sourceRoot:paths.root.path,files:files,externalAttachments:external,unavailableAttachments:missing)
        try StoreFiles.write(StoreFiles.encode(manifest),relative:"manifest.json",root:stage)
        _ = try verify(stage)
        let final=destination.appendingPathComponent(UUID().uuidString+".stixbackup")
        try fm.moveItem(at:stage,to:final);complete=true
        return .init(url:final,createdAt:manifest.createdAt,automatic:automatic,fileCount:files.count)
    }
    @discardableResult static func verify(_ snapshot: URL) throws -> BackupManifest {
        let manifest=try JSONDecoder().decode(BackupManifest.self,from:StoreFiles.read("manifest.json",root:snapshot))
        guard manifest.version==1, manifest.files.count<=50000, manifest.files["store.json"] != nil else {throw AgentError.message("Неподдерживаемая резервная копия")}
        let data=try StoreFiles.canonical(snapshot.appendingPathComponent("Data"))
        let rootValues=try snapshot.appendingPathComponent("Data").resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard rootValues.isDirectory==true,rootValues.isSymbolicLink != true,
              manifest.sourceRoot.hasPrefix("/"), !manifest.sourceRoot.contains("\0"),
              manifest.externalAttachments.values.allSatisfy({manifest.files[$0] != nil && $0.hasPrefix("PortableAttachments/")}) else{throw AgentError.message("Некорректная структура резервной копии")}
        guard let entries=FileManager.default.enumerator(at:data,includingPropertiesForKeys:[.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey]) else{throw AgentError.message("Данные копии недоступны")}
        var seen=Set<String>()
        for case let file as URL in entries {
            let values=try file.resourceValues(forKeys:[.isRegularFileKey,.isDirectoryKey,.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else{throw AgentError.message("В копии обнаружена символическая ссылка")}
            if values.isRegularFile==true {
                let relative=String(file.path.dropFirst(data.path.count+1))
                guard manifest.files[relative] != nil else{throw AgentError.message("В копии обнаружен незаявленный файл: "+relative)}
                seen.insert(relative)
            }else if values.isDirectory != true{throw AgentError.message("В копии обнаружен специальный файл")}
        }
        guard seen==Set(manifest.files.keys) else{throw AgentError.message("В резервной копии отсутствуют файлы")}
        for (relative,hash) in manifest.files {guard hash.count==64, try digest(StoreFiles.url(relative,root:data))==hash else {throw AgentError.message("Резервная копия повреждена: "+relative)}}
        _ = try SplitStore.load(root:data)
        return manifest
    }
    static func list(in directory: URL) throws -> [BackupRecord] {
        guard FileManager.default.fileExists(atPath:directory.path) else{return []}
        return try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil).filter{$0.pathExtension=="stixbackup"}.map { url in
            let manifest=try JSONDecoder().decode(BackupManifest.self,from:StoreFiles.read("manifest.json",root:url))
            return BackupRecord(url:url,createdAt:manifest.createdAt,automatic:manifest.automatic,fileCount:manifest.files.count)
        }.sorted{$0.createdAt>$1.createdAt}
    }
    static func restore(_ snapshot: URL, paths: AppStoragePaths) throws -> URL {
        let manifest=try verify(snapshot), fm=FileManager.default
        let parent=paths.root.deletingLastPathComponent(), stage=parent.appendingPathComponent(".stix-restore-"+UUID().uuidString)
        try fm.copyItem(at:snapshot.appendingPathComponent("Data"),to:stage)
        var moved=false;defer{if !moved{try? fm.removeItem(at:stage)}}
        let storage=StateStorage(paths:.init(root:stage));guard var state=try storage.load() else{throw AgentError.message("В копии нет истории")}
        func rebase(_ path:String)->String {
            if path.hasPrefix(manifest.sourceRoot+"/"){return paths.root.path+path.dropFirst(manifest.sourceRoot.count)}
            if !fm.fileExists(atPath:path), let copy=manifest.externalAttachments[path]{return paths.root.appendingPathComponent(copy).path}
            return path
        }
        func attachment(_ item:Attachment)->Attachment{var item=item;item.path=rebase(item.path);return item}
        for i in state.chats.indices {
            for j in state.chats[i].messages.indices{state.chats[i].messages[j].attachments=state.chats[i].messages[j].attachments.map(attachment)}
            state.chats[i].draftAttachments=state.chats[i].draftAttachments?.map(attachment)
        }
        var jobs = state.jobs ?? []; for i in jobs.indices {jobs[i].attachments=jobs[i].attachments.map(attachment)}; state.jobs=jobs
        for i in state.undos.indices {state.undos[i].source=rebase(state.undos[i].source);state.undos[i].destination=state.undos[i].destination.map(rebase);state.undos[i].backup=state.undos[i].backup.map(rebase)}
        for i in state.preferences.connections.indices{state.preferences.connections[i].documentationPath=rebase(state.preferences.connections[i].documentationPath)}
        for i in state.preferences.imageProfiles.indices{state.preferences.imageProfiles[i].path=rebase(state.preferences.imageProfiles[i].path)}
        if var features=state.features {
            for i in features.imageRecipes.indices {
                features.imageRecipes[i].attachmentPaths=features.imageRecipes[i].attachmentPaths.map(rebase)
                features.imageRecipes[i].request.inputImagePath=features.imageRecipes[i].request.inputImagePath.map(rebase)
                features.imageRecipes[i].request.maskImagePath=features.imageRecipes[i].request.maskImagePath.map(rebase)
            }
            features.documentFolders=features.documentFolders.map(rebase)
            for i in features.automations.indices{features.automations[i].folder=features.automations[i].folder.map(rebase)}
            state.features=features
        }
        try storage.save(state)
        let previous=parent.appendingPathComponent("STIX-data-before-restore-"+UUID().uuidString)
        let journal:[String:String]=["root":paths.root.path,"stage":stage.path,"previous":previous.path]
        try StoreFiles.write(StoreFiles.encode(journal),relative:".stix-restore-journal.json",root:parent)
        if fm.fileExists(atPath:paths.root.path){try fm.moveItem(at:paths.root,to:previous)}
        do{try fm.moveItem(at:stage,to:paths.root);moved=true}
        catch{if !fm.fileExists(atPath:paths.root.path),fm.fileExists(atPath:previous.path){try? fm.moveItem(at:previous,to:paths.root)};throw error}
        _ = try SplitStore.load(root:paths.root)
        try fm.removeItem(at:parent.appendingPathComponent(".stix-restore-journal.json"))
        return previous
    }
    static func recoverRestore(paths:AppStoragePaths) throws {
        let fm=FileManager.default,parent=paths.root.deletingLastPathComponent(),file=parent.appendingPathComponent(".stix-restore-journal.json")
        guard fm.fileExists(atPath:file.path) else{return}
        let record=try JSONDecoder().decode([String:String].self,from:StoreFiles.read(file.lastPathComponent,root:parent))
        guard record["root"]==paths.root.path,let stage=record["stage"],let previous=record["previous"],URL(fileURLWithPath:stage).deletingLastPathComponent()==parent,URL(fileURLWithPath:previous).deletingLastPathComponent()==parent else{throw AgentError.message("Некорректный журнал восстановления")}
        if !fm.fileExists(atPath:paths.root.path){
            let candidate=fm.fileExists(atPath:stage) ? stage : previous
            _ = try SplitStore.load(root:URL(fileURLWithPath:candidate));try fm.moveItem(atPath:candidate,toPath:paths.root.path)
        }
        _ = try SplitStore.load(root:paths.root);try fm.removeItem(at:file)
    }
}
