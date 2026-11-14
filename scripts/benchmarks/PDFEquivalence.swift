import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import PDFKit

/// Offline before/after characterization. Fixed receipts are written only to this process's
/// test archive; the fixture clock must already be loaded by DYLD_INSERT_LIBRARIES.
@main
struct PDFEquivalence {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count >= 2 else { throw Failure.invalid("Expected a new artifact directory") }
        guard Date().timeIntervalSinceReferenceDate == 790000000 else { throw Failure.invalid("Fixture clock is not loaded") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure.invalid("Artifact directory already exists") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        setenv("XCTestConfigurationFilePath", "pdf-equivalence", 1)
        let archive = try PDFSourceEvidence.shared.root
        guard !FileManager.default.fileExists(atPath: archive.path) else { throw Failure.invalid("Test archive already exists") }
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: archive) }
        let fixedDate = Date()
        let shortHTML = """
        <h2>Обязанности</h2><p>Unicode: ёж, Ω, —. Первая строка<br>Вторая строка.</p>
        <ul><li>Анализ данных</li><li><b>Проверка</b> <a href="https://example.invalid/reference">ссылки</a></li></ul>
        <p>Конец описания.</p><script>never render this</script>
        """
        let first = try hh(id: "fixture-1", name: "Экономист Ω", html: shortHTML, number: 1)
        let second = try hh(id: "fixture-2", name: "Аналитик", html: "<p>Короткая карточка.</p>", number: 2)
        let values = [first, second]
        let tv = try trud()
        let worker = PDFExportWorker()
        try await worker.exportPersonal(vacancy: PDFVacancySnapshot(value: first), destination: output.appendingPathComponent("hh-personal.pdf"))
        let report = statistics(values, at: fixedDate)
        try await worker.exportStatistics(report: report, destination: output.appendingPathComponent("hh-statistics.pdf"))
        let bulk = try await worker.prepare(vacancies: .init(values: values), filters: ["Регион": "Москва"]) { _ in }
        _ = try await worker.writePrepared(names: (0..<bulk.partCount).map { "hh-bulk-\($0 + 1).pdf" }, directory: output)
        try await worker.exportTrudvsemPersonal(vacancy: tv, destination: output.appendingPathComponent("trud-personal.pdf"))
        try await worker.exportTrudvsemStatistics(vacancies: [tv], filters: ["Регион": "Москва"], destination: output.appendingPathComponent("trud-statistics.pdf"))
        let tvBulk = try await worker.prepareTrudvsem(vacancies: [tv]) { _ in }
        _ = try await worker.writePrepared(names: (0..<tvBulk.partCount).map { "trud-bulk-\($0 + 1).pdf" }, directory: output)
        try await worker.exportStatistics(report: statistics([], at: fixedDate), destination: output.appendingPathComponent("hh-empty-statistics.pdf"))
        try await worker.exportTrudvsemStatistics(vacancies: [], filters: [:], destination: output.appendingPathComponent("trud-empty-statistics.pdf"))

        // One complete card crossing the 100-page boundary; every marker must survive.
        let longHTML = (0..<6500).map { "<p>MARKER_\($0)_END Разработка и проверка многостраничной карточки.</p>" }.joined()
        let long = try hh(id: "fixture-long", name: "Длинная карточка", html: longHTML, number: 3)
        let longBulk = try await worker.prepare(vacancies: .init(values: [long])) { _ in }
        guard longBulk.partCount > 1 else { throw Failure.invalid("Long fixture did not cross the 100-page boundary") }
        let longFiles = try await worker.writePrepared(names: (0..<longBulk.partCount).map { "long-bulk-\($0 + 1).pdf" }, directory: output)
        let longText = longFiles.compactMap { PDFDocument(url: $0)?.string }.joined(separator: "\n")
        let markers = try NSRegularExpression(pattern: #"MARKER_(\d+)_END"#)
        let markerMatches = markers.matches(in: longText, range: NSRange(longText.startIndex..., in: longText))
        let markerIDs = markerMatches.map { (longText as NSString).substring(with: $0.range(at: 1)) }
        guard markerIDs.count == 6500, Set(markerIDs) == Set((0..<6500).map(String.init)) else {
            throw Failure.invalid("Long-card text loss or duplication")
        }
        var documents: [[String: Any]] = []
        for file in try FileManager.default.contentsOfDirectory(at: output, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "pdf" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            documents.append(try inspect(file, output: output))
        }
        let names = [
            PDFFileNameBuilder.personal(vacancyID: first.id, title: first.name, exportStartedAt: fixedDate),
            PDFFileNameBuilder.statisticsReport(report),
            PDFFileNameBuilder.bulk(part: 1, totalParts: 2, exportStartedAt: fixedDate),
            PDFFileNameBuilder.bulk(part: 2, totalParts: 2, exportStartedAt: fixedDate, source: .trudvsem)
        ]
        let manifest: [String: Any] = ["fixtureVersion": 1, "clock": fixedDate.timeIntervalSinceReferenceDate,
            "timeZone": TimeZone.current.identifier, "locale": Locale.current.identifier,
            "fileNames": names, "longPartCount": longBulk.partCount, "documents": documents]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        print("PDF equivalence artifacts: \(documents.count) PDFs; long card: \(longBulk.partCount) parts / \(longBulk.pageCount) pages; fixed dates and exact source bytes")
    }

    enum Failure: Error { case invalid(String) }

    static func receipt(data: Data, number: Int, source: VacancySource, endpoint: String, ids: [String]) throws -> String {
        let id = String(format: "00000000-0000-4000-8000-%012d", number)
        let folder = try PDFSourceEvidence.shared.root.appendingPathComponent("observations/" + id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let record = APIObservation(source: source, version: 1, id: id, endpoint: endpoint, parameters: [:],
            sentAt: "2026-01-02T03:04:05.000Z", receivedAt: "2026-01-02T03:04:06.000Z", httpStatus: 200,
            vacancyIDs: ids, algorithm: MaterialHash.algorithm, hash: try MaterialHash.digest(data), byteCount: data.count, method: "GET")
        try data.write(to: folder.appendingPathComponent("response.json"), options: .withoutOverwriting)
        try PDFSourceJSON.encode(record).write(to: folder.appendingPathComponent("observation.json"), options: .withoutOverwriting)
        return id
    }

    static func hh(id: String, name: String, html: String, number: Int) throws -> VacancySearchResult {
        let object: [String: Any] = ["id": id, "name": name, "employer": ["id": "47858", "name": "Банк России"],
            "area": ["id": "1", "name": "Москва"], "salary": ["from": 100000, "to": 180000, "currency": "RUR", "gross": false],
            "description": html, "published_at": "2026-01-02T03:04:05+0300", "archived": false,
            "experience": ["id": "between1And3", "name": "От 1 года до 3 лет"], "key_skills": [["name": "Swift"], ["name": "SQL"]],
            "address": ["city": "Москва", "street": "Тестовая", "building": "1"],
            "alternate_url": "https://hh.ru/vacancy/" + id]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        let observation = try receipt(data: data, number: number, source: .hh, endpoint: "https://api.hh.ru/vacancies/" + id, ids: [id])
        var summary = try JSONDecoder().decode(HHVacancySummary.self, from: data)
        var details = try JSONDecoder().decode(HHVacancyDetails.self, from: data)
        summary.observationID = observation; details.observationID = observation
        return VacancySearchResult(id: id, summary: summary, details: details,
            location: .subject(id: "1", name: "Москва", cityID: "1", cityName: "Москва"))
    }

    static func trud() throws -> TrudvsemVacancy {
        let data = Data(#"{"status":"200","meta":{"total":1},"results":{"vacancies":[{"vacancy":{"id":"fixture-tv","job-name":"Экономист Ω","company":{"companycode":"fixture-company","inn":"7702235133","ogrn":"1037700013020","name":"Банк России"},"region":{"region_code":"77","name":"Москва"},"creation-date":"2026-01-02","salary_min":40000,"salary_max":70000,"salary":"40000-70000","duty":"<p>Анализ данных.</p><p>Unicode ёж Ω.</p>","requirement":{"education":"Высшее","experience":3},"employment":"Полная занятость","schedule":"Полный рабочий день","work-places":2,"medicalCertificate":"Не требуется"}}]}}"#.utf8)
        let dto = try TrudvsemPage(data: data).vacancies[0]
        let observation = try receipt(data: data, number: 4, source: .trudvsem,
            endpoint: "https://opendata.trudvsem.ru/api/v1/vacancies/company/inn/7702235133", ids: ["trudvsem.ru:fixture-company:fixture-tv"])
        return TrudvsemVacancy(dto: dto, organization: OrganizationRegistry.all[0], observationIDs: [observation])
    }

    static func statistics(_ values: [VacancySearchResult], at date: Date) -> VacancyStatisticsReport {
        VacancyStatisticsReport(entries: values.map(VacancyStatisticsReport.Entry.init), modeName: "Все вакансии",
            employerID: "all", employerName: "Все работодатели", regionID: "all", regionName: "Все регионы", createdAt: date,
            timeZoneIdentifier: "UTC", sourceNote: "Синтетическая проверка эквивалентности; сетевых запросов нет.")
    }

    static func inspect(_ file: URL, output: URL) throws -> [String: Any] {
        guard let pdf = PDFDocument(url: file), let cg = CGPDFDocument(file as CFURL), let catalog = cg.catalog,
              pdf.pageCount > 0, pdf.pageCount <= 100 else { throw Failure.invalid("Invalid PDF: " + file.lastPathComponent) }
        let stem = file.deletingPathExtension().lastPathComponent
        let text = pdf.string ?? ""
        try Data(text.utf8).write(to: output.appendingPathComponent(stem + ".txt"), options: .withoutOverwriting)
        var images: [String] = []
        for index in 1...cg.numberOfPages {
            guard let page = cg.page(at: index) else { throw Failure.invalid("Missing page") }
            let width = 320, height = 453, rowBytes = width * 4
            var pixels = [UInt8](repeating: 255, count: rowBytes * height)
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB), let context = CGContext(data: &pixels, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: rowBytes, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure.invalid("Raster context") }
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.concatenate(page.getDrawingTransform(.mediaBox, rect: CGRect(x: 0, y: 0, width: width, height: height), rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            images.append(SHA256.hash(data: Data(pixels)).map { String(format: "%02x", $0) }.joined())
            if index == 1 || index == cg.numberOfPages {
                guard let image = context.makeImage(), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw Failure.invalid("PNG") }
                try png.write(to: output.appendingPathComponent("\(stem)-page-\(index).png"), options: .withoutOverwriting)
            }
        }
        var attachments: [[String: Any]] = []
        var names: CGPDFDictionaryRef?, embedded: CGPDFDictionaryRef?, array: CGPDFArrayRef?
        guard CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names,
              CGPDFDictionaryGetDictionary(names, "EmbeddedFiles", &embedded), let embedded,
              CGPDFDictionaryGetArray(embedded, "Names", &array), let array else { throw Failure.invalid("Missing embedded source tree") }
        for index in stride(from: 0, to: CGPDFArrayGetCount(array), by: 2) {
            var name: CGPDFStringRef?, spec: CGPDFDictionaryRef?, ef: CGPDFDictionaryRef?, stream: CGPDFStreamRef?
            guard CGPDFArrayGetString(array, index, &name), let name, let decoded = CGPDFStringCopyTextString(name),
                  CGPDFArrayGetDictionary(array, index + 1, &spec), let spec,
                  CGPDFDictionaryGetDictionary(spec, "EF", &ef), let ef,
                  CGPDFDictionaryGetStream(ef, "F", &stream), let stream else { throw Failure.invalid("Attachment") }
            var format = CGPDFDataFormat.raw
            guard let bytes = CGPDFStreamCopyData(stream, &format) as Data? else { throw Failure.invalid("Attachment bytes") }
            attachments.append(["path": decoded as String, "bytes": bytes.count, "streebog512": try MaterialHash.digest(bytes), "base64": bytes.base64EncodedString()])
        }
        return ["name": file.lastPathComponent, "pages": pdf.pageCount, "text": text, "rasterSHA256": images, "attachments": attachments]
    }
}
