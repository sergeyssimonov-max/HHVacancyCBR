import AppKit
import Foundation
import PDFKit
import XCTest
import SwiftUI
@testable import HHVacancyCBR


final class PDFSourceEvidenceTests: XCTestCase {
    func testStreebogRFC6986AndLegacySHA256() throws {
        let first = Data("012345678901234567890123456789012345678901234567890123456789012".utf8)
        let hex = "d1e520e2e5f2f0e82c20d1f2f0e8e1eee6e820e2edf3f6e82c20e2e5fef2fa20f120eceef0ff20f1f2f0e5ebe0ece820ede020f5f0e0e1f0fbff20efebfaeafb20c8e3eef0e5e2fb"
        let second = Data(stride(from: 0, to: hex.count, by: 2).map { offset in UInt8(String(Array(hex)[offset..<offset+2]), radix: 16)! })
        // RFC vectors are printed most significant byte first; file digest convention reverses that representation.
        XCTAssertEqual(try MaterialHash.digest(first), "1b54d01a4af5b9d5cc3d86d68d285462b19abc2475222f35c085122be4ba1ffa00ad30f8767b3a82384c6574f024c311e2a481332b08ef7f41797891c1646f48")
        XCTAssertEqual(try MaterialHash.digest(second), "1e88e62226bfca6f9994f1f2d51569e0daf8475a3b0fe61a5300eee46d961376035fe83549ada2b8620fcd7c496ce5b33f0cb9dddc2b6460143b03dabac9fb28")
        XCTAssertEqual(try MaterialHash.digest(Data("abc".utf8), algorithm: "SHA-256"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertThrowsError(try MaterialHash.digest(first, algorithm: "unknown"))
    }
    func testOldEvidenceRemainsAfterNewCapture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PDFSourceEvidence(root: root)
        let url = URL(string: "https://api.hh.ru/vacancies/42")!
        let bytes = Data(#"{"id":"42"}"#.utf8)
        let old = try XCTUnwrap(store.capture(data: bytes, url: url, status: 200, sent: Date(), received: Date()))
        let folder = root.appendingPathComponent("observations/" + old.id)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: folder.path)
        _ = try store.capture(data: bytes, url: url, status: 200, sent: Date(), received: Date())
        XCTAssertEqual(try store.observation(old.id).id, old.id)
    }
    func testSourceReceiptAppendOnlyAndOriginalBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PDFSourceEvidence(root: root)
        let bytes = Data(#"{ "id":"42", "name":"Экономист", "archived":false, "published_at":"2026-10-17T10:15:16+0300" }"#.utf8)
        let url = URL(string: "https://api.hh.ru/vacancies/42?access_token=SECRET&area=1")!
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try XCTUnwrap(store.capture(data: bytes, url: url, status: 200, sent: t, received: t.addingTimeInterval(1)))
        let second = try XCTUnwrap(store.capture(data: bytes, url: url, status: 200, sent: t.addingTimeInterval(9), received: t.addingTimeInterval(10)))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("observations/\(first.id)/response.json")), bytes)
        XCTAssertFalse(String(data: try PDFSourceJSON.encode(first), encoding: .utf8)!.contains("SECRET"))
        XCTAssertEqual(first.parameters, ["area": "1"])
        let materials = try store.materials(for: DocumentContext(kind: "Сведения о вакансии",
                                                                  vacancyIDs: ["42"], observationIDs: [first.id]))
        XCTAssertEqual(materials.map(\.path), ["sources/response-001.json"])
        XCTAssertEqual(materials.first?.data, bytes)
        XCTAssertNil(try store.capture(data: bytes, url: url, status: 404, sent: t, received: t))
        XCTAssertThrowsError(try store.capture(data: Data(#"{"id":"42","access_token":"SECRET"}"#.utf8), url: url, status: 200, sent: t, received: t))
    }

}

extension PDFSourceEvidenceTests {
    func testPDFContainsExactOriginalBinaryAttachmentsAndReadablePages() throws {
        let bytes = Data([0, 10, 13, 127, 128, 255]) + Data("endstream\nendobj\n(•) Кириллица".utf8)
        let page = NSAttributedString(string: "Проверка вложений PDF", attributes: [.font: VacancyPDFStyle.bodyFont])
        let original = try VacanciesPDFExporter.pdfData(for: VacanciesPDFExporter.pages(for: page))
        let embedded = try PDFOriginalMaterials.embed([.init(path: "original.bin", data: bytes, type: "fixture", observationIDs: [])], in: original)
        let provider = try XCTUnwrap(CGDataProvider(data: embedded as CFData))
        let pdf = try XCTUnwrap(CGPDFDocument(provider))
        let catalog = try XCTUnwrap(pdf.catalog)
        var names: CGPDFDictionaryRef?, files: CGPDFDictionaryRef?, array: CGPDFArrayRef?
        XCTAssertTrue(CGPDFDictionaryGetDictionary(catalog, "Names", &names))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(names), "EmbeddedFiles", &files))
        XCTAssertTrue(CGPDFDictionaryGetArray(try XCTUnwrap(files), "Names", &array))
        var spec: CGPDFDictionaryRef?, ef: CGPDFDictionaryRef?, stream: CGPDFStreamRef?
        XCTAssertTrue(CGPDFArrayGetDictionary(try XCTUnwrap(array), 1, &spec))
        XCTAssertTrue(CGPDFDictionaryGetDictionary(try XCTUnwrap(spec), "EF", &ef))
        XCTAssertTrue(CGPDFDictionaryGetStream(try XCTUnwrap(ef), "F", &stream))
        var format = CGPDFDataFormat.raw
        let extracted = try XCTUnwrap(CGPDFStreamCopyData(try XCTUnwrap(stream), &format)) as Data
        XCTAssertEqual(extracted, bytes)
        XCTAssertEqual(pdf.numberOfPages, 1)
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data: embedded)?.string).contains("Проверка вложений PDF"))
        XCTAssertThrowsError(try PDFOriginalMaterials.embed([], in: Data("invalid".utf8)))
    }
}
