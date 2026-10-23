import Foundation
import PDFKit
import UIKit
import Vision

enum LocalPhoneTools {
    static func answer(_ command: String) throws -> String? {
        if command == "/time" {
            return Date.now.formatted(date: .complete, time: .standard)
        }
        if command.hasPrefix("/calc ") {
            let input = String(command.dropFirst(6))
            var parser = ArithmeticParser(input)
            let result = try parser.parse()
            return result.formatted()
        }
        return nil
    }

    static func describe(_ upload: MobileDraftUpload) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let suffix = URL(fileURLWithPath: upload.name).pathExtension.lowercased()
            if ["txt", "md", "json", "csv", "py", "swift", "js", "ts", "html", "css", "xml", "yaml", "yml", "log"].contains(suffix) {
                guard let text = String(data: upload.data, encoding: .utf8) else { throw LocalToolError.unreadable }
                return String(text.prefix(16_000))
            }
            if suffix == "pdf" {
                guard let document = PDFDocument(data: upload.data) else { throw LocalToolError.unreadable }
                let pages = (0..<min(document.pageCount, 20)).compactMap { document.page(at: $0)?.string }
                return String(pages.joined(separator: "\n\n").prefix(16_000))
            }
            if upload.isImage {
                let text = VNRecognizeTextRequest()
                text.recognitionLevel = .accurate
                let labels = VNClassifyImageRequest()
                try VNImageRequestHandler(data: upload.data).perform([text, labels])
                let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                let objects = (labels.results ?? []).prefix(5).map(\.identifier)
                return "Распознанный текст: \(lines.joined(separator: " | "))\nОбъекты: \(objects.joined(separator: ", "))"
            }
            throw LocalToolError.unsupported
        }.value
    }
}

private struct ArithmeticParser {
    let characters: [Character]
    var index = 0
    init(_ source: String) { characters = Array(source) }

    mutating func parse() throws -> Double {
        guard characters.count <= 200 else { throw LocalToolError.invalidExpression }
        let value = try expression()
        skipSpaces()
        guard index == characters.count, value.isFinite else { throw LocalToolError.invalidExpression }
        return value
    }

    private mutating func expression() throws -> Double {
        var value = try term()
        while true {
            skipSpaces()
            if consume("+") { value += try term() }
            else if consume("-") { value -= try term() }
            else { return value }
        }
    }

    private mutating func term() throws -> Double {
        var value = try factor()
        while true {
            skipSpaces()
            if consume("*") { value *= try factor() }
            else if consume("/") {
                let divisor = try factor()
                guard divisor != 0 else { throw LocalToolError.invalidExpression }
                value /= divisor
            } else { return value }
        }
    }

    private mutating func factor() throws -> Double {
        skipSpaces()
        if consume("-") { return -(try factor()) }
        if consume("+") { return try factor() }
        if consume("(") {
            let value = try expression()
            skipSpaces()
            guard consume(")") else { throw LocalToolError.invalidExpression }
            return value
        }
        let start = index
        while index < characters.count, characters[index].isNumber ||
                (index < characters.count && characters[index] == ".") { index += 1 }
        guard index > start, let value = Double(String(characters[start..<index])) else {
            throw LocalToolError.invalidExpression
        }
        return value
    }

    private mutating func skipSpaces() {
        while index < characters.count, characters[index].isWhitespace { index += 1 }
    }
    private mutating func consume(_ character: Character) -> Bool {
        guard index < characters.count, characters[index] == character else { return false }
        index += 1
        return true
    }
}

enum LocalToolError: LocalizedError {
    case invalidExpression, unreadable, unsupported
    var errorDescription: String? {
        switch self {
        case .invalidExpression: "Проверьте выражение: доступны +, −, ×, ÷ и скобки."
        case .unreadable: "Не удалось прочитать выбранный файл."
        case .unsupported: "На iPhone поддерживаются текст, PDF и изображения."
        }
    }
}
