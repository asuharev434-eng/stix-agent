import Foundation
import AppKit

@MainActor
enum LocalServices {
    private static var comfyProcess: Process?
    static var ownsComfy: Bool { comfyProcess?.isRunning == true }
    private static var comfyLog: FileHandle?
    static func installedImageCheckpoints(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [String] {
        let folder = home.appendingPathComponent("ComfyUI-Shared/models/checkpoints", isDirectory: true)
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                                        options: [.skipsHiddenFiles]) else { return [] }
        let extensions: Set<String> = ["safetensors", "ckpt"]
        return files.filter { extensions.contains($0.pathExtension.lowercased()) &&
            ((try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) ?? false)
        }.map(\.lastPathComponent).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    static func mergedImageCheckpoints(_ groups: [[String]]) -> [String] {
        var seen = Set<String>()
        return groups.flatMap { $0 }.filter { seen.insert($0).inserted }
    }
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

    static func firstReadyModelEndpoint(preferred: String, candidates: [String], probe: (String) async -> Bool) async -> String? {
        var seen = Set<String>()
        for endpoint in [preferred] + candidates where seen.insert(endpoint).inserted {
            guard (try? Diagnostics.localURL(endpoint: endpoint, path: "/v1/models", lm: true)) != nil else { continue }
            if await probe(endpoint) { return endpoint }
        }
        return nil
    }
    static func modelReady(_ endpoint: String) async -> Bool {
        do {
            let url = try Diagnostics.localURL(endpoint: endpoint, path: "/v1/models", lm: true)
            return try await Diagnostics.fetchJSON(url)["data"].array != nil
        } catch { return false }
    }
    static func ensureModelServer(preferred: String) async -> String? {
        let candidates = lmCandidates()
        func ready() async -> String? {
            await firstReadyModelEndpoint(preferred: preferred, candidates: candidates, probe: modelReady)
        }
        if let endpoint = await ready() { return endpoint }
        guard openModelApp() || modelCLI() != nil else { return nil }
        // The desktop application may restore its saved Local Server state itself.
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let endpoint = await ready() { return endpoint }
        }
        if let cli = modelCLI() {
            // lms is an installed local CLI; bind explicitly to loopback and never enable CORS.
            _ = try? await ProcessRunner().runExecutable(cli.path, arguments: ["server", "start", "--bind", "127.0.0.1"], directory: nil, timeout: 20)
        }
        for _ in 0..<25 {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if let endpoint = await ready() { return endpoint }
        }
        return nil
    }
    static func modelCLI() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [home.appendingPathComponent(".lmstudio/bin/lms"),
                     home.appendingPathComponent(".lmstudio/apps/bionic/bin/lms")]
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }
    static func comfyReady(_ endpoint: String) async -> Bool {
        do {
            let url = try Diagnostics.localURL(endpoint: endpoint, path: "/queue")
            let response = try await Diagnostics.fetchJSON(url)
            return response["queue_running"].array != nil && response["queue_pending"].array != nil
        } catch { return false }
    }
    static func canStartBundledComfy(_ endpoint: String) -> Bool {
        guard let parts = URLComponents(string: endpoint), parts.scheme == "http",
              ["127.0.0.1", "localhost"].contains(parts.host?.lowercased() ?? ""), parts.port == 8188,
              parts.path.isEmpty || parts.path == "/", parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil else { return false }
        return true
    }
    static func ensureComfyServer(endpoint: String, paths: AppStoragePaths) async throws -> Bool {
        if await comfyReady(endpoint) { return true }
        // The bundled local installation is configured for this exact loopback endpoint.
        guard canStartBundledComfy(endpoint) else { return false }
        for _ in 0..<3 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if await comfyReady(endpoint) { return true }
        }
        if try !startInstalledComfy(paths: paths), !openComfy() { return false }
        for _ in 0..<60 {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            if await comfyReady(endpoint) { return true }
            if let process = comfyProcess, !process.isRunning { break }
        }
        return false
    }

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
    @discardableResult static func openModelApp() -> Bool {
        if NSWorkspace.shared.runningApplications.contains(where: { ["Bionic", "LM Studio"].contains($0.localizedName ?? "") }) { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in ["/Applications/LM Studio.app", "/Applications/Bionic.app", home + "/Applications/LM Studio.app", home + "/Applications/Bionic.app"] where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()); return true
        }
        return false
    }
    @discardableResult static func openComfy() -> Bool {
        let path = "/Applications/Comfy Desktop.app"
        if FileManager.default.fileExists(atPath: path) { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: .init()); return true }
        return false
    }
}
