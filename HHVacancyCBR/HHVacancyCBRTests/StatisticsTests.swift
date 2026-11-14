import AppKit
import Foundation
import PDFKit
import XCTest
import SwiftUI
@testable import HHVacancyCBR

extension HHVacancyCBRTests {



    func testStatisticsChronologyCountsMissingDatesAndPDFCompleteness() throws {
        let report = statisticsFixture([
            statisticsVacancy(id: "old", date: "2026-09-01T10:00:00+0300"),
            statisticsVacancy(id: "unknown", date: nil),
            statisticsVacancy(id: "new", date: "2026-09-03T10:00:00+0300", salary: true),
            statisticsVacancy(id: "fractional", date: "2026-09-03T08:00:00.500Z", archived: true),
            statisticsVacancy(id: "bad", date: "invalid")
        ])
        XCTAssertEqual(report.orderedEntries().map(\.entry.id), ["fractional", "new", "old", "bad", "unknown"])
        let document = try report.attributedDocument()
        XCTAssertTrue(document.string.contains("Всего вакансий: 5"))
        XCTAssertTrue(document.string.contains("В архиве: 1"))
        XCTAssertTrue(document.string.contains("С указанной зарплатой: 1"))
        XCTAssertTrue(document.string.contains("Без корректной даты размещения: 2"))
        let vacancyRowStringRange = try XCTUnwrap(
            document.string.range(of: "1. Вакансия fractional")
        )
        let vacancyRowRange = NSRange(vacancyRowStringRange, in: document.string)
        document.enumerateAttribute(.font, in: vacancyRowRange) { value, _, _ in
            guard let font = value as? NSFont else {
                XCTFail("В строке вакансии должен быть задан шрифт")
                return
            }
            XCTAssertEqual(font.pointSize, 10.5)
            XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        }
        let vacancyRowStyle = try XCTUnwrap(
            document.attribute(.paragraphStyle, at: vacancyRowRange.location, effectiveRange: nil) as? NSParagraphStyle
        )
        XCTAssertEqual(vacancyRowStyle.lineSpacing, 2)
        XCTAssertEqual(vacancyRowStyle.paragraphSpacing, 14)
        let pages = VacanciesPDFExporter.pages(for: document)
        XCTAssertEqual(pages.map(\.content.string).joined(), document.string)
        let data = try VacanciesPDFExporter.pdfData(for: pages)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let text = try extractedStatisticsText(pdf)
        XCTAssertTrue(text.contains("Вакансия fractional"))
        XCTAssertTrue(text.contains("Вакансия unknown"))
        XCTAssertTrue(text.contains("03.09.2026 08:00"))
    }

    func testStatisticsFilenameRetainsBothFiltersAndIsSafeForLongLabels() {
        let report = statisticsFixture([])
        XCTAssertTrue(report.fileName.hasPrefix("цбвакансии_"))
        XCTAssertTrue(report.fileName.contains("банк_россии"))
        XCTAssertTrue(report.fileName.contains("москва"))
        let long = VacancyStatisticsReport(
            entries: [], modeName: "Все вакансии", employerID: "47858",
            employerName: String(repeating: "Очень длинное / название ", count: 50),
            regionID: "subject:1", regionName: String(repeating: "Москва ", count: 50),
            createdAt: report.createdAt, timeZoneIdentifier: "UTC", sourceNote: ""
        )
        XCTAssertLessThanOrEqual(long.fileName.utf8.count, PDFFileNameBuilder.maximumUTF8Length)
        XCTAssertFalse(long.fileName.contains("/"))
        XCTAssertTrue(long.fileName.contains("москва"))
        XCTAssertTrue(long.fileName.hasSuffix(".pdf"))
    }

