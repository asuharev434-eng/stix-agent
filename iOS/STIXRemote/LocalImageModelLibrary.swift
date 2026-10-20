import Foundation

struct LocalImageModelChoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL
    let bundled: Bool
    let supportsEditing: Bool
}

enum LocalImageModelLibrary {
    private static let required = ["Unet.mlmodelc", "TextEncoder.mlmodelc", "VAEDecoder.mlmodelc", "vocab.json", "merges.txt"]

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("STIXRemote/ImageModels", isDirectory: true)
    }

    static func available() -> [LocalImageModelChoice] {
        var result: [LocalImageModelChoice] = []
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Models/CoreML-SD15-Palettized", isDirectory: true),
           isValid(bundled) {
            result.append(.init(id: "bundled-sd15", name: "Stable Diffusion 1.5 · встроенная",
                                url: bundled, bundled: true, supportsEditing: supportsEditing(bundled)))
        }
        let imports = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        for url in imports.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where isValid(url) {
            result.append(.init(id: url.lastPathComponent, name: url.lastPathComponent,
                                url: url, bundled: false, supportsEditing: supportsEditing(url)))
        }
        return result
    }

    static func importCoreML(from source: URL) throws -> LocalImageModelChoice {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard isValid(source) else { throw LocalImageModelError.invalidFormat }
        let size = try FileManager.default.allocatedSizeOfDirectory(at: source)
        guard size > 0, size <= 4_000_000_000 else { throw LocalImageModelError.invalidSize }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = source.lastPathComponent.unicodeScalars
            .filter { CharacterSet.alphanumerics.union(.init(charactersIn: " -_." )).contains($0) }
            .prefix(64).map(String.init).joined()
        let target = directory.appendingPathComponent("\(name.isEmpty ? "CoreML" : name)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let temporary = directory.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            guard isValid(temporary) else { throw LocalImageModelError.invalidFormat }
            try FileManager.default.moveItem(at: temporary, to: target)
            return .init(id: target.lastPathComponent, name: target.lastPathComponent,
                         url: target, bundled: false, supportsEditing: supportsEditing(target))
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func isValid(_ url: URL) -> Bool {
        required.allSatisfy { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    private static func supportsEditing(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent("VAEEncoder.mlmodelc").path)
    }
}

private extension FileManager {
    func allocatedSizeOfDirectory(at url: URL) throws -> Int64 {
        guard let enumerator = enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                          options: [.skipsHiddenFiles]) else { throw LocalImageModelError.invalidFormat }
        var result: Int64 = 0
        for case let file as URL in enumerator {
            result += Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            if result > 4_000_000_000 { break }
        }
        return result
    }
}

enum LocalImageModelError: LocalizedError {
    case invalidFormat, invalidSize
    var errorDescription: String? {
        switch self {
        case .invalidFormat: "Выберите папку Core ML Stable Diffusion с Unet, TextEncoder, VAEDecoder и токенизатором."
        case .invalidSize: "Размер модели изображений должен быть до 4 ГБ."
        }
    }
}
