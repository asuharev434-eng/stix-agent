import Foundation
import AppKit

@MainActor
enum LocalServices {
    private static var comfyProcess: Process?
    static var ownsComfy: Bool { comfyProcess?.isRunning == true }
    private static var comfyLog: FileHandle?
    static func startInstalledComfy(paths: AppStoragePaths) throws -> Bool {
        if comfyProcess?.isRunning == true { return true }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let metadata = support.appendingPathComponent("Comfy Desktop/installations.json")
        guard let data = try? Data(contentsOf: metadata),
              let list = try? JSONDecoder().decode([JSONValue].self, from: data),
              let installation = list.first(where: { $0["status"].string == "installed" && $0["installPath"].string != nil }),
              let path = installation["installPath"].string else { return false }
        let root = URL(fileURLWithPath: path)
        let directory = root.appendingPathComponent("ComfyUI")
        let environmentPython = directory.appendingPathComponent(".venv/bin/python")
        let python = FileManager.default.isExecutableFile(atPath: environmentPython.path) ? environmentPython : root.appendingPathComponent("standalone-env/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path), FileManager.default.fileExists(atPath: directory.appendingPathComponent("main.py").path) else { return false }
        try paths.prepare()
        let shared = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("ComfyUI-Shared")
        let modelRoot = shared.appendingPathComponent("models")
        guard FileManager.default.fileExists(atPath: modelRoot.path) else { return false }
        let config = paths.root.appendingPathComponent("comfy-model-paths.yaml")
        let yaml = "stix_local:\n  base_path: " + String(data: try JSONEncoder().encode(shared.path), encoding: .utf8)! + "\n  checkpoints: models/checkpoints\n  vae: models/vae\n  loras: models/loras\n  diffusion_models: models/diffusion_models\n  text_encoders: models/text_encoders\n  clip: models/clip\n  embeddings: models/embeddings\n  controlnet: models/controlnet\n"
        try Data(yaml.utf8).write(to: config, options: .atomic)
        let logURL = paths.root.appendingPathComponent("comfy-local.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let log = try FileHandle(forWritingTo: logURL)
        let process = Process(); process.executableURL = python; process.currentDirectoryURL = directory
        process.arguments = ["-s", "main.py", "--listen", "127.0.0.1", "--port", "8188", "--disable-auto-launch", "--disable-all-custom-nodes", "--offline", "--extra-model-paths-config", config.path, "--input-directory", shared.appendingPathComponent("input").path, "--output-directory", shared.appendingPathComponent("output").path]
        var environment = ProcessInfo.processInfo.environment; environment["PYTHONUNBUFFERED"] = "1"; environment["HF_HUB_OFFLINE"] = "1"; environment["DO_NOT_TRACK"] = "1"
        process.environment = environment; process.standardOutput = log; process.standardError = log
        do { try process.run() } catch { try? log.close(); throw error }
        comfyProcess = process; comfyLog = log; return true
    }
    static func shutdown() { if comfyProcess?.isRunning == true { comfyProcess?.terminate() }; comfyProcess = nil; try? comfyLog?.close(); comfyLog = nil }

    static func lmCandidates() -> [String] {
        var candidates = ["http://127.0.0.1:1234", "http://127.0.0.1:1235"]
        let home = FileManager.default.homeDirectoryForCurrentUser
        for suffix in [".lmstudio/.internal/http-server-config.json", ".lmstudio/apps/bionic/.internal/http-server-config.json"] {
            let url = home.appendingPathComponent(suffix)
            if let data = try? Data(contentsOf: url), let json = try? JSONDecoder().decode(JSONValue.self, from: data), let port = json["port"].int, port > 0, port < 65536 {
                let value = "http://127.0.0.1:\(port)"
                if !candidates.contains(value) { candidates.append(value) }
            }
        }
        return candidates
    }
    static func openModelApp() {
        for path in ["/Applications/LM Studio.app", "/Applications/Bionic.app"] where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()); return
        }
    }
    static func openComfy() {
        let path = "/Applications/Comfy Desktop.app"
        if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()) }
    }
}
