import AppKit
import Foundation
import PDFKit
import XCTest
import SwiftUI
@testable import HHVacancyCBR

extension HHVacancyCBRTests {

    func testPDFPaginationPreservesOversizedUnicodeContentAndRendersEveryPage() throws {
        let paragraph = "ОченьДлиннаяНепрерывнаяСтрокаБезПробелов0123456789🙂"
        let source = (0..<1_000).map { "\($0): \(paragraph)\n" }.joined()
        let attributed = NSAttributedString(
            string: source,
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]
        )

        let pages = VacanciesPDFExporter.pages(for: attributed)

        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.map(\.content.string).joined(), source)
        let data = try VacanciesPDFExporter.pdfData(for: pages)
        try VacanciesPDFExporter.validatePDF(data: data, expectedPages: pages.count)
    }

    func testPDFPaginationKeepsParagraphsTogetherAndEveryPageFitsWhenDrawnAlone() throws {
        let words = (0..<60).map { "слово\($0)" }.joined(separator: " ")
        let source = (0..<120).map { "Абзац \($0). \(words)\n" }.joined()
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 6
        let attributed = NSAttributedString(string: source, attributes: [
            .font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.black, .paragraphStyle: style
        ])

        let pages = VacanciesPDFExporter.pages(for: attributed)

        XCTAssertGreaterThan(pages.count, 3)
        XCTAssertEqual(pages.map(\.content.string).joined(), source)
        let text = source as NSString
        var offset = 0
        var previousStart = 0
        let drawableHeight = VacancyPDFDefaults.paperSize.height - VacancyPDFDefaults.verticalMargin * 2
        let width = VacancyPDFDefaults.paperSize.width - VacancyPDFDefaults.horizontalMargin * 2
        for (index, page) in pages.enumerated() {
            if index > 0 {
                let paragraph = text.paragraphRange(for: NSRange(location: offset, length: 0))
                // A page starts a paragraph unless that paragraph is longer than a page.
                XCTAssertTrue(paragraph.location == offset || paragraph.location <= previousStart,
                              "Page \(index + 1) splits a paragraph that fits on one page")
            }
            let height = page.content.boundingRect(
                with: NSSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height
            XCTAssertLessThanOrEqual(height, drawableHeight, "Page \(index + 1) would be clipped")
            previousStart = offset
            offset += page.content.length
        }
        let data = try VacanciesPDFExporter.pdfData(for: pages)
        try VacanciesPDFExporter.validatePDF(data: data, expectedPages: pages.count)
    }

    @MainActor
    func testPDFHTMLListAndLongBreakParagraphUseRemainingSpace() throws {
        let prefix = String(repeating: "Вступление<br>", count: 20)
        let long = (0..<35).map { "СтрокаHTML\($0)" }.joined(separator: "<br>")
        let html = "<p>\(prefix)</p><ul><li>\(long)</li></ul>"
        let text = VacancyHTMLAttributedText.convert(html)
        let pages = VacanciesPDFExporter.pages(for: text)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertTrue(pages[0].content.string.contains("СтрокаHTML0"))
        XCTAssertTrue(pages[1].content.string.contains("СтрокаHTML"))
        XCTAssertEqual(pages.map(\.content.string).joined(), text.string)
        let data = try VacanciesPDFExporter.pdfData(for: pages)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(pdf.pageCount, pages.count)
        XCTAssertTrue(try XCTUnwrap(pdf.string).contains("СтрокаHTML0"))
        XCTAssertTrue(try XCTUnwrap(pdf.string).contains("СтрокаHTML34"))
    }

    func testPDFPaginationDoesNotEmitBlankPagesForWhitespaceTail() throws {
        let source = "Текст вакансии\n" + String(repeating: "\n", count: 400)
        let attributed = NSAttributedString(
            string: source,
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]
        )

        let pages = VacanciesPDFExporter.pages(for: attributed)

        XCTAssertEqual(pages.map(\.content.string).joined(), source)
        XCTAssertTrue(pages.allSatisfy { !$0.content.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        let data = try VacanciesPDFExporter.pdfData(for: pages)
        try VacanciesPDFExporter.validatePDF(data: data, expectedPages: pages.count)
    }

    @MainActor
    func testPDFSnapshotImportsHTMLOnMainActorForBackgroundRendering() async throws {
        let snapshot = PDFVacancySnapshot(value: makePDFVacancy(id: "main-import"))
        let imported = snapshot.attributedDocument
        XCTAssertTrue(imported.string.contains("Кириллица, Unicode"))

        // Rendering happens off the main actor from the imported text only.
        let rendered = await Task.detached { snapshot.attributedDocument.string }.value
        XCTAssertTrue(rendered.contains("Кириллица, Unicode"))
        XCTAssertFalse(rendered.contains("<p>"))

        let batch = try await PDFVacanciesSnapshot.make(values: [makePDFVacancy(id: "a"), makePDFVacancy(id: "b")])
        XCTAssertEqual(batch.values.flatMap { $0.context.vacancyIDs }, ["a", "b"])
        XCTAssertTrue(batch.values.allSatisfy { $0.attributedDocument.length > 0 })
    }

    func testPDFDocumentWithoutImportedDescriptionFallsBackToPlainText() {
        let document = VacancyPDFFormatter.attributedDocument(
            for: makePDFVacancy(id: "plain"),
            importedDescription: nil
        ).string
        XCTAssertTrue(document.contains("Кириллица, Unicode"))
        XCTAssertFalse(document.contains("<p>"))
    }

    @MainActor
    func testPDFHeadingAndBodyTypographyUsesSharedMinimalistStyle() throws {
        let document = VacancyPDFFormatter.attributedDocument(for: makePDFVacancy(id: "typography"))
        let text = document.string as NSString

        func fontSize(at substring: String, offset: Int = 0) throws -> CGFloat {
            let range = text.range(of: substring)
            guard range.location != NSNotFound else {
                XCTFail("Missing PDF text: \(substring)")
                return 0
            }
            let location = range.location + offset
            return try XCTUnwrap(
                document.attribute(.font, at: location, effectiveRange: nil) as? NSFont
            ).pointSize
        }

        XCTAssertEqual(try fontSize(at: "Сведения о вакансии"), 17, accuracy: 0.01)
        XCTAssertEqual(try fontSize(at: "Инженер надёжности typography"), 11.5, accuracy: 0.01)
        XCTAssertEqual(try fontSize(at: "Работодатель: Банк России"), 9.5, accuracy: 0.01)
        XCTAssertEqual(
            try fontSize(at: "Работодатель: Банк России", offset: ("Работодатель: " as NSString).length),
            9.5,
            accuracy: 0.01
        )
    }

    @MainActor
    func testPDFFallbackPreservesSummaryFieldsInPersonalAndFavoriteDocuments() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let summary = documentedTestSummary(HHVacancySummary(id: "fallback-fields", name: "UniqueTitleAlpha",
            employer: .init(name: "Банк России", id: "47858"),
            salary: .init(from: 123_456, to: nil, currency: "RUR", gross: false),
            area: .init(id: "1", name: "Москва"), alternateURL: "https://example.invalid/fallback-fields",
            url: nil, snippet: .init(requirement: "UniqueSnippetBeta", responsibility: nil),
            department: .init(name: "DepartmentFallback"), publishedAt: "2026-09-02T12:34:56+0300"))
        let value = VacancySearchResult(id: summary.id, summary: summary,
            details: .init(id: summary.id, name: summary.name, employer: nil, area: nil,
                salary: nil, alternateURL: nil, description: nil),
            location: .subject(id: "1", name: "Москва", cityID: "1", cityName: "Москва"))
        let worker = PDFExportWorker()
        let personal = directory.appendingPathComponent("personal.pdf")
        try await worker.exportPersonal(vacancy: .init(value: value), destination: personal)
        let exporter = VacanciesPDFExporter(chooseDirectory: { directory },
            now: { Date(timeIntervalSince1970: 1_788_400_000) })
        _ = try await exporter.export(vacancies: [value]) { _ in }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pdf" }
        XCTAssertEqual(files.count, 2)
        for file in files {
            let pdf = try XCTUnwrap(PDFDocument(url: file))
            XCTAssertGreaterThan(pdf.pageCount, 0)
            XCTAssertLessThanOrEqual(pdf.pageCount, 100)
            let text = try extractedStatisticsText(pdf)
            // Use word markers: PDFKit versions can reorder punctuation during
            // extraction. Check exact source content and one complete occurrence
            // in the PDF, independent of extracted whitespace.
            let sourceText = VacancyPDFFormatter.attributedDocument(for: value).string
            let markerText = text.components(separatedBy: .whitespacesAndNewlines).joined()
            for marker in ["UniqueTitleAlpha", "UniqueSnippetBeta"] {
                XCTAssertEqual(sourceText.components(separatedBy: marker).count - 1, 1)
                XCTAssertEqual(markerText.components(separatedBy: marker).count - 1, 1,
                               "Extracted synthetic PDF text: \(text)")
            }
            XCTAssertTrue(text.contains("DepartmentFallback"), "Lost summary department")
            let expectedDate = String(VacancyPDFStyle.publicationDate(summary.publishedAt).prefix(19))
            XCTAssertTrue(text.contains(expectedDate), "Lost summary publication date: expected \(expectedDate), got \(text)")
            XCTAssertTrue(text.contains("123 456"), "Lost summary salary")
            XCTAssertTrue(text.contains("https://hh.ru/vacancy/fallback-fields"))
            XCTAssertFalse(text.contains("Полное описание из detail endpoint HH недоступно."))
            let attachment = XCTAttachment(data: try Data(contentsOf: file), uniformTypeIdentifier: "com.adobe.pdf")
            attachment.name = file.lastPathComponent == "personal.pdf" ? "Fallback personal PDF" : "Fallback favorites PDF"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor
    func testPDFFallbackDoesNotOverrideAvailableDetailFields() throws {
        let summary = HHVacancySummary(id: "priority", name: "Priority title", employer: nil,
            salary: .init(from: 123_456, to: nil, currency: "RUR", gross: nil), area: nil,
            alternateURL: nil, url: nil, snippet: nil, department: .init(name: "SummaryDepartment"),
            publishedAt: "2026-09-01T10:00:00Z")
        let value = VacancySearchResult(id: summary.id, summary: summary,
            details: .init(id: summary.id, name: summary.name, employer: nil, area: nil,
                salary: .init(from: 987_654, to: nil, currency: "RUR", gross: nil), alternateURL: nil,
                description: nil, publishedAt: "2026-09-02T10:00:00Z", department: .init(name: "DetailDepartment")),
            isDetailLoaded: true)
        let pages = VacanciesPDFExporter.pages(for: VacancyPDFFormatter.attributedDocument(for: value))
        let pdf = try XCTUnwrap(PDFDocument(data: VacanciesPDFExporter.pdfData(for: pages)))
        let text = try extractedStatisticsText(pdf)
        for expected in ["DetailDepartment", VacancyPDFStyle.publicationDate("2026-09-02T10:00:00Z"), "987 654"] {
            XCTAssertTrue(text.contains(expected))
        }
        for absent in ["SummaryDepartment", VacancyPDFStyle.publicationDate("2026-09-01T10:00:00Z"), "123 456"] {
            XCTAssertFalse(text.contains(absent))
        }
    }

    func testReadableHTMLTextSurvivesPoolDrainAndConcurrentConversion() async {
        let cases = [
            ("", ""),
            ("<p>ёж &amp; Ω 🙂</p>", "ёж & Ω 🙂"),
            ("<script>hidden()</script><style>body{}</style><p>Visible</p>", "Visible"),
            ("<div>First<br>Second</div>", "First\nSecond"),
            ("<ul><li>One</li><li>Two</li></ul>", "– One\n\n– Two"),
            ("&lt;x&gt; &quot;quoted&quot; &#39;text&#39;", "<x> \"quoted\" 'text'")
        ]
        let results = await withTaskGroup(of: [String].self, returning: [[String]].self) { group in
            for _ in 0..<100 {
                group.addTask { cases.map { $0.0.readableHTMLText } }
            }
            var values: [[String]] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.count, 100)
        // Compare after every conversion pool has drained and all tasks have finished.
        for result in results { XCTAssertEqual(result, cases.map { $0.1 }) }
    }

    func testHTMLSanitizerIsSafeAndDeterministicUnderConcurrentUse() async {
        let source = """
        <!-- secret --><div class="layout"><h2>Кириллица</h2><script>alert(1)</script>
        <a href="https://hh.ru/vacancy/42" onclick="alert(2)">HH</a>
        <a href="javascript:alert(3)">bad</a><img src="https://example.invalid/tracker.png"></div>
        """
        let expected = VacancyHTMLAttributedText.sanitize(source)

        XCTAssertFalse(expected.contains("secret"))
        XCTAssertFalse(expected.contains("script"))
        XCTAssertFalse(expected.contains("onclick"))
        XCTAssertFalse(expected.contains("javascript"))
        XCTAssertFalse(expected.contains("img"))
        XCTAssertTrue(expected.contains("<a href=\"https://hh.ru/vacancy/42\">"))
        XCTAssertTrue(expected.contains("Кириллица"))

        let values = await withTaskGroup(of: String.self, returning: [String].self) { group in
            for _ in 0..<100 {
                group.addTask { VacancyHTMLAttributedText.sanitize(source) }
            }
            var values: [String] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(Set(values), [expected])
    }

    func testOptInPDFRenderingMetrics() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HH_RUN_PERFORMANCE_TESTS"] == "1",
            "Set HH_RUN_PERFORMANCE_TESTS=1 for the five-iteration SDK metrics run."
        )
        let paragraph = "Надёжность, производительность и Unicode: ёж, Ω.\n"
        let document = NSAttributedString(
            string: String(repeating: paragraph, count: 8_000),
            attributes: [.font: NSFont.systemFont(ofSize: 9.5)]
        )
        let pages = VacanciesPDFExporter.pages(for: document)
        XCTAssertGreaterThan(pages.count, 10)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        var renderedByteCount = 0
        var renderingError: Error?
        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()],
            options: options
        ) {
            autoreleasepool {
                do {
                    renderedByteCount = try VacanciesPDFExporter.pdfData(for: pages).count
                } catch {
                    renderingError = error
                }
            }
        }
        if let renderingError { throw renderingError }
        XCTAssertGreaterThan(renderedByteCount, 0)
    }
    @MainActor
    func testHHBulkPDFHasOneEvidenceSectionAfterVacancy() async throws {
        let value = statisticsVacancy(id: "hh-footer", date: "2026-09-01T10:00:00Z")
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let worker = PDFExportWorker()
        let snapshots = PDFVacanciesSnapshot(values: [value])
        let prepared = try await worker.prepare(vacancies: snapshots) { _ in }
        let files = try await worker.writePrepared(names: (0..<prepared.partCount).map { "hh\($0).pdf" }, directory: directory)
        for file in files {
            let text = try XCTUnwrap(PDFDocument(url: file)?.string)
            XCTAssertEqual(text.components(separatedBy: "Данные для проверки").count - 1, 1)
            XCTAssertFalse(text.contains("Арбитражного процессуального кодекса"))
            XCTAssertFalse(text.contains("нотариус"))
            XCTAssertFalse(text.contains("Совпадение контрольной суммы подтверждает согласованность"))
            XCTAssertFalse(text.contains("Сведения о вакансии"))
            XCTAssertEqual(text.components(separatedBy: "Все вакансии").count - 1, 1)
            XCTAssertGreaterThan(try XCTUnwrap(text.range(of: "Данные для проверки")?.lowerBound),
                                 try XCTUnwrap(text.range(of: value.name)?.lowerBound))
            let raw = try Data(contentsOf: file)
            for material in try PDFSourceEvidence.shared.materials(for: DocumentContext.vacancy(value)) { XCTAssertNotNil(raw.range(of: material.data)) }
        }
    }

    @MainActor
    func testTrudPDFUsesReadableSectionsAndEvidenceAtEnd() async throws {
        var row = TrudFixture.row("readable")
        var raw = try XCTUnwrap(row["vacancy"] as? [String: Any])
        raw["requirement"] = ["education": "Высшее образование", "experience": 1]
        raw["contact_list"] = [["contact_type": "Телефон", "contact_value": "+7 123"]]
        raw["medicalDocuments"] = "Медицинская книжка"
        raw["companycode"] = "secret-code"
        row["vacancy"] = raw
        let data = try TrudFixture.data([row])
        let url = try TrudvsemAPIClient.url(inn: TrudFixture.bank.inn, page: 0, limit: 100)
        let obs = try XCTUnwrap(PDFSourceEvidence.shared.capture(data: data, url: url, status: 200, sent: Date(), received: Date()))
        let dto = try XCTUnwrap(TrudvsemPage(data: data).vacancies.first)
        let value = TrudvsemVacancy(dto: dto, organization: TrudFixture.bank, observationIDs: [obs.id])
        let card = TrudvsemPDFFormatter.personal(value).attributedDocument.string
        XCTAssertTrue(card.contains("статья 71 Гражданского процессуального кодекса Российской Федерации"))
        let evidence = String(card[try XCTUnwrap(card.range(of: "Данные для проверки")).lowerBound...])
        XCTAssertFalse(evidence.contains("Арбитражного процессуального кодекса"))
        XCTAssertFalse(evidence.contains("нотариус"))
        XCTAssertFalse(evidence.contains("Совпадение контрольной суммы подтверждает согласованность"))
        XCTAssertTrue(card.contains("Дата создания: 21.10.2026"))
        XCTAssertTrue(card.contains("Медицинские документы"))
        XCTAssertTrue(card.contains("Контакт: +7 123"))
        for key in ["companycode", "contact_type", "contact_value", "medicalDocuments", "Код региона"] { XCTAssertFalse(card.contains(key), key) }
        XCTAssertGreaterThan(try XCTUnwrap(card.range(of: "Данные для проверки")?.lowerBound), try XCTUnwrap(card.range(of: "Описание вакансии")?.lowerBound))
        let stats = TrudvsemPDFFormatter.statistics([value], filters: ["Сортировка": "Сначала новые"]).attributedDocument.string
        XCTAssertTrue(stats.contains("Период дат создания: 21.10.2026 — 21.10.2026"))
        XCTAssertFalse(stats.contains("Сортировка:"))
        XCTAssertFalse(stats.contains("Зарплата по валюте и периодичности"))
        XCTAssertTrue(stats.contains("Требования к опыту работы"))
        XCTAssertTrue(stats.contains("От 1 года: 1"))
        XCTAssertFalse(stats.contains("companycode"))
        let statsEvidence = String(stats[try XCTUnwrap(stats.range(of: "Данные для проверки")).lowerBound...])
        XCTAssertFalse(statsEvidence.contains("Арбитражного процессуального кодекса"))
        XCTAssertFalse(statsEvidence.contains("нотариус"))
        XCTAssertFalse(statsEvidence.contains("Совпадение контрольной суммы подтверждает согласованность"))
        let attributed = TrudvsemPDFFormatter.statistics([value], filters: [:]).attributedDocument
        let nsText = attributed.string as NSString
        for paragraph in ["Документы, полученные через интернет", "Материалы могут быть исследованы", "Ответ API №1"] {
            let range = nsText.range(of: paragraph)
            XCTAssertNotEqual(range.location, NSNotFound)
            if range.location != NSNotFound {
                XCTAssertNil(attributed.attribute(VacancyPDFStyle.keepWithNext, at: range.location, effectiveRange: nil), paragraph)
            }
        }
        let worker = PDFExportWorker(), directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let personalURL = directory.appendingPathComponent("personal.pdf")
        let statisticsURL = directory.appendingPathComponent("statistics.pdf")
        try await worker.exportTrudvsemPersonal(vacancy: value, destination: personalURL)
        try await worker.exportTrudvsemStatistics(vacancies: [value], filters: ["Сортировка": "Сначала новые"], destination: statisticsURL)
        for (name, url) in [("personal", personalURL), ("statistics", statisticsURL)] {
            let attachment = XCTAttachment(data: try Data(contentsOf: url), uniformTypeIdentifier: "com.adobe.pdf")
            attachment.name = "review-" + name; attachment.lifetime = .keepAlways; add(attachment)
        }
        let prepared = try await worker.prepareTrudvsem(vacancies: [value]) { _ in }
        let files = try await worker.writePrepared(names: (0..<prepared.partCount).map { "part\($0).pdf" }, directory: directory)
        for file in files {
            let pdf = try XCTUnwrap(PDFDocument(url: file))
            let attachment = XCTAttachment(data: try Data(contentsOf: file), uniformTypeIdentifier: "com.adobe.pdf")
            attachment.name = "review-bulk"; attachment.lifetime = .keepAlways; add(attachment)
            let text = try XCTUnwrap(pdf.string)
            XCTAssertEqual(text.components(separatedBy: "Данные для проверки").count - 1, 1)
            XCTAssertGreaterThan(try XCTUnwrap(text.range(of: "Данные для проверки")?.lowerBound), try XCTUnwrap(text.range(of: value.title)?.lowerBound))
            XCTAssertNotNil(try Data(contentsOf: file).range(of: data))
        }
    }

    func testPDFRenderingPreservesLinksAndLinklessPages() throws {
        let url = URL(string: "https://example.com/vacancy/1")!
        let first = NSAttributedString(string: "Clickable vacancy", attributes: [.font: VacancyPDFStyle.bodyFont, .link: url])
        let second = NSAttributedString(string: "Plain description", attributes: [.font: VacancyPDFStyle.bodyFont])
        let data = try VacanciesPDFExporter.pdfData(for: [.init(content: first), .init(content: second)])
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(pdf.pageCount, 2)
        XCTAssertTrue(try XCTUnwrap(pdf.page(at: 0)).annotations.contains { $0.url == url })
        XCTAssertTrue(try XCTUnwrap(pdf.page(at: 1)).annotations.isEmpty)
        XCTAssertTrue(try XCTUnwrap(pdf.string).contains("Plain description"))
    }
}
