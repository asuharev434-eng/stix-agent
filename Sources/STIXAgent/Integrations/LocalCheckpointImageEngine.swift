import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImportedImageCheckpoint: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let fileName: String
    let sha256: String
    let bytes: Int64
}

private final class ImageStepParser: @unchecked Sendable {
    private let lock = NSLock()
    private var tail = ""
    private var last = 0
    private let steps: Int
    private let offset: Int
    private let total: Int
    private let callback: @Sendable (Int, Int) async -> Void

    init(steps: Int, offset: Int, total: Int, callback: @escaping @Sendable (Int, Int) async -> Void) {
        self.steps = steps; self.offset = offset; self.total = total; self.callback = callback
    }

    func feed(_ text: String) {
        lock.lock()
        tail = String((tail + text).suffix(256))
        let fragments = tail.split(separator: "\r")
        var advance: Int?
        for fragment in fragments {
            let pieces = fragment.split(separator: "/", maxSplits: 1)
            guard pieces.count == 2,
                  let denominator = Int(pieces[1].prefix(while: { $0.isNumber })), denominator == steps,
                  let numerator = Int(String(pieces[0].reversed().prefix(while: { $0.isNumber }).reversed())),
                  numerator > last, numerator <= steps else { continue }
            last = numerator; advance = numerator
        }
        lock.unlock()
        if let advance { Task { await callback(offset + advance, total) } }
    }
}

