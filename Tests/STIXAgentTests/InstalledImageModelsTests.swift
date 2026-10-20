import Foundation
import XCTest
@testable import STIXAgent

final class InstalledImageModelsTests: XCTestCase {
    @MainActor func testInstalledCheckpointsAppearWithoutRunningComfyUI() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("STIX-image-models-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let checkpoints = home.appendingPathComponent("ComfyUI-Shared/models/checkpoints")
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        for name in ["sd_xl_base_1.0.safetensors", "portrait.ckpt", "download.log"] {
            try Data("model".utf8).write(to: checkpoints.appendingPathComponent(name))
        }
        let discovered = LocalServices.installedImageCheckpoints(home: home)
        XCTAssertEqual(discovered, ["portrait.ckpt", "sd_xl_base_1.0.safetensors"])
        XCTAssertEqual(LocalServices.mergedImageCheckpoints([["builtin-image:sd15-palettized-512"], discovered, discovered]).count, 3)
    }
}
