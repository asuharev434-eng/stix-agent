import Foundation

struct LocalModelChoice: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let url: URL
    let bytes: Int64
    let bundled: Bool
}

enum LocalModelLibrary {
    private static let maxBytes: Int64 = 3_000_000_000

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("STIXRemote/Models", isDirectory: true)
    }

    static func available() -> [LocalModelChoice] {
        var result: [LocalModelChoice] = []
        if let bundled = Bundle.main.url(forResource: "Qwen3-1.7B-Q4_K_M", withExtension: "gguf", subdirectory: "Models"),
           let size = fileSize(bundled) {
            result.append(.init(id: "bundled-qwen3-1.7b", name: "Qwen3 1.7B · встроенная",
                                url: bundled, bytes: size, bundled: true))
        }
        let imports = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles])) ?? []
        for url in imports.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension.lowercased() == "gguf" {
            guard let size = fileSize(url), size > 1_000_000, size <= maxBytes else { continue }
            result.append(.init(id: url.lastPathComponent, name: url.deletingPathExtension().lastPathComponent,
                                url: url, bytes: size, bundled: false))
        }
        return result
    }

    static func importGGUF(from source: URL) throws -> LocalModelChoice {
        guard source.pathExtension.lowercased() == "gguf" else { throw LocalModelError.invalidFormat }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard let size = fileSize(source), size > 1_000_000, size <= maxBytes else {
            throw LocalModelError.invalidSize
        }
        let handle = try FileHandle(forReadingFrom: source)
        let magic = try handle.read(upToCount: 4)
        try handle.close()
        guard magic == Data("GGUF".utf8) else { throw LocalModelError.invalidFormat }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let readableName = source.deletingPathExtension().lastPathComponent
            .unicodeScalars.filter { CharacterSet.alphanumerics.union(.init(charactersIn: " -_." )).contains($0) }
            .prefix(64).map(String.init).joined()
        let name = readableName.isEmpty ? "Модель" : readableName
        let target = directory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).gguf")
        let temporary = directory.appendingPathComponent(".import-\(UUID().uuidString)")
        do {
            try FileManager.default.copyItem(at: source, to: temporary)
            guard fileSize(temporary) == size else { throw LocalModelError.copyFailed }
            try FileManager.default.moveItem(at: temporary, to: target)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: target.path)
            return .init(id: target.lastPathComponent, name: name, url: target, bytes: size, bundled: false)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
    }
}

enum LocalModelError: LocalizedError {
    case invalidFormat, invalidSize, copyFailed
    var errorDescription: String? {
        switch self {
        case .invalidFormat: "Выберите файл модели GGUF."
        case .invalidSize: "Файл GGUF должен быть от 1 МБ до 3 ГБ для этого iPhone."
        case .copyFailed: "Не удалось полностью скопировать модель на iPhone."
        }
    }
}