/// Runs app-owned safetensors through the bundled Metal CLI. No local HTTP service is required.
actor LocalCheckpointImageEngine: ImageInferenceEngine {
    let directory: URL
    let executable: URL
    private var records: [ImportedImageCheckpoint] = []
    private var loaded = false
    private var busy = false

    init(directory: URL, executable: URL) {
        self.directory = directory
        self.executable = executable
    }

    static func bundled(paths: AppStoragePaths) -> LocalCheckpointImageEngine? {
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("stix-sd-cli"), FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return LocalCheckpointImageEngine(directory: paths.models.appendingPathComponent("ImageCheckpoints"), executable: executable)
    }

    private var manifest: URL { directory.appendingPathComponent("manifest.json") }

    private func load() throws {
        guard !loaded else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: manifest.path) {
            records = try JSONDecoder().decode([ImportedImageCheckpoint].self, from: Data(contentsOf: manifest))
        }
        loaded = true
    }

    func models() async throws -> [ModelDescriptor] {
        try load()
        return records.map { ModelDescriptor(id: "local-image:" + $0.id, kind: "image",
                                              displayName: $0.name + " · локальная") }
    }

    func importedModels() throws -> [ImportedImageCheckpoint] {
        try load()
        return records
    }

    func importFile(_ source: URL) async throws -> ImportedImageCheckpoint {
        try load()
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard source.isFileURL, source.pathExtension.lowercased() == "safetensors" else {
            throw AgentError.message("Выберите локальный checkpoint .safetensors")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              (1024...12_000_000_000).contains(size) else {
            throw AgentError.message("Checkpoint должен быть обычным файлом размером до 12 ГБ")
        }
        let temporary = directory.appendingPathComponent(".import-" + UUID().uuidString + ".safetensors")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: source, to: temporary)
        guard (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value == size else {
            throw AgentError.message("Checkpoint изменился во время импорта")
        }
        let file = try FileHandle(forReadingFrom: temporary)
        defer { try? file.close() }
        let lengthData = try file.read(upToCount: 8) ?? Data()
        guard lengthData.count == 8 else { throw AgentError.message("Некорректный safetensors") }
        let headerLength = UInt64(littleEndian: lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
        guard headerLength > 2, headerLength <= 16_777_216, headerLength < size,
              let header = try JSONSerialization.jsonObject(with: file.read(upToCount: Int(headerLength)) ?? Data()) as? [String: Any],
              !header.isEmpty else { throw AgentError.message("Некорректный заголовок safetensors") }
        try file.seek(toOffset: 0)
        var hasher = SHA256()
        while let chunk = try file.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        if let existing = records.first(where: { $0.sha256 == digest }) { return existing }
        let id = "imported-" + String(digest.prefix(16))
        let name = source.deletingPathExtension().lastPathComponent
        let fileName = id + ".safetensors"
        let target = directory.appendingPathComponent(fileName)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw AgentError.message("Конфликт checkpoint-файла") }
        let item = ImportedImageCheckpoint(id: id, name: name, fileName: fileName, sha256: digest, bytes: size)
        try FileManager.default.moveItem(at: temporary, to: target)
        do {
            try JSONEncoder().encode(records + [item]).write(to: manifest, options: .atomic)
            records.append(item)
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        return item
    }

    func remove(_ id: String) throws {
        try load()
        guard let record = records.first(where: { $0.id == id }), !busy else {
            throw AgentError.message("Модель не найдена или сейчас используется")
        }
        let next = records.filter { $0.id != id }
        try JSONEncoder().encode(next).write(to: manifest, options: .atomic)
        records = next
        try FileManager.default.removeItem(at: directory.appendingPathComponent(record.fileName))
    }

    func releaseIfIdle() async throws {}

    func generate(request: ImageRequest, model: String, outputDirectory: URL, workflow: JSONValue?,
                  onStepProgress: @escaping @Sendable (Int, Int) async -> Void,
                  onProgress: @escaping @Sendable (String) async -> Void) async throws -> [URL] {
        try load()
        guard workflow == nil else { throw AgentError.message("Пользовательский workflow требует ComfyUI") }
        guard let record = records.first(where: { $0.id == model }) else { throw AgentError.message("Локальный checkpoint не найден") }
        guard !busy else { throw AgentError.message("Локальная модель изображений уже работает") }
        busy = true
        defer { busy = false }
        let request = try request.validated()
        let modelURL = directory.appendingPathComponent(record.fileName)
        guard (try FileManager.default.attributesOfItem(atPath: modelURL.path)[.size] as? NSNumber)?.int64Value == record.bytes,
              FileManager.default.isExecutableFile(atPath: executable.path), outputDirectory.isFileURL else {
            throw AgentError.message("Файл checkpoint или встроенный движок недоступен")
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        if request.resizeOnly {
            return [try Self.resizeImage(request, outputDirectory: outputDirectory)]
        }
        let working = outputDirectory.appendingPathComponent(".sd-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: working) }
        let promptURL = working.appendingPathComponent("prompt.txt")
        let negativeURL = working.appendingPathComponent("negative.txt")
        try Data(request.prompt.utf8).write(to: promptURL, options: .atomic)
        try Data(request.negativePrompt.utf8).write(to: negativeURL, options: .atomic)
        var outputs: [URL] = []
        do {
            for index in 0..<request.count {
                try Task.checkCancellation()
                await onProgress("Локальная SDXL: изображение \(index + 1) из \(request.count)…")
                let output = working.appendingPathComponent("result-\(index).png")
                var arguments = ["--model", modelURL.path, "--prompt-file", promptURL.path,
                                 "--negative-prompt-file", negativeURL.path, "--width", String(request.width),
                                 "--height", String(request.height), "--steps", String(request.steps),
                                 "--seed", String(request.seed + UInt64(index)), "--cfg-scale", String(request.cfg),
                                 "--batched-cfg", "off", "--output", output.path]
                if let input = request.inputImagePath {
                    arguments += ["--init-img", input, "--strength", String(request.denoise)]
                }
                if let mask = request.maskImagePath { arguments += ["--mask", mask] }
                let parser = ImageStepParser(steps: request.steps, offset: index * request.steps,
                                             total: request.count * request.steps, callback: onStepProgress)
                let result = try await ProcessRunner().runExecutable(executable.path, arguments: arguments,
                                                                     directory: working.path, timeout: 1800,
                                                                     environment: ["GGML_METAL_TENSOR_DISABLE": "1"],
                                                                     onOutput: { parser.feed(String(decoding: $0, as: UTF8.self)) })
                // stable-diffusion.cpp can return exit code 0 and write a flat gray PNG
                // after Metal reports an out-of-memory command buffer failure.
                guard result.exitCode == 0, !result.timedOut,
                      !Self.hasFatalBackendError(result.output),
                      FileManager.default.fileExists(atPath: output.path) else {
                    throw AgentError.message("SDXL: \(result.output.suffix(2000))")
                }
                let final = outputDirectory.appendingPathComponent("STIX-" + UUID().uuidString + ".png")
                try FileManager.default.moveItem(at: output, to: final)
                outputs.append(final)
                await onStepProgress((index + 1) * request.steps, request.count * request.steps)
            }
        } catch {
            for output in outputs { try? FileManager.default.removeItem(at: output) }
            throw error
        }
        await onProgress("Изображение сохранено")
        return outputs
    }

    static func hasFatalBackendError(_ output: String) -> Bool {
        output.contains("OutOfMemory") || output.contains("Insufficient Memory") ||
            output.contains("command buffer 0 failed")
    }

    private static func resizeImage(_ request: ImageRequest, outputDirectory: URL) throws -> URL {
        guard let input = request.inputImagePath,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: request.width, height: request.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AgentError.message("Не удалось прочитать изображение для изменения размера")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: request.width, height: request.height))
        guard let resized = context.makeImage(), let data = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw AgentError.message("Не удалось изменить размер изображения")
        }
        CGImageDestinationAddImage(destination, resized, nil)
        guard CGImageDestinationFinalize(destination) else { throw AgentError.message("Не удалось сохранить PNG") }
        let url = outputDirectory.appendingPathComponent("STIX-" + UUID().uuidString + ".png")
        try (data as Data).write(to: url, options: .atomic)
        return url
    }
}
