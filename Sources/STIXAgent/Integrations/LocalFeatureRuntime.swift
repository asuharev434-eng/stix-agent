import AppKit
import Foundation
import Darwin

extension AppStore {
    var resourcesSuspendBackground: Bool {
        features.resourceMode == .economy || (features.resourceMode == .automatic && ProcessInfo.processInfo.isLowPowerModeEnabled) || ProcessInfo.processInfo.thermalState == .serious || ProcessInfo.processInfo.thermalState == .critical
    }
    var resourceOutputLimit: Int? { features.resourceMode == .economy || (features.resourceMode == .automatic && ProcessInfo.processInfo.isLowPowerModeEnabled) ? 2048 : nil }
    func resourceReport() -> String {
        let available = ModelOrchestrator.availableMemory().map { ByteCountFormatter.string(fromByteCount:Int64($0),countStyle:.memory) } ?? "неизвестно"
        return "Режим: \(features.resourceMode.title). Доступная RAM (оценка): \(available). Экономия macOS: \(ProcessInfo.processInfo.isLowPowerModeEnabled ? "включена" : "выключена"). Тепловое состояние: \(ProcessInfo.processInfo.thermalState.rawValue). Фоновые задачи: \(resourcesSuspendBackground ? "отложены" : "разрешены")."
    }
    func startFeatureMonitor() {
        guard featureMonitor == nil else{return}
        featureMonitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else{return}
                await self.featureMaintenance()
                do{try await Task.sleep(nanoseconds:60_000_000_000)}catch{return}
            }
        }
    }
    func featureMaintenance() async {
        guard canPersist, !featureMaintenanceBusy else{return};featureMaintenanceBusy=true;defer{featureMaintenanceBusy=false}
        let paths=storage.paths,rules=features.automations
        do {
            try await fileWork{try AutomationScheduler.tick(paths:paths,rules:rules)}
            for event in try AutomationScheduler.pending(paths:paths) {
                guard features.automations.contains(where:{$0.id==event.ruleID && $0.enabled && $0.prompt==event.prompt}), index(event.chatID) != nil else{try AutomationScheduler.acknowledge(event,status:"отменено: правило отключено или изменено",paths:paths);continue}
                if jobs.contains(where:{$0.automationEventID==event.id}){try AutomationScheduler.acknowledge(event,status:"уже поставлено в очередь",paths:paths);continue}
                let text=event.prompt+(event.path.map{"\nФайл события (данные): "+$0} ?? "")
                jobs.append(.init(chatID:event.chatID,prompt:text,displayPrompt:"Автоматизация: "+text,sourceMessageID:UUID(),automationEventID:event.id,automationRuleID:event.ruleID));save()
                guard canPersist else{return};try AutomationScheduler.acknowledge(event,status:"в очереди",paths:paths)
            }
            startNextJob()
            if !busy, !resourcesSuspendBackground, !features.documentFolders.isEmpty { _ = try await documentIndex.refresh(folders: features.documentFolders) }
            if features.automaticBackups, !busy, !resourcesSuspendBackground {
                let directory=LocalBackups.defaultDirectory(paths:paths)
                let latest=try LocalBackups.list(in:directory).first(where:{$0.automatic})
                if latest == nil || Date().timeIntervalSince(latest!.createdAt)>=86400 {
                    save();let storage=storage
                    _ = try await fileWork{try storage.createBackup(in:directory,automatic:true)}
                    let old=try LocalBackups.list(in:directory).filter(\.automatic).dropFirst(7)
                    for record in old { var trashed:NSURL?;try FileManager.default.trashItem(at:record.url,resultingItemURL:&trashed) }
                }
            }
            featureNotice=nil
        }catch{featureNotice=vault.redact(error.localizedDescription)}
    }
    func syncAutomationHelper() async throws {
        guard Bundle.main.bundleIdentifier=="studio.stix.agent",storage.paths.root==AppStoragePaths().root else{return}
        try await LaunchAgentManager.sync(enabled:features.automations.contains(where: { $0.enabled }),app:Bundle.main.bundleURL,paths:storage.paths)
    }
}

