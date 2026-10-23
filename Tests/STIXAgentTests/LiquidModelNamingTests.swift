import XCTest
import RemoteChatCore
@testable import STIXAgent

final class LiquidModelNamingTests: XCTestCase {
    func testPreOneLabelsKeepVersionOriginAndMobileVariant() {
        let cases = [
            "STIX-AI-0.1": "STIX Liquid 0.1-self",
            "STIX-AI-0.6-self": "STIX Liquid 0.6-self",
            "STIX-AI-0.6B-self": "STIX Liquid 0.6B-self",
            "STIX-Ai-0.2-mobile-other": "STIX Liquid 0.2-mobile-other",
            "STIX-AI-0.9-other": "STIX Liquid 0.9-other",
            "STIX-Ai-0.2-mobile-other-Q4_K_M-ABC123DE": "STIX Liquid 0.2-mobile-other",
            "STIX-AI-0.4-self · импортирована": "STIX Liquid 0.4-self · импортирована"
        ]
        for (input, expected) in cases {
            XCTAssertEqual(STIXModelNaming.displayName(input), expected)
            XCTAssertEqual(STIXModelNaming.displayName(expected), expected)
        }
        for unchanged in ["STIX-AI-1.0-self", "STIX-AI-2.0-other", "Qwen3 4B", "LiquidAI/LFM2.5-2.6B"] {
            XCTAssertEqual(STIXModelNaming.displayName(unchanged), unchanged)
        }
    }

    func testExistingImportedIDsAndMetadataStayStable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = ImportedGGUF(id: "imported-hash", name: "STIX-AI-0.6-self", fileName: "model.gguf",
                                  sha256: "recorded-hash", bytes: 21820096, architecture: "gpt2",
                                  tokenizer: "gpt2", contextLength: 256)
        let bytes = try JSONEncoder().encode([record])
        let manifest = directory.appendingPathComponent("manifest.json")
        try bytes.write(to: manifest)
        let library = LocalModelLibrary(bundled: nil, directory: directory, libraryURL: nil)
        let choices = try await library.models()
        XCTAssertEqual(choices.first?.id, "builtin-text:imported-hash")
        XCTAssertEqual(choices.first?.name, "STIX Liquid 0.6-self · импортирована")
        XCTAssertEqual(record.displayName, "STIX Liquid 0.6-self")
        XCTAssertEqual(record.name, "STIX-AI-0.6-self")
        XCTAssertEqual(try Data(contentsOf: manifest), bytes)
    }
}