    @MainActor
    func testStatisticsExportUsesFrozenRowsWithoutDetailRequestsAndCanRetry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let client = MockAPIClient(mode: .filters)
        var destination: URL?
        var chosenName = ""
        weak var observedModel: VacancySearchViewModel?
        let model = VacancySearchViewModel(
            apiClient: client,
            employerStore: TestEmployerStore(entries: [.init(id: "47858", name: "Банк России", comment: "test")]),
            areaStore: AreaDirectoryStore(fileURL: directory.appendingPathComponent("areas.json")),
            statisticsPDFDestination: { name in
                chosenName = name
                observedModel?.selectedRegionID = "all"
                return destination
            }
        )
        observedModel = model
        XCTAssertFalse(model.canExportStatisticsPDF)
        await model.search()
        await model.exportStatisticsPDF() // cancelled save panel
        XCTAssertFalse(model.isExportingStatisticsPDF)
        XCTAssertNil(model.statisticsPDFExportMessage)
        destination = directory.appendingPathComponent("missing/report.pdf")
        await model.exportStatisticsPDF()
        XCTAssertTrue(model.statisticsPDFExportMessage?.contains("Не удалось") == true)
        destination = directory.appendingPathComponent("report.pdf")
        model.selectedEmployerID = "bank_of_russia"
        model.selectedRegionID = "subject:1"
        await model.exportStatisticsPDF()
        let pdf = try XCTUnwrap(PDFDocument(url: try XCTUnwrap(destination)))
        let text = try extractedStatisticsText(pdf)
        XCTAssertTrue(text.contains("Вакансия filter-moscow"))
        XCTAssertFalse(text.contains("Вакансия filter-ekb"))
        XCTAssertTrue(chosenName.contains("москва"))
        XCTAssertTrue(model.statisticsPDFExportMessage?.contains("сохранён: 1") == true)
        XCTAssertTrue(model.canExportStatisticsPDF)
        let detailRequests = await client.detailRequestCount
        XCTAssertEqual(detailRequests, 0)
    }

    func testStatisticsEmptyAndMultipageReportsPreserveEveryRow() throws {
        let empty = try statisticsFixture([]).attributedDocument()
        XCTAssertTrue(empty.string.contains("Всего вакансий: 0"))
        XCTAssertTrue(empty.string.contains("Под выбранными фильтрами вакансий нет."))
        let report = statisticsFixture((0..<250).map {
            statisticsVacancy(id: String($0), date: "2026-09-03T10:00:00+0300")
        })
        let document = try report.attributedDocument()
        let pages = VacanciesPDFExporter.pages(for: document)
        XCTAssertGreaterThan(pages.count, 1)
        XCTAssertEqual(pages.map(\.content.string).joined(), document.string)
        let data = try VacanciesPDFExporter.pdfData(for: pages)
        try VacanciesPDFExporter.validatePDF(data: data, expectedPages: pages.count)
        let text = try extractedStatisticsText(XCTUnwrap(PDFDocument(data: data)))
        for entry in report.entries { XCTAssertTrue(text.contains("Идентификатор вакансии: " + entry.id)) }
    }

    @MainActor
    func testStatisticsPDFExportAcrossEveryEmployerAndRegionCombination() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, client, panel) = makeStatisticsExportModel(directory: directory)
        await model.search()
        let rows = statisticsFilterRows
        for employer in ["all", "47858", "1654251", "9999"] {
            for region in ["all", "subject:1", "subject:2", "subject:66", "remote", "unknown"] {
                let expected = rows.filter {
                    (employer == "all" || $0.employer == employer) && (region == "all" || $0.region == region)
                }.map(\.id)
                try await assertStatisticsExport(model, client: client, panel: panel,
                                                 employer: employer, region: region, expected: expected)
            }
        }
        XCTAssertEqual(panel.names.count, 14)
        XCTAssertEqual(Set(panel.names).count, 14)
    }


    @MainActor
    func testRepeatedStatisticsExportsReplacePriorFilterContentsInSameFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, client, panel) = makeStatisticsExportModel(directory: directory)
        await model.search()
        for (employer, region, expected) in [
            ("all", "all", statisticsFilterRows.map(\.id)),
            ("47858", "subject:1", ["filter-moscow"]),
            ("1654251", "remote", ["filter-remote"]),
            ("47858", "remote", []),
            ("all", "unknown", ["filter-unknown"]),
            ("all", "all", statisticsFilterRows.map(\.id))
        ] {
            try await assertStatisticsExport(model, client: client, panel: panel,
                                             employer: employer, region: region, expected: expected)
        }
        XCTAssertEqual(panel.names.first, panel.names.last)
        XCTAssertFalse(model.isExportingStatisticsPDF)
    }



    @MainActor
    func testStatisticsExportUnavailableBeforeSearchOrAfterInitialFailure() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, _, panel) = makeStatisticsExportModel(directory: directory, mode: .failure)
        await model.loadPersistenceIfNeeded()
        await model.exportStatisticsPDF()
        XCTAssertTrue(panel.names.isEmpty)
        await model.search()
        XCTAssertNotNil(model.errorMessage)
        await model.exportStatisticsPDF()
        XCTAssertFalse(model.canExportStatisticsPDF)
        XCTAssertTrue(panel.names.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: panel.destination!.path))
    }


    @MainActor
    func testStatisticsExportBlockedDuringRefreshAndUsesExplicitStaleDataAfterFailure() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, client, panel) = makeStatisticsExportModel(directory: directory, mode: .delayedRefreshFailure)
        await model.search()
        await client.enableDelayedSearchFailure()
        let refresh = Task { await model.refreshVacancies() }
        for _ in 0..<1_000 {
            if model.isLoading { break }
            await Task.yield()
        }
        XCTAssertTrue(model.isLoading)
        await model.exportStatisticsPDF()
        XCTAssertTrue(panel.names.isEmpty)
        await refresh.value
        XCTAssertNotNil(model.errorMessage)
        await model.exportStatisticsPDF()
        let text = try extractedStatisticsText(XCTUnwrap(PDFDocument(url: XCTUnwrap(panel.destination))))
        XCTAssertFalse(text.contains("Последнее обновление не завершено"))
        XCTAssertTrue(model.statisticsReportSnapshot().sourceNote.contains("Последнее обновление не завершено"))
        XCTAssertTrue(text.contains("Всего вакансий: 3"))
        XCTAssertTrue(model.canExportStatisticsPDF)
    }

    func testStatisticsFilenameDisambiguatesSameNamesWithDifferentIDsAndModes() {
        func report(employer: String, region: String, mode: String) -> VacancyStatisticsReport {
            VacancyStatisticsReport(entries: [], modeName: mode, employerID: employer, employerName: "Одинаковое имя",
                                    regionID: region, regionName: "Одинаковый регион", createdAt: .distantPast,
                                    timeZoneIdentifier: "UTC", sourceNote: "")
        }
        let names = [report(employer: "1", region: "subject:1", mode: "Все вакансии"),
                     report(employer: "2", region: "subject:1", mode: "Все вакансии"),
                     report(employer: "1", region: "subject:2", mode: "Все вакансии"),
                     report(employer: "1", region: "subject:1", mode: "Избранное")].map(\.fileName)
        XCTAssertEqual(Set(names).count, 4)
        XCTAssertTrue(names.allSatisfy { $0.utf8.count <= PDFFileNameBuilder.maximumUTF8Length })
    }

    func testStatisticsOrderIsStableForEqualInstantsAcrossTimeZones() {
        let vacancies = [statisticsVacancy(id: "b", date: "2026-09-03T10:00:00+0300"),
                         statisticsVacancy(id: "a", date: "2026-09-03T07:00:00Z"),
                         statisticsVacancy(id: "c", date: "2026-09-03T07:00:00.001Z"),
                         statisticsVacancy(id: "z", date: nil)]
        XCTAssertEqual(statisticsFixture(vacancies).orderedEntries().map(\.entry.id), ["c", "a", "b", "z"])
        XCTAssertEqual(statisticsFixture(Array(vacancies.reversed())).orderedEntries().map(\.entry.id), ["c", "a", "b", "z"])
    }

    func testCancelledStatisticsWorkerPreservesExistingFileAndAllowsRetry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("report.pdf")
        let original = Data("original file must survive cancellation".utf8)
        try original.write(to: url)
        let worker = PDFExportWorker()
        let report = statisticsFixture([statisticsVacancy(id: "retry", date: nil)])
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await worker.exportStatistics(report: report, destination: url)
        }
        do { try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(try Data(contentsOf: url), original)
        try await worker.exportStatistics(report: report, destination: url)
        XCTAssertTrue(try extractedStatisticsText(XCTUnwrap(PDFDocument(url: directory.appendingPathComponent("report_2.pdf")))).contains("Вакансия retry"))
    }

    @MainActor
    func testTrudStatisticsEvidenceFlowsWithoutIsolatedParagraphPage() throws {
        let rows = (0..<35).map { TrudFixture.row("flow-\($0)") }
        let data = try TrudFixture.data(rows)
        let url = try TrudvsemAPIClient.url(inn: TrudFixture.bank.inn, page: 0, limit: 100)
        let observation = try XCTUnwrap(PDFSourceEvidence.shared.capture(data: data, url: url, status: 200, sent: Date(), received: Date()))
        let values = try TrudvsemPage(data: data).vacancies.map {
            TrudvsemVacancy(dto: $0, organization: TrudFixture.bank, observationIDs: [observation.id])
        }
        let document = TrudvsemPDFFormatter.statistics(values, filters: [:])
        let pages = VacanciesPDFExporter.pages(for: document.attributedDocument)
        let legalIndex = try XCTUnwrap(pages.firstIndex { $0.content.string.contains("Документы, полученные через интернет") })
        let pageText = pages[legalIndex].content.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if pageText.hasPrefix("Документы, полученные через интернет") {
            XCTAssertTrue(pageText.contains("Материалы могут быть исследованы"), "На странице не должен оставаться один короткий абзац")
        }
        let rendered = try VacanciesPDFExporter.pdfData(for: pages)
        let attachment = XCTAttachment(data: rendered, uniformTypeIdentifier: "com.adobe.pdf")
        attachment.name = "trud-statistics-evidence-flow"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
