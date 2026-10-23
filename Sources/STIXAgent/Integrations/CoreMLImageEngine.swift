import CoreImage
import CoreML
import CryptoKit
import Foundation
import ImageIO
import StableDiffusion
import UniformTypeIdentifiers

private struct CoreMLAssetManifest: Decodable {
    struct Item: Decodable { let size: Int64; let sha256: String? }
    let repository: String
    let revision: String
    let files: [String: Item]
}

private final class ImageProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let continuation: AsyncThrowingStream<(Int, Int), Error>.Continuation

    init(_ continuation: AsyncThrowingStream<(Int, Int), Error>.Continuation) {
        self.continuation = continuation
    }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func step(_ value: Int, total: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        continuation.yield((value, total))
        return true
    }
    func finish(_ error: Error? = nil) {
        if let error { continuation.finish(throwing: error) }
        else { continuation.finish() }
    }
}

actor CoreMLImageEngine: ImageInferenceEngine {
    static let modelID = "sd15-palettized-512"
    let resources: URL
    private var validated = false
    private var busy = false

    init(resources: URL) { self.resources = resources }

    static func bundled() -> CoreMLImageEngine? {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Models/CoreML-SD15-Palettized"),
              FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path) else { return nil }
        return CoreMLImageEngine(resources: root)
    }

    func models() async throws -> [ModelDescriptor] {
        try validateResources()
        return [ModelDescriptor(id: "builtin-image:" + Self.modelID, kind: "image")]
    }

    func releaseIfIdle() async throws {}

    func generate(request: ImageRequest, model: String, outputDirectory: URL,
                  workflow: JSONValue?,
                  onStepProgress: @escaping @Sendable (Int, Int) async -> Void,
                  onProgress: @escaping @Sendable (String) async -> Void) async throws -> [URL] {
        guard model == Self.modelID else { throw AgentError.message("Встроенная модель изображений не найдена") }
        guard workflow == nil else { throw AgentError.message("Пользовательский workflow работает только через ComfyUI") }
        guard !busy else { throw AgentError.message("Встроенная модель изображений уже работает") }
        busy = true
        defer { busy = false }
        let request = try request.validated()
        guard outputDirectory.isFileURL else { throw AgentError.message("Нужна локальная папка изображений") }
        guard request.seed <= UInt32.max else { throw AgentError.message("Встроенная модель поддерживает seed до \(UInt32.max)") }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        if request.resizeOnly {
            guard let path = request.inputImagePath else { throw AgentError.message("Не найдено исходное изображение") }
            let image = try Self.loadImage(URL(fileURLWithPath: path))
            let resized = try Self.resize(image, width: request.width, height: request.height)
            return [try Self.writePNG(resized, to: outputDirectory)]
        }
        guard request.width == 512, request.height == 512 else {
            throw AgentError.message("Встроенная SD 1.5 создаёт изображения 512×512. Укажите --size 512x512 или выберите ComfyUI для другого размера.")
        }
        guard request.inputImagePath == nil || request.denoise < 1 else {
            throw AgentError.message("Для правки исходного изображения укажите denoise ниже 1")
        }
        try validateResources()
        let source = try request.inputImagePath.map { try Self.loadImage(URL(fileURLWithPath: $0)) }
        let sourceMask = try request.maskImagePath.map { try Self.loadImage(URL(fileURLWithPath: $0)) }
        if let source, let sourceMask, (source.width != sourceMask.width || source.height != sourceMask.height) {
            throw AgentError.message("Маска должна совпадать с размером исходного изображения")
        }
        let input = try source.map { try Self.squareForModel($0) }
        let mask = try sourceMask.map { try Self.squareForModel($0) }
        await onProgress(input == nil ? "Генерация встроенной Core ML моделью…" : "Редактирование встроенной Core ML моделью…")
        let resources = self.resources
        var state: ImageProgressState?
        let stream = AsyncThrowingStream<(Int, Int), Error> { continuation in
            state = ImageProgressState(continuation)
        }
        guard let state else { throw AgentError.message("Не удалось начать генерацию") }
        let worker = Task.detached(priority: .userInitiated) { () throws -> [URL] in
            do {
                let configuration = MLModelConfiguration()
                configuration.computeUnits = .cpuAndGPU
                let pipeline = try StableDiffusionPipeline(resourcesAt: resources, controlNet: [],
                                                           configuration: configuration, disableSafety: true,
                                                           reduceMemory: true)
                try pipeline.loadResources()
                defer { pipeline.unloadResources() }
                var options = PipelineConfiguration(prompt: request.prompt)
                options.negativePrompt = request.negativePrompt
                options.imageCount = request.count
                options.stepCount = request.steps
                options.seed = UInt32(request.seed)
                options.guidanceScale = Float(request.cfg)
                options.disableSafety = true
                options.startingImage = try input.map { original in
                    try mask.map { try Self.desaturateMaskedRegion(original: original, mask: $0) } ?? original
                }
                options.strength = Float(request.denoise)
                let generated = try pipeline.generateImages(configuration: options) { progress in
                    state.step(progress.step + 1, total: progress.stepCount)
                }
                try Task.checkCancellation()
                guard generated.count == request.count, generated.allSatisfy({ $0 != nil }) else {
                    throw AgentError.message("Генерация прервана или модель отклонила результат")
                }
                var written: [URL] = []
                do {
                    for item in generated {
                        try Task.checkCancellation()
                        guard let image = item else { throw AgentError.message("Пустой результат Core ML") }
                        let result = try mask.flatMap { mask -> CGImage? in
                            guard let input else { return nil }
                            return try Self.composite(new: image, original: input, mask: mask)
                        } ?? image
                        written.append(try Self.writePNG(result, to: outputDirectory))
                    }
                    state.finish()
                    return written
                } catch {
                    for url in written { try? FileManager.default.removeItem(at: url) }
                    throw error
                }
            } catch {
                state.finish(error)
                throw error
            }
        }
        try await withTaskCancellationHandler {
            for try await (step, total) in stream { await onStepProgress(step, total) }
        } onCancel: { state.cancel() }
        let results = try await worker.value
        await onProgress("Изображение сохранено")
        return results
    }

    private func validateResources() throws {
        guard !validated else { return }
        let manifestURL = resources.appendingPathComponent("manifest.json")
        let manifest = try JSONDecoder().decode(CoreMLAssetManifest.self, from: Data(contentsOf: manifestURL))
        let approvedSources = [
            "apple/coreml-stable-diffusion-v1-5-palettized": "04a6a0bdd66fb8da470c14e56d762343ef579d88",
            "apple/coreml-stable-diffusion-v1-5": "c63580e549bc0ca6c27381d0640c1eb1b68b00b1"
        ]
        guard approvedSources[manifest.repository] == manifest.revision,
              manifest.files.count >= 25,
              ["TextEncoder.mlmodelc/weights/weight.bin", "Unet.mlmodelc/weights/weight.bin",
               "VAEDecoder.mlmodelc/weights/weight.bin", "VAEEncoder.mlmodelc/weights/weight.bin",
               "SafetyChecker.mlmodelc/weights/weight.bin",
               "vocab.json", "merges.txt"].allSatisfy({ manifest.files[$0] != nil }) else {
            throw AgentError.message("Комплект встроенной модели изображений неполон")
        }
        for (relative, entry) in manifest.files {
            guard !relative.contains(".."), !relative.hasPrefix("/"), entry.size > 0 else {
                throw AgentError.message("Некорректный путь в manifest изображений")
            }
            let url = resources.appendingPathComponent(relative)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber,
                  size.int64Value == entry.size else {
                throw AgentError.message("Повреждён ресурс модели изображений: \(relative)")
            }
            if let expected = entry.sha256 {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                var digest = SHA256()
                while true {
                    let chunk = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
                    if chunk.isEmpty { break }
                    digest.update(data: chunk)
                }
                let actual = digest.finalize().map { String(format: "%02x", $0) }.joined()
                guard actual == expected else { throw AgentError.message("Хеш ресурса модели изображений не совпадает: \(relative)") }
            }
        }
        validated = true
    }

    private static func loadImage(_ url: URL) throws -> CGImage {
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw AgentError.message("Не удалось прочитать исходное изображение")
        }
        return image
    }

    private static func resize(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AgentError.message("Не удалось создать изображение заданного размера")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else { throw AgentError.message("Не удалось изменить размер изображения") }
        return resized
    }

    /// Core ML SD 1.5 has a fixed square latent. Crop the source and mask identically,
    /// preserving proportions rather than stretching a portrait or landscape photo.
    static func squareForModel(_ image: CGImage) throws -> CGImage {
        guard image.width > 0, image.height > 0, image.width <= 16_384,
              image.height <= min(16_384, 32_000_000 / image.width),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AgentError.message("Не удалось подготовить исходное изображение")
        }
        let scale = max(512.0 / Double(image.width), 512.0 / Double(image.height))
        let width = Double(image.width) * scale, height = Double(image.height) * scale
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (512 - width) / 2, y: (512 - height) / 2, width: width, height: height))
        guard let result = context.makeImage() else { throw AgentError.message("Не удалось подготовить исходное изображение") }
        return result
    }

    static func composite(new: CGImage, original: CGImage, mask: CGImage) throws -> CGImage {
        guard let filter = CIFilter(name: "CIBlendWithMask") else { throw AgentError.message("Системный фильтр маски недоступен") }
        filter.setValue(CIImage(cgImage: new), forKey: kCIInputImageKey)
        filter.setValue(CIImage(cgImage: original), forKey: kCIInputBackgroundImageKey)
        filter.setValue(CIImage(cgImage: mask), forKey: kCIInputMaskImageKey)
        guard let output = filter.outputImage,
              let image = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: output.extent) else {
            throw AgentError.message("Не удалось применить маску к изображению")
        }
        return image
    }

    private static func desaturateMaskedRegion(original: CGImage, mask: CGImage) throws -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        guard let color = CIFilter(name: "CIColorControls"),
              let blend = CIFilter(name: "CIBlendWithMask") else {
            throw AgentError.message("Системные фильтры подготовки маски недоступны")
        }
        color.setValue(CIImage(cgImage: original), forKey: kCIInputImageKey)
        color.setValue(0, forKey: kCIInputSaturationKey)
        guard let neutral = color.outputImage else { throw AgentError.message("Не удалось подготовить область правки") }
        blend.setValue(neutral, forKey: kCIInputImageKey)
        blend.setValue(CIImage(cgImage: original), forKey: kCIInputBackgroundImageKey)
        blend.setValue(CIImage(cgImage: mask), forKey: kCIInputMaskImageKey)
        guard let output = blend.outputImage,
              let image = CIContext(options: [.useSoftwareRenderer: false]).createCGImage(output, from: extent) else {
            throw AgentError.message("Не удалось подготовить маску для Core ML")
        }
        return image
    }

    private static func writePNG(_ image: CGImage, to directory: URL) throws -> URL {
        let final = directory.appendingPathComponent("STIX-\(UUID().uuidString).png")
        let temporary = directory.appendingPathComponent(".stix-image-\(UUID().uuidString).png")
        do {
            guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw AgentError.message("Не удалось создать PNG")
            }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { throw AgentError.message("Не удалось сохранить PNG") }
            try FileManager.default.moveItem(at: temporary, to: final)
            return final
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
