import Foundation
import Darwin

/// A single MCP session. Each configured plugin owns its own process or HTTP session.
actor MCPClient {
    private let config: PluginConfig
    private let environment: [String: String]
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var buffer = Data()
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var timers: [Int: Task<Void, Never>] = [:]
    private var nextID = 0
    private var writer: Task<Void, Error>?
    private var initialized = false
    private var initialization: Task<Void, Error>?
    private var sessionID: String?
    private var closed = false
    private let session: URLSession
    static let maximumBytes = 4 * 1024 * 1024
    private let timeout: UInt64 = 30_000_000_000

    init(config: PluginConfig, environment: [String: String] = [:]) {
        self.environment = environment
        self.config = config
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 30
        settings.timeoutIntervalForResource = 30
        settings.httpShouldSetCookies = false
        self.session = URLSession(configuration: settings)
    }

    func tools() async throws -> [ToolDefinition] {
        try await ensureInitialized()
        var result: [ToolDefinition] = []
        var cursor: String?
        var seen = Set<String>()
        repeat {
            let page = try await request("tools/list", params: .object(cursor.map { ["cursor": .string($0)] } ?? [:]))
            guard let tools = page["tools"].array else { throw failure("Invalid tools/list response") }
            for tool in tools {
                let name = try tool.requiredString("name")
                guard tool["inputSchema"].object != nil else { throw failure("Invalid tool input schema") }
                result.append(ToolDefinition(name: name, description: tool["description"].string ?? "", parameters: tool["inputSchema"]))
            }
            guard result.count <= 10_000 else { throw failure("Too many MCP tools") }
            cursor = page["nextCursor"].string
            if let cursor = cursor, !seen.insert(cursor).inserted { throw failure("Repeated MCP pagination cursor") }
        } while cursor != nil
        return result
    }

    func call(name: String, arguments: JSONValue) async throws -> JSONValue {
        guard !name.isEmpty, arguments.object != nil else { throw failure("Invalid tool call") }
        try await ensureInitialized()
        return try await request("tools/call", params: .object(["name": .string(name), "arguments": arguments]))
    }

    func close() async {
        closed = true
        initialization?.cancel()
        initialization = nil
        initialized = false
        writer?.cancel()
        writer = nil
        input?.closeFile()
        output?.readabilityHandler = nil
        errors?.readabilityHandler = nil
        output?.closeFile()
        errors?.closeFile()
        input = nil; output = nil; errors = nil
        if let process = process, process.isRunning {
            process.terminate()
            // A plugin must not outlive its owning session, even if it ignores SIGTERM.
            kill(process.processIdentifier, SIGKILL)
        }
        process = nil
        buffer.removeAll()
        let waiting = pending
        pending.removeAll()
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
        for continuation in waiting.values { continuation.resume(throwing: CancellationError()) }
        session.invalidateAndCancel()
    }

    private func failure(_ message: String) -> AgentError { .message("MCP: \(message)") }

    private func ensureInitialized() async throws {
        try await withTaskCancellationHandler(operation: {
            try await initializeIfNeeded()
        }, onCancel: { Task { await self.close() } })
    }

    private func initializeIfNeeded() async throws {
        try Task.checkCancellation()
        guard !closed else { throw failure("Session is closed") }
        if initialized { return }
        if let initialization = initialization { return try await initialization.value }
        let task = Task { try await self.initialize() }
        initialization = task
        do { try await task.value; initialization = nil }
        catch { initialization = nil; await close(); throw error }
    }

    private func initialize() async throws {
        let result = try await request("initialize", params: .object([
            "protocolVersion": .string("2025-03-26"), "capabilities": .object([:]),
            "clientInfo": .object(["name": .string("STIX Agent"), "version": .string("1.0")])
        ]))
        guard result["protocolVersion"].string == "2025-03-26", result["capabilities"].object != nil,
              result["serverInfo"].object != nil else { throw failure("Unsupported or invalid MCP initialization") }
        try await notify("notifications/initialized", params: .object([:]))
        initialized = true
    }

    private func request(_ method: String, params: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
        guard !closed else { throw failure("Session is closed") }
        nextID += 1
        let id = nextID
        let envelope: JSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(Double(id)), "method": .string(method), "params": params])
        if config.transport == "http" { return try await http(envelope, id: id) }
        guard config.transport == "stdio" else { throw failure("Unknown transport") }
        try startProcess()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                timers[id] = Task { [timeout] in
                    do { try await Task.sleep(nanoseconds: timeout) } catch { return }
                    await self.expire(id)
                }
                Task {
                    do { try await write(envelope) }
                    catch { finish(id, result: .failure(error)) }
                }
            }
        }, onCancel: { Task { await self.close() } })
    }

    private func expire(_ id: Int) async {
        finish(id, result: .failure(failure("Request timed out")))
        await close()
    }
    private func finish(_ id: Int, result: Result<JSONValue, Error>) {
        timers.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }
    private func notify(_ method: String, params: JSONValue) async throws {
        let value: JSONValue = .object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params])
        if config.transport == "http" { _ = try await http(value, id: nil) }
        else { try await write(value) }
    }
    private func write(_ value: JSONValue) async throws {
        guard let input = input else { throw failure("Process input unavailable") }
        var data = try JSONEncoder().encode(value)
        guard data.count < Self.maximumBytes else { throw failure("Request too large") }
        data.append(10)
        let frame = data
        let previous = writer
        let task = Task.detached {
            if let previous = previous { try await previous.value }
            try Task.checkCancellation()
            try input.write(contentsOf: frame)
        }
        writer = task
        try await task.value
    }
    private func startProcess() throws {
        if process != nil { return }
        guard !config.command.isEmpty, !config.command.contains("\0"), config.arguments.allSatisfy({ !$0.contains("\0") }) else { throw failure("Invalid executable") }
        try CredentialEnvironment.validate(environment: environment)
        let child = Process()
        if config.command.hasPrefix("/") {
            child.executableURL = URL(fileURLWithPath: config.command)
            child.arguments = config.arguments
        } else {
            guard !config.command.hasPrefix("-"), !config.command.contains("/"), !config.command.contains("=") else { throw failure("Use an absolute executable path") }
            child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            child.arguments = [config.command] + config.arguments
        }
        // Never forward API credentials from the parent application's environment.
        let inherited = ProcessInfo.processInfo.environment
        child.environment = Dictionary(uniqueKeysWithValues: ["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL"].compactMap { key in inherited[key].map { (key, $0) } })
        child.environment?.merge(environment) { _, explicit in explicit }
        let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
        child.standardInput = stdinPipe; child.standardOutput = stdoutPipe; child.standardError = stderrPipe
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        errors = stderrPipe.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { await self?.receive(data) }
        }
        // Drain without retaining or logging potentially sensitive server diagnostics.
        errors?.readabilityHandler = { handle in _ = handle.availableData }
        child.terminationHandler = { [weak self] _ in Task { await self?.processEnded() } }
        process = child
        do { try child.run() } catch { process = nil; throw error }
    }
    private func processEnded() {
        for id in Array(pending.keys) { finish(id, result: .failure(failure("Plugin process exited"))) }
    }
    private func receive(_ data: Data) async {
        if data.isEmpty { processEnded(); return }
        do {
            let messages = try MCPFraming.append(data, to: &buffer)
            for message in messages {
                // Server notifications are intentionally ignored. Server requests receive method-not-found.
                if message["method"].string != nil {
                    if message["id"] != .null {
                        try await write(.object(["jsonrpc": .string("2.0"), "id": message["id"], "error": .object(["code": .number(-32601), "message": .string("Method not supported")])]))
                    }
                    continue
                }
                guard let id = message["id"].int, pending[id] != nil else { continue }
                do { finish(id, result: .success(try MCPFraming.result(message, id: id))) }
                catch { finish(id, result: .failure(error)) }
            }
        } catch { await close() }
    }

    private func http(_ envelope: JSONValue, id: Int?) async throws -> JSONValue {
        guard let url = URL(string: config.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { throw failure("Invalid HTTP endpoint") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        if initialized { request.setValue("2025-03-26", forHTTPHeaderField: "MCP-Protocol-Version") }
        if let sessionID = sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
        request.httpBody = try JSONEncoder().encode(envelope)
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw failure("HTTP request failed") }
        if let received = response.value(forHTTPHeaderField: "Mcp-Session-Id") {
            guard received.utf8.count <= 1024, !received.contains("\r"), !received.contains("\n") else { throw failure("Invalid session header") }
            sessionID = received
        }
        if id == nil, response.statusCode == 202 { return .null }
        let sse = response.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            data.append(byte)
            guard data.count <= Self.maximumBytes else { throw failure("Response too large") }
            if sse, byte == 10, let id = id {
                for message in try MCPFraming.events(data) where message["id"].int == id {
                    return try MCPFraming.result(message, id: id)
                }
            }
        }
        if id == nil { return .null }
        let message = try JSONDecoder().decode(JSONValue.self, from: data)
        return try MCPFraming.result(message, id: id!)
    }
}

