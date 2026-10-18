import XCTest
import AppKit
import PDFKit
import CoreText
@testable import STIXAgent

final class DocumentReaderTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func prepare(_ url: URL) async throws -> PreparedDocuments {
        try await DocumentReader.prepare(attachments: [Attachment(path: url.path, kind: "file")])
    }

    func testUTF8AndMissingOrBinaryFiles() async throws {
        let directory = try temporaryDirectory()
        let text = directory.appendingPathComponent("notes.txt")
        try Data("Локальный документ\nHello".utf8).write(to: text)
        let result = try await prepare(text)
        XCTAssertTrue(result.text.contains("Локальный документ\nHello"))
        XCTAssertTrue(result.imageURLs.isEmpty)
        do { _ = try await prepare(directory.appendingPathComponent("missing.txt")); XCTFail("Missing file accepted") } catch {}
        let binary = directory.appendingPathComponent("binary.bin")
        try Data([0, 1, 2, 255]).write(to: binary)
        do { _ = try await prepare(binary); XCTFail("Binary file accepted") } catch {}
    }

    func testOversizedTextAndAttachmentCountFailExplicitly() async throws {
        let directory = try temporaryDirectory()
        let text = directory.appendingPathComponent("large.txt")
        try Data(String(repeating: "x", count: 200_001).utf8).write(to: text)
        do { _ = try await prepare(text); XCTFail("Oversized content accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("200 000")) }
        do { _ = try await DocumentReader.prepare(attachments: Array(repeating: Attachment(path: text.path, kind: "file"), count: 9)); XCTFail("Too many attachments accepted") } catch {}
    }

    func testPDFTextExtractionAndPageLimit() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("document.pdf")
        let data = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: data))
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 50, y: 700)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Local PDF text", attributes: [.font: NSFont.systemFont(ofSize: 24)]))
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        try (data as Data).write(to: url)
        let result = try await prepare(url)
        XCTAssertTrue(result.text.contains("Local PDF text"))
        let pdf = try XCTUnwrap(PDFDocument(url: url))
        let sourcePage = try XCTUnwrap(pdf.page(at: 0))
        for index in 1...40 { pdf.insert(try XCTUnwrap(sourcePage.copy() as? PDFPage), at: index) }
        XCTAssertTrue(pdf.write(to: url))
        do { _ = try await prepare(url); XCTFail("41 pages accepted") } catch { XCTAssertTrue(error.localizedDescription.contains("40")) }
    }

    @MainActor
    private static func writeImage(to url: URL) throws {
        let image = NSImage(size: NSSize(width: 1200, height: 400))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 1200, height: 400).fill()
        NSAttributedString(string: "LOCAL DOCUMENT 12345", attributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black]).draw(at: NSPoint(x: 30, y: 160))
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    func testLocalImageOCRAndResizedJPEGPayload() async throws {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("scan.png")
        try await Self.writeImage(to: url)
        let result = try await prepare(url)
        XCTAssertTrue(result.text.contains("12345"))
        let payload = try XCTUnwrap(result.imageURLs.first)
        XCTAssertTrue(payload.hasPrefix("data:image/jpeg;base64,"))
        let data = try XCTUnwrap(Data(base64Encoded: String(payload.dropFirst("data:image/jpeg;base64,".count))))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertLessThanOrEqual(max(bitmap.pixelsWide, bitmap.pixelsHigh), 1600)
        XCTAssertLessThanOrEqual(data.count, 1_000_000)
        let scannedPDF = directory.appendingPathComponent("scan.pdf")
        let pdf = PDFDocument()
        pdf.insert(try XCTUnwrap(PDFPage(image: try XCTUnwrap(NSImage(contentsOf: url)))), at: 0)
        XCTAssertTrue(pdf.write(to: scannedPDF))
        let pdfResult = try await prepare(scannedPDF)
        XCTAssertTrue(pdfResult.text.contains("12345"))
    }

    func testDOCXParagraphsEntitiesAndInvalidArchive() async throws {
        let directory = try temporaryDirectory()
        let word = directory.appendingPathComponent("word")
        try FileManager.default.createDirectory(at: word, withIntermediateDirectories: true)
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Hello &amp; local</w:t></w:r></w:p><w:p><w:r><w:t>Вторая строка</w:t></w:r></w:p></w:body></w:document>
        """
        try Data(xml.utf8).write(to: word.appendingPathComponent("document.xml"))
        // A hostile filename verifies argument arrays are used instead of shell interpolation.
        let url = directory.appendingPathComponent("fixture $(touch NEVER).docx")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", url.path, "word/document.xml"]
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let result = try await prepare(url)
        XCTAssertTrue(result.text.contains("Hello & local\nВторая строка"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("NEVER").path))
        try Data("invalid".utf8).write(to: url)
        do { _ = try await prepare(url); XCTFail("Corrupt DOCX accepted") } catch {}
    }
}
