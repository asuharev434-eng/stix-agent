import CoreML
import Foundation
import StableDiffusion
import UIKit

enum LocalImageError: LocalizedError {
    case modelMissing, rejected, saveFailed
    var errorDescription: String? {
        switch self {
        case .modelMissing: "Модель изображений не установлена на iPhone."
        case .rejected: "Модель не создала изображение. Попробуйте изменить запрос."
        case .saveFailed: "Не удалось сохранить готовое изображение."
        }
    }
}

enum LocalImageEvent {
    case progress(Int, Int)
    case image(URL)
}

struct LocalImageGeneration {
    let stream: AsyncThrowingStream<LocalImageEvent, Error>
    let cancel: () -> Void
}

enum LocalImageEngine {
    static func start(prompt: String, resources: URL, sourceImage: Data? = nil) -> LocalImageGeneration {
        let (stream, continuation) = AsyncThrowingStream<LocalImageEvent, Error>.makeStream()
        let worker = Task.detached(priority: .userInitiated) {
            do {
                guard FileManager.default.fileExists(atPath: resources.appendingPathComponent("Unet.mlmodelc").path)
                    else { throw LocalImageError.modelMissing }
                try Task.checkCancellation()
                let configuration = MLModelConfiguration()
                configuration.computeUnits = .cpuAndNeuralEngine
                let pipeline = try StableDiffusionPipeline(resourcesAt: resources, controlNet: [],
                                                           configuration: configuration, disableSafety: true,
                                                           reduceMemory: true)
                defer { pipeline.unloadResources() }
                var options = PipelineConfiguration(prompt: prompt)
                options.imageCount = 1
                options.stepCount = 16
                options.guidanceScale = 7.0
                options.seed = UInt32.random(in: 0...UInt32.max)
                if let sourceImage {
                    guard let image = UIImage(data: sourceImage) else { throw LocalImageError.rejected }
                    let rendered = UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512)).image { _ in
                        image.draw(in: CGRect(x: 0, y: 0, width: 512, height: 512))
                    }
                    guard let cgImage = rendered.cgImage else { throw LocalImageError.rejected }
                    options.startingImage = cgImage
                    options.strength = 0.65
                }
                let result = try pipeline.generateImages(configuration: options) { step in
                    continuation.yield(.progress(step.step + 1, step.stepCount))
                    return !Task.isCancelled
                }
                try Task.checkCancellation()
                guard let image = result.first ?? nil else { throw LocalImageError.rejected }
                let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("STIXRemote/Images", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let output = folder.appendingPathComponent("STIX-\(UUID().uuidString).png")
                guard let data = UIImage(cgImage: image).pngData() else { throw LocalImageError.saveFailed }
                try data.write(to: output, options: .atomic)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                      ofItemAtPath: output.path)
                continuation.yield(.image(output))
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { @Sendable _ in worker.cancel() }
        return LocalImageGeneration(stream: stream, cancel: { worker.cancel() })
    }
}
