import Foundation

struct IsolatedResult: Sendable { var id: UUID; var output:String; var exitCode:Int32; var timedOut:Bool; var outputs:[URL] }
struct IsolatedRunner {
    let paths:AppStoragePaths
    func run(language:String,code:String,inputs:[String],timeout:TimeInterval) async throws -> IsolatedResult {
        guard code.utf8.count<=128000,!code.contains("\0"),inputs.count<=8,timeout.isFinite,(1...120).contains(timeout) else{throw AgentError.message("Изолированный запуск: код до 128 КБ, до 8 входных файлов и 1–120 секунд")}
        guard FileManager.default.isExecutableFile(atPath:"/usr/bin/sandbox-exec") else{throw AgentError.message("Seatbelt sandbox-exec недоступен на этой версии macOS; запуск без изоляции не выполнялся")}
        let executable:String,ext:String,args:[String]
        switch language {
        case "python":executable=try runtime(["/opt/homebrew/bin/python3","/usr/local/bin/python3","/Applications/Xcode.app/Contents/Developer/usr/bin/python3","/Library/Developer/CommandLineTools/usr/bin/python3","/usr/bin/python3"]);ext="py";args=["-I","-S"]
        case "javascript":executable=try runtime(["/opt/homebrew/bin/node","/usr/local/bin/node","/usr/bin/node"]);ext="js";args=[]
        case "shell":executable="/bin/sh";ext="sh";args=[]
        default:throw AgentError.message("Язык: python, javascript или shell")
        }
        let id=UUID(),relative="SandboxRuns/"+id.uuidString
        let root=try StoreFiles.url(relative,root:paths.root)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let canonical=try StoreFiles.canonical(root)
        for name in ["Inputs","Outputs","Temp"]{try FileManager.default.createDirectory(at:canonical.appendingPathComponent(name),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])}
        let script=canonical.appendingPathComponent("script."+ext);try Data(code.utf8).write(to:script,options:.atomic)
        var bytes=0
        for path in inputs {
            let url=try FileTools(paths:paths).resolve(path,workingDirectory:nil)
            let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
            bytes += values.fileSize ?? Int.max/10
            guard values.isRegularFile==true,values.isSymbolicLink != true,bytes<=50_000_000 else{throw AgentError.message("Входные файлы: обычные файлы суммарно до 50 МБ")}
            let target=canonical.appendingPathComponent("Inputs/"+url.lastPathComponent)
            guard !FileManager.default.fileExists(atPath:target.path) else{throw AgentError.message("Имена входных файлов совпадают")}
            try FileManager.default.copyItem(at:url,to:target)
            try FileManager.default.setAttributes([.posixPermissions:0o400],ofItemAtPath:target.path)
        }
        let profile=canonical.appendingPathComponent("profile.sb")
        try Data(Self.profile(root:canonical).utf8).write(to:profile,options:.atomic)
        let command=["-i","PATH=/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin","HOME="+canonical.path,"TMPDIR="+canonical.appendingPathComponent("Temp").path,"LANG=en_US.UTF-8","/usr/bin/sandbox-exec","-f",profile.path,executable]+args+[script.path]
        let result=try await ProcessRunner().runExecutable("/usr/bin/env",arguments:command,directory:canonical.path,timeout:timeout)
        let outputRoot=canonical.appendingPathComponent("Outputs"),fm=FileManager.default
        var outputs:[URL]=[],outputBytes=0
        if let enumerator=fm.enumerator(at:outputRoot,includingPropertiesForKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]){
            while let output = enumerator.nextObject() as? URL {
                let values=try output.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
                guard values.isSymbolicLink != true else{throw AgentError.message("Результат содержит символическую ссылку; публикация запрещена")}
                if values.isRegularFile==true{outputBytes += values.fileSize ?? Int.max/10;guard outputs.count<200,outputBytes<=100_000_000 else{throw AgentError.message("Результаты превышают 200 файлов или 100 МБ")};outputs.append(output)}
            }
        }
        try StoreFiles.write(StoreFiles.encode(["language":language,"exit":String(result.exitCode),"timeout":String(result.timedOut),"isolation":"Seatbelt: no network; writes Outputs/Temp only"]),relative:"result.json",root:canonical)
        return .init(id:id,output:result.output,exitCode:result.exitCode,timedOut:result.timedOut,outputs:outputs.sorted{$0.path<$1.path})
    }
    private func runtime(_ candidates:[String])throws->String{
        guard let found=candidates.first(where:{FileManager.default.isExecutableFile(atPath:$0)}) else{throw AgentError.message("Локальный интерпретатор не установлен")};return URL(fileURLWithPath:found).resolvingSymlinksInPath().path
    }
    static func profile(root:URL)->String{
        func quoted(_ value:String)->String{"\""+value.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")+"\""}
        return """
        (version 1)
        (deny default)
        (import "dyld-support.sb")
        (allow syscall* mach-bootstrap dynamic-code-generation)
        (allow process-exec process-fork sysctl-read)
        (allow file-read-metadata)
        (allow signal (target self))
        (allow file-read-data file-map-executable
          (subpath "/System") (subpath "/usr") (subpath "/bin") (subpath "/sbin")
          (subpath "/opt/homebrew") (subpath "/usr/local")
          (subpath "/Applications/Xcode.app/Contents/Developer")
          (subpath "/Library/Developer/CommandLineTools")
          (subpath "/Library/Frameworks/Python.framework")
          (literal "/private/etc/localtime") (literal "/dev/urandom") (literal "/dev/random")
          (subpath \(quoted(root.path))))
        (allow file-write* (subpath \(quoted(root.appendingPathComponent("Outputs").path))) (subpath \(quoted(root.appendingPathComponent("Temp").path))))
        (allow file-read-data file-write-data (literal "/dev/null"))
        """
    }
    func output(_ runID:UUID,name:String)throws->URL{
        guard !name.hasPrefix("/"),!name.split(separator:"/").contains("..") else{throw AgentError.message("Некорректное имя результата")}
        let root=try StoreFiles.url("SandboxRuns/"+runID.uuidString+"/Outputs",root:paths.root).resolvingSymlinksInPath()
        let url=try StoreFiles.url(name,root:root)
        guard url.resolvingSymlinksInPath().path.hasPrefix(root.path+"/"),try url.resourceValues(forKeys:[.isRegularFileKey]).isRegularFile==true else{throw AgentError.message("Результат изолированного запуска недоступен")}
        return url
    }
}
