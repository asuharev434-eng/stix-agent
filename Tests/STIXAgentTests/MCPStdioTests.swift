import XCTest
import Foundation
import Darwin
@testable import STIXAgent

final class MCPStdioTests: XCTestCase {
    func testPersistentStdioSessionNegotiatesListsCallsAndClosesProcess() async throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
            throw XCTSkip("System Python is required for the local stdio fixture")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("stix-mcp-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("server.py")
        let pidFile = directory.appendingPathComponent("pid")
        let methodsFile = directory.appendingPathComponent("methods")
        let fixture = #"""
import json, os, sys
with open(sys.argv[1], "w") as f:
    f.write(str(os.getpid()))
initialized = False
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    with open(sys.argv[2], "a") as f:
        f.write(method + "\n")
    if method == "notifications/initialized":
        initialized = True
        continue
    if method == "initialize":
        assert request["params"]["protocolVersion"] == "2025-03-26"
        # More than a normal pipe buffer: a client must drain stderr continuously.
        sys.stderr.write("fixture diagnostics\n" * 5000)
        sys.stderr.flush()
        result = {"protocolVersion": "2025-03-26", "capabilities": {"tools": {}}, "serverInfo": {"name": "fixture", "version": "1"}}
    elif method == "tools/list":
        assert initialized
        result = {"tools": [{"name": "echo", "description": "Echo supplied text", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}]}
    elif method == "tools/call":
        assert initialized and request["params"]["name"] == "echo"
        result = {"content": [{"type": "text", "text": request["params"]["arguments"]["text"]}], "isError": False}
    else:
        raise RuntimeError("Unexpected method")
    # Notifications must not consume a pending response. Fragment each response, too.
    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/tools/list_changed"}) + "\n")
    response = json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}) + "\n"
    midpoint = len(response) // 2
    sys.stdout.write(response[:midpoint])
    sys.stdout.flush()
    sys.stdout.write(response[midpoint:])
    sys.stdout.flush()
"""#
        try Data(fixture.utf8).write(to: script)
        let client = MCPClient(config: PluginConfig(id: "fixture", name: "Fixture", transport: "stdio", command: "/usr/bin/python3", arguments: [script.path, pidFile.path, methodsFile.path], url: "", enabled: true))
        do {
            let tools = try await client.tools()
            XCTAssertEqual(tools.count, 1)
            XCTAssertEqual(tools.first?.name, "echo")
            XCTAssertEqual(tools.first?.description, "Echo supplied text")
            XCTAssertEqual(tools.first?.parameters["properties"]["text"]["type"].string, "string")
            let first = try await client.call(name: "echo", arguments: .object(["text": .string("Привет from stdio")]))
            XCTAssertEqual(first["content"].array?.first?["text"].string, "Привет from stdio")
            let second = try await client.call(name: "echo", arguments: .object(["text": .string("same session")]))
            XCTAssertEqual(second["content"].array?.first?["text"].string, "same session")
            let methods = try String(contentsOf: methodsFile, encoding: .utf8).split(separator: "\n").map(String.init)
            XCTAssertEqual(methods, ["initialize", "notifications/initialized", "tools/list", "tools/call", "tools/call"])
            let pidText = try String(contentsOf: pidFile, encoding: .utf8)
            let pid = try XCTUnwrap(Int32(pidText))
            await client.close()
            for _ in 0..<100 {
                if kill(pid, 0) == -1 && errno == ESRCH { break }
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let probe = kill(pid, 0)
            let probeError = errno
            XCTAssertEqual(probe, -1, "Closing the client must stop the fixture process")
            XCTAssertEqual(probeError, ESRCH)
        } catch {
            await client.close()
            throw error
        }
    }
}