/// Pure bounded framing helpers, shared by both transports and unit tests.
enum MCPFraming {
    static func append(_ data: Data, to buffer: inout Data) throws -> [JSONValue] {
        guard buffer.count + data.count <= MCPClient.maximumBytes else { throw AgentError.message("MCP frame exceeds limit") }
        buffer.append(data)
        var messages: [JSONValue] = []
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            if line.allSatisfy({ $0 == 13 || $0 == 32 || $0 == 9 }) { continue }
            messages.append(try JSONDecoder().decode(JSONValue.self, from: line))
        }
        return messages
    }
    static func events(_ data: Data) throws -> [JSONValue] {
        let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = text.components(separatedBy: "\n\n").dropLast()
        return try blocks.compactMap { block in
            let payload = block.components(separatedBy: "\n").filter { $0.hasPrefix("data:") }.map { String($0.dropFirst(5)).trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            return payload.isEmpty ? nil : try JSONValue.parse(payload)
        }
    }
    static func result(_ message: JSONValue, id: Int) throws -> JSONValue {
        guard message["jsonrpc"].string == "2.0", message["id"] == .number(Double(id)) else { throw AgentError.message("MCP response ID or protocol mismatch") }
        if message["error"] != .null {
            // Do not expose arbitrary server error payloads that might contain credentials.
            throw AgentError.message("MCP server returned an error (\(message["error"]["code"].int ?? -32603))")
        }
        guard let object = message.object, let result = object["result"] else { throw AgentError.message("MCP response has no result") }
        return result
    }
}
