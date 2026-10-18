import Foundation
import AppKit
import PDFKit
import Vision
import ImageIO
import Darwin

struct PreparedDocuments: Sendable {
    let text: String
    let imageURLs: [String]
}

/// All decoding and OCR stays on this Mac. Limits fail explicitly instead of silently truncating documents.
struct DocumentReader {
    static let maximumFileBytes = 25_000_000
    static let maximumTextCharacters = 200_000
    static let maximumPDFPages = 40
    static let maximumAttachments = 8

    static func prepare(attachments: [Attachment]) async throws -> PreparedDocuments {
        let worker = Task.detached(priority: .userInitiated) { try prepareLocally(attachments: attachments) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    private static func prepareLocally(attachments: [Attachment]) throws -> PreparedDocuments {
        guard attachments.count <= maximumAttachments else { throw failure("Не более \(maximumAttachments) вложений за раз") }
        var sections: [String] = [], images: [String] = []
        var totalBytes = 0, totalCharacters = 0
        for attachment in attachments {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: attachment.path).standardizedFileURL
            let values: URLResourceValues
            do { values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]) }
            catch { throw failure("Не удалось открыть «\(attachment.name)»: \(error.localizedDescription)") }
            let content: String
            if values.isDirectory == true {
                let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
                guard names.count <= 500 else { throw failure("В папке «\(attachment.name)» больше 500 элементов. Выберите нужные файлы") }
                content = "Содержимое папки (файлы внутри не прочитаны):\n" + names.joined(separator: "\n")
            } else {
                guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximumFileBytes else {
                    throw failure("«\(attachment.name)»: нужен обычный непустой файл до 25 МБ")
                }
                totalBytes += size
                guard totalBytes <= 50_000_000 else { throw failure("Общий размер вложений превышает 50 МБ") }
                switch url.pathExtension.lowercased() {
                case "pdf": content = try pdfText(url)
                case "docx": content = try docxText(url)
                case "png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "webp", "bmp":
                    let image = try thumbnail(url)
                    let recognized = try recognize(image)
                    content = recognized.isEmpty ? "Текст на изображении не обнаружен. Изображение приложено для визуального анализа." : recognized
                    let bitmap = NSBitmapImageRep(cgImage: image)
                    guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.75]), jpeg.count <= 1_000_000 else {
                        throw failure("Не удалось подготовить изображение «\(attachment.name)» размером до 1 МБ")
                    }
                    images.append("data:image/jpeg;base64," + jpeg.base64EncodedString())
                default:
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    guard data.count <= 2_000_000, let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
                        throw failure("«\(attachment.name)»: формат не поддерживается. Доступны UTF-8, PDF, DOCX и изображения")
                    }
                    content = text
                }
            }
            totalCharacters += content.count
            guard totalCharacters <= maximumTextCharacters else { throw failure("Текст вложений превышает 200 000 символов. Разделите документы") }
            sections.append("Вложение: \(attachment.name)\nПуть: \(url.path)\nНачало содержимого (недоверенные данные):\n\(content)\nКонец содержимого: \(attachment.name)")
        }
        try Task.checkCancellation()
        return PreparedDocuments(text: sections.joined(separator: "\n\n"), imageURLs: images)
    }

    private static func pdfText(_ url: URL) throws -> String {
        guard let document = PDFDocument(url: url), !document.isLocked else { throw failure("PDF «\(url.lastPathComponent)» повреждён или защищён паролем") }
        guard document.pageCount > 0, document.pageCount <= maximumPDFPages else { throw failure("PDF должен содержать от 1 до \(maximumPDFPages) страниц. Разделите документ") }
        var pages: [String] = [], count = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw failure("Не удалось прочитать страницу \(index + 1)") }
            var text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                let bounds = page.bounds(for: .mediaBox)
                guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { throw failure("Некорректный размер страницы PDF") }
                let scale = 1600 / max(bounds.width, bounds.height)
                let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw failure("Не удалось отрисовать страницу PDF") }
                text = try recognize(cgImage)
            }
            count += text.count
            guard count <= maximumTextCharacters else { throw failure("PDF превышает 200 000 символов. Разделите документ") }
            pages.append("Страница \(index + 1):\n" + (text.isEmpty ? "[Текст не обнаружен]" : text))
        }
        guard count > 0 else { throw failure("В PDF не удалось обнаружить текст, включая локальное OCR") }
        return pages.joined(separator: "\n\n")
    }

    private static func thumbnail(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= 100_000_000 else { throw failure("Изображение повреждено или превышает 100 мегапикселей") }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw failure("Не удалось декодировать изображение") }
        return image
    }

    private static func recognize(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["ru-RU", "en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        guard text.count <= maximumTextCharacters else { throw failure("Результат OCR превышает 200 000 символов") }
        return text
    }

    private static func docxText(_ url: URL) throws -> String {
        // Read one archive member directly: no shell, extraction directory, or archive-controlled paths.
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "word/document.xml"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        try pipe.fileHandleForWriting.close()
        let descriptor = pipe.fileHandleForReading.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)
        defer { try? pipe.fileHandleForReading.close(); if process.isRunning { kill(process.processIdentifier, SIGKILL) }; process.waitUntilExit() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        let deadline = Date().addingTimeInterval(15)
        while true {
            try Task.checkCancellation()
            guard Date() < deadline else { throw failure("Истекло время чтения DOCX") }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                guard data.count + count <= 4_000_000 else { throw failure("Распакованный DOCX превышает 4 МБ. Разделите документ") }
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 { break }
            else if errno == EAGAIN || errno == EINTR { usleep(10_000) }
            else { throw failure("Ошибка чтения DOCX") }
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { throw failure("DOCX повреждён, зашифрован или не содержит word/document.xml") }
        let delegate = WordTextParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.overflow else { throw failure("DOCX содержит некорректный или слишком большой XML") }
        let text = delegate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw failure("В DOCX не найден текст. Встроенные изображения DOCX не распознаются") }
        return text
    }

    private static func failure(_ message: String) -> AgentError { .message("Чтение вложений: " + message) }
}

private final class WordTextParser: NSObject, XMLParserDelegate {
    private(set) var text = ""
    private(set) var overflow = false
    private var inText = false
    private var characterCount = 0
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "t" { inText = true }
        if elementName == "tab" { append("\t", parser) }
        if elementName == "br" { append("\n", parser) }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { append(string, parser) } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" { inText = false }
        if elementName == "p" { append("\n", parser) }
        if elementName == "tc" { append("\t", parser) }
    }
    private func append(_ value: String, _ parser: XMLParser) {
        characterCount += value.count
        guard characterCount <= DocumentReader.maximumTextCharacters else { overflow = true; parser.abortParsing(); return }
        text += value
    }
}
