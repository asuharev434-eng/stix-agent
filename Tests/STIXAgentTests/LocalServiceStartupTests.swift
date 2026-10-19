import XCTest
@testable import STIXAgent

final class LocalServiceStartupTests: XCTestCase {
    @MainActor func testReadyModelSelectionPrefersConfiguredServiceAndRejectsExternalCandidate() async {
        var probed: [String] = []
        let preferred = "http://127.0.0.1:1235"
        let result = await LocalServices.firstReadyModelEndpoint(preferred: preferred,
            candidates: ["https://example.com", "http://127.0.0.1:1234", preferred]) { endpoint in
            probed.append(endpoint)
            return endpoint == "http://127.0.0.1:1234"
        }
        XCTAssertEqual(result, "http://127.0.0.1:1234")
        XCTAssertEqual(probed, [preferred, "http://127.0.0.1:1234"])
    }

    @MainActor func testReadyModelDoesNotProbeOtherEndpointsWhenPreferredIsLive() async {
        var count = 0
        let preferred = "http://127.0.0.1:1235"
        let result = await LocalServices.firstReadyModelEndpoint(preferred: preferred,
            candidates: ["http://127.0.0.1:1234"]) { _ in count += 1; return true }
        XCTAssertEqual(result, preferred)
        XCTAssertEqual(count, 1)
    }

    @MainActor func testCustomComfyEndpointDoesNotStartBundledServer() async throws {
        XCTAssertTrue(LocalServices.canStartBundledComfy("http://127.0.0.1:8188"))
        XCTAssertTrue(LocalServices.canStartBundledComfy("http://localhost:8188"))
        XCTAssertFalse(LocalServices.canStartBundledComfy("http://0.0.0.0:8188"))
        XCTAssertFalse(LocalServices.canStartBundledComfy("https://example.com:8188"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let ready = try await LocalServices.ensureComfyServer(endpoint: "http://127.0.0.1:1", paths: .init(root: root))
        XCTAssertFalse(ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