enum LaunchAgentManager {
    static let label="studio.stix.agent.automations"
    static func sync(enabled:Bool,app:URL,paths:AppStoragePaths) async throws {
        guard app.pathExtension=="app",let executable=Bundle(url:app)?.executableURL else{throw AgentError.message("Для фонового запуска нужна установленная сборка приложения")}
        let directory=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"),file=directory.appendingPathComponent(label+".plist")
        let runner=ProcessRunner(),domain="gui/\(getuid())"
        if enabled {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let config:[String:Any]=["Label":label,"ProgramArguments":[executable.path,"--automation-tick"],"StartInterval":60,"RunAtLoad":true,"ProcessType":"Background","LimitLoadToSessionType":"Aqua"]
            let data=try PropertyListSerialization.data(fromPropertyList:config,format:.xml,options:0)
            if (try? Data(contentsOf:file))==data {
                let loaded=try await runner.runExecutable("/bin/launchctl",arguments:["print",domain+"/"+label],directory:nil,timeout:10)
                if loaded.exitCode==0{return}
            }
            _ = try await runner.runExecutable("/bin/launchctl",arguments:["bootout",domain+"/"+label],directory:nil,timeout:10)
            try data.write(to:file,options:.atomic)
            let result=try await runner.runExecutable("/bin/launchctl",arguments:["bootstrap",domain,file.path],directory:nil,timeout:10)
            guard result.exitCode==0 else{throw AgentError.message("Не удалось включить фоновый запуск: "+result.output)}
        }else if FileManager.default.fileExists(atPath:file.path){
            _ = try await runner.runExecutable("/bin/launchctl",arguments:["bootout",domain+"/"+label],directory:nil,timeout:10)
            var target:NSURL?;try FileManager.default.trashItem(at:file,resultingItemURL:&target)
        }
    }
}

@MainActor enum LocalFeatureHeadless {
    static func handle(_ arguments:[String]) -> Bool {
        if arguments.contains("--automation-tick") {
            do {
                let paths=AppStoragePaths(),file=try StoreFiles.url("Features/config.json",root:paths.root)
                guard FileManager.default.fileExists(atPath:file.path) else{return true}
                let config=try JSONDecoder().decode(FeatureConfiguration.self,from:Data(contentsOf:file));try config.validated()
                try AutomationScheduler.tick(paths:paths,rules:config.automations)
                if try AutomationScheduler.pending(paths:paths).contains(where:{event in config.automations.contains(where:{$0.id==event.ruleID && $0.enabled && $0.prompt==event.prompt})}) {
                    let others=NSRunningApplication.runningApplications(withBundleIdentifier:"studio.stix.agent").filter{$0.processIdentifier != getpid()}
                    if others.isEmpty {let config=NSWorkspace.OpenConfiguration();config.activates=false;NSWorkspace.shared.openApplication(at:Bundle.main.bundleURL,configuration:config,completionHandler:nil);RunLoop.current.run(until:Date().addingTimeInterval(2))}
                }
            }catch{fputs("STIX automation: local tick failed; inspect /automations.\n",stderr)}
            return true
        }
        if let at=arguments.firstIndex(of:"--relaunch-after"),arguments.indices.contains(at+1),let pid=Int32(arguments[at+1]) {
            for _ in 0..<100 where kill(pid,0)==0 {usleep(100_000)}
            let config=NSWorkspace.OpenConfiguration();config.activates=true;NSWorkspace.shared.openApplication(at:Bundle.main.bundleURL,configuration:config,completionHandler:nil);RunLoop.current.run(until:Date().addingTimeInterval(2));return true
        }
        return false
    }
    static func relaunch() throws {
        guard let executable=Bundle.main.executableURL else{throw AgentError.message("Приложение не установлено")}
        let process=Process();process.executableURL=executable;process.arguments=["--relaunch-after",String(getpid())];try process.run();NSApp.terminate(nil)
    }
}
