import AppKit
import Foundation
import PDFKit
import XCTest
import SwiftUI
@testable import HHVacancyCBR

// Shared helpers have test-target scope; no production API visibility changes.
extension HHVacancyCBRTests {

    func fieldSummary(_ title: String, id: String = "field", employer: String = "47858", description: String? = nil,
                              area: HHArea = .init(id: "1", name: "Москва")) -> HHVacancySummary {
        .init(id: id, name: title, employer: .init(name: "Банк России", id: employer), salary: nil,
              area: area, alternateURL: nil, url: nil, snippet: .init(requirement: description, responsibility: nil),
              publishedAt: "2026-10-17T10:00:00+0300")
    }

    var statisticsFilterRows: [(id: String, employer: String, region: String)] {
        [("filter-moscow", "47858", "subject:1"), ("filter-ekb", "47858", "subject:66"),
         ("filter-unknown", "47858", "unknown"), ("filter-remote", "1654251", "remote"),
         ("filter-spb", "9999", "subject:2")]
    }

    @MainActor
    final class StatisticsDestinationSpy {
        var destination: URL?
        var names: [String] = []
        var onChoose: (() -> Void)?
        init(destination: URL) { self.destination = destination }
        func choose(_ name: String) -> URL? {
            names.append(name)
            onChoose?()
            return destination
        }
    }

    @MainActor
    func makeStatisticsExportModel(directory: URL, mode: MockAPIClient.Mode = .filters)
        -> (VacancySearchViewModel, MockAPIClient, StatisticsDestinationSpy) {
        let client = MockAPIClient(mode: mode)
        let panel = StatisticsDestinationSpy(destination: directory.appendingPathComponent("report.pdf"))
        let model = VacancySearchViewModel(
            apiClient: client,
            employerStore: TestEmployerStore(entries: [
                .init(id: "47858", name: "Банк России", comment: "test"),
                .init(id: "1654251", name: "НСПК", comment: "test"),
                .init(id: "9999", name: "Альфа Банк", comment: "test")
            ]),
            areaStore: AreaDirectoryStore(fileURL: directory.appendingPathComponent("areas.json")),
            statisticsPDFDestination: panel.choose,
            currentDate: { Date(timeIntervalSince1970: 1_788_400_000) }
        )
        return (model, client, panel)
    }


    func extractedStatisticsText(_ pdf: PDFDocument) throws -> String {
        // macOS 13 Quartz/PDFKit can expose the shared SF glyph for Cyrillic к as kra.
        // Exact original Unicode is checked separately on the attributed page sequence.
        try XCTUnwrap(pdf.string).replacingOccurrences(of: "\u{0138}", with: "к")
            .precomposedStringWithCanonicalMapping
    }

    func statisticsFixture(_ vacancies: [VacancySearchResult]) -> VacancyStatisticsReport {
        VacancyStatisticsReport(
            entries: vacancies.map(VacancyStatisticsReport.Entry.init), modeName: "Все вакансии",
            employerID: "47858", employerName: "Банк России", regionID: "subject:1", regionName: "Москва",
            createdAt: Date(timeIntervalSince1970: 1_788_400_000), timeZoneIdentifier: "UTC", sourceNote: "Локальная выборка."
        )
    }

    func statisticsVacancy(id: String, date: String?, salary: Bool = false, archived: Bool = false) -> VacancySearchResult {
        let summary = documentedTestSummary(HHVacancySummary(
            id: id, name: "Вакансия \(id)", employer: .init(name: "Банк России", id: "47858"),
            salary: salary ? .init(from: 100_000, to: nil, currency: "RUR", gross: false) : nil,
            area: .init(id: "1", name: "Москва"), alternateURL: nil, url: nil, snippet: nil, publishedAt: date
        ))
        return VacancySearchResult(
            id: id, summary: summary,
            details: .init(id: id, name: summary.name, employer: summary.employer, area: summary.area,
                           salary: summary.salary, alternateURL: nil, description: nil, archived: archived),
            location: .subject(id: "1", name: "Москва", cityID: "1", cityName: "Москва")
        )
    }



    func makePDFVacancy(id: String) -> VacancySearchResult {
        let vacancy = summary(id: id, areaID: "1", areaName: "Москва")
        return VacancySearchResult(
            id: vacancy.id,
            summary: vacancy,
            details: .init(
                id: vacancy.id,
                name: "Инженер надёжности \(id)",
                employer: vacancy.employer,
                area: vacancy.area,
                salary: nil,
                alternateURL: "https://hh.ru/vacancy/\(id)",
                description: "<p>Кириллица, Unicode и длинная строка: надёжность-производительность-HeadHunter-PDF.</p>",
                archived: false,
                keySkills: [.init(name: "Swift"), .init(name: "macOS")]
            ),
            location: .subject(id: "1", name: "Москва", cityID: "1", cityName: "Москва"),
            isDetailLoaded: true
        )
    }

    @MainActor
    func checkLiveDetailCancellation(transition: LiveCancellationTransition) async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HHVACANCYCBR_RUN_LIVE_CANCELLATION_TESTS"] == "1",
            "Opt-in live cancellation group; at most four GET requests for all three tests."
        )
        let run = LiveCancellationRun.shared
        try XCTSkipIf(run.stopped, "Live group stopped after an earlier API or transport failure; no further requests.")
        defer {
            let attachment = XCTAttachment(string: run.journal)
            attachment.name = "Live cancellation request journal"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let rows = try await run.searchRows()
        try XCTSkipIf(rows.count < 3, "Need three distinct live vacancies for three detail requests; no extra search.")
        let source = rows[transition.rawValue]
        let received = expectation(description: "Real detail response received before publication")
        let cancelled = expectation(description: "Hidden card detail Task is cancelled")
        let resume = TestAsyncSignal()
        let fixture = FixedSummaryAPIClient(rows: rows, detailLoader: { id in
            let details = try await run.detail(id: id)
            received.fulfill()
            // Hold the genuine response at the client boundary; do not fabricate a
            // response or cancel the transport ourselves. The ViewModel owns cancellation.
            await resume.wait()
            if Task.isCancelled { cancelled.fulfill() }
            return details
        })
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = VacancySearchViewModel(
            apiClient: fixture,
            employerStore: TestEmployerStore(entries: [.init(id: "47858", name: "Банк России", comment: "live fixture")]),
            areaStore: AreaDirectoryStore(fileURL: directory.appendingPathComponent("areas.json"))
        )
        await model.search()
        let sourceIndex = try XCTUnwrap(model.results.firstIndex { $0.id == source.id })
        XCTAssertFalse(model.results[sourceIndex].isDetailLoaded)
        model.toggleExplanation(for: source.id)
        await fulfillment(of: [received], timeout: 25)
        // API errors stop the shared group, including later XCTest cases.
        guard !run.stopped else {
            await resume.signal()
            XCTFail("Live request failed; inspect the status-only journal.")
            return
        }
        XCTAssertTrue(model.results[sourceIndex].isDetailLoading)
        XCTAssertEqual(model.expandedVacancyID, source.id)
        switch transition {
        case .employer: model.selectedEmployerID = "nspk"
        case .region: model.selectedRegionID = "subject:66"
        }
        XCTAssertNil(model.expandedVacancyID)
        XCTAssertFalse(model.displayedResults.contains { $0.id == source.id })
        await resume.signal()
        await fulfillment(of: [cancelled], timeout: 2)
        for _ in 0..<1000 where model.results[sourceIndex].isDetailLoading {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(model.results[sourceIndex].isDetailLoading)
        XCTAssertFalse(model.results[sourceIndex].isDetailLoaded)
        XCTAssertNil(model.results[sourceIndex].detailErrorMessage)
        XCTAssertNil(model.errorMessage)
        XCTAssertLessThanOrEqual(run.requestCount, 4)
    }

    @MainActor
    func makeFilterViewModel() -> VacancySearchViewModel {
        VacancySearchViewModel(
            apiClient: MockAPIClient(mode: .filters),
            employerStore: TestEmployerStore(entries: [
                .init(id: "1654251", name: "НСПК", comment: "test"),
                .init(id: "47858", name: "Банк России", comment: "test"),
                .init(id: "9999", name: "Альфа Банк", comment: "test")
            ]),
            areaStore: AreaDirectoryStore(fileURL: temporaryDirectory().appendingPathComponent("areas.json"))
        )
    }

    @MainActor
    func assertStatisticsExport(_ model: VacancySearchViewModel, client: MockAPIClient,
                                        panel: StatisticsDestinationSpy, employer: String, region: String,
                                        expected: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
        model.selectedEmployerID = employer == "all" ? "all" : OrganizationRegistry.key(forHH: employer)
        model.selectedRegionID = region
        let snapshot = model.statisticsReportSnapshot()
        let context = "\("hh.ru") / \(employer) / \(region)"
        XCTAssertEqual(Set(snapshot.entries.map(\.id)), Set(expected), context, file: file, line: line)
        let beforeSearch = await client.searchRequestCount
        let beforeDetails = await client.detailRequestCount
        if expected.isEmpty { XCTAssertFalse(model.canExportStatisticsPDF); return }
        panel.destination = panel.destination?.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".pdf")
        await model.exportStatisticsPDF()
        let pdf = try XCTUnwrap(PDFDocument(url: XCTUnwrap(panel.destination)), context, file: file, line: line)
        let text = try extractedStatisticsText(pdf)
        XCTAssertGreaterThan(pdf.pageCount, 0, context, file: file, line: line)
        XCTAssertTrue(text.contains("Всего вакансий: \(expected.count)"), context, file: file, line: line)
        XCTAssertEqual(text.contains("Список: \(snapshot.modeName)"), snapshot.modeName != "Все вакансии", context, file: file, line: line)
        XCTAssertEqual(text.contains("Работодатель: \(snapshot.employerName)"), employer != "all", context, file: file, line: line)
        XCTAssertEqual(text.contains("Регион: \(snapshot.regionName)"), region != "all", context, file: file, line: line)
        let expectedRows = statisticsFilterRows.filter { expected.contains($0.id) }
        XCTAssertTrue(text.contains("Работодателей: \(Set(expectedRows.map(\.employer)).count)"), context, file: file, line: line)
        XCTAssertTrue(text.contains("Регионов / территориальных групп: \(Set(expectedRows.map(\.region)).count)"), context, file: file, line: line)
        for row in statisticsFilterRows {
            XCTAssertEqual(text.contains("Вакансия \(row.id)"), expected.contains(row.id), context, file: file, line: line)
        }
        // Fixture 47858 was published a day later than the other employers.
        let expectedOrder = expectedRows.sorted {
            if ($0.employer == "47858") != ($1.employer == "47858") { return $0.employer == "47858" }
            return $0.id < $1.id
        }
        var previousPosition = -1
        for row in expectedOrder {
            let position = (text as NSString).range(of: "Вакансия \(row.id)").location
            XCTAssertNotEqual(position, NSNotFound, context, file: file, line: line)
            XCTAssertGreaterThan(position, previousPosition, context, file: file, line: line)
            previousPosition = position
        }
        XCTAssertEqual(panel.names.last, snapshot.fileName, context, file: file, line: line)
        XCTAssertFalse(model.isExportingStatisticsPDF, context, file: file, line: line)
        XCTAssertTrue(model.statisticsPDFExportMessage?.contains("сохранён: \(expected.count)") == true, context, file: file, line: line)
        let afterSearch = await client.searchRequestCount
        let afterDetails = await client.detailRequestCount
        XCTAssertEqual(afterSearch, beforeSearch, context, file: file, line: line)
        XCTAssertEqual(afterDetails, beforeDetails, context, file: file, line: line)
    }

    @MainActor
    func enrichmentModel(client: PDFEnrichmentClient, exporter: PDFEnrichmentExporter) async -> VacancySearchViewModel {
        let dir = temporaryDirectory()
        let store = VacancySnapshotStore(fileURL: dir.appendingPathComponent("vacancies.json"))
        try! store.save(VacancySnapshot(values: (1...3).map { statisticsVacancy(id: String($0), date: "2026-09-01T10:00:00Z") }, issues: [], updatedAt: Date()))
        let model = VacancySearchViewModel(apiClient: client,
            employerStore: TestEmployerStore(entries: [.init(id: "47858", name: "Банк России", comment: "test")]),
            snapshotStore: store, bulkPDFExporter: exporter)
        await model.loadPersistenceIfNeeded()
        return model
    }

    func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HHVacancyCBRTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }


    func makeHTTPClient(
        handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)
    ) -> HHAPIClient {
        URLProtocolStub.handler = handler
        return HTTPClientFactory.make()
    }

    func assertAPIError(_ client: HHAPIClient, equals expected: HHAPIError) async {
        do {
            _ = try await client.searchVacancies(.init(employerID: "47858"))
            XCTFail("Expected \(expected)")
        } catch let error as HHAPIError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func summary(
        id: String,
        employerID: String = "47858",
        areaID: String?,
        areaName: String?,
        workFormat: [HHNamedItem]? = nil,
        areas: [HHArea]? = nil
    ) -> HHVacancySummary {
        documentedTestSummary(HHVacancySummary(
            id: id, name: "Вакансия \(id)", employer: .init(name: "Банк России", id: employerID), salary: nil,
            area: areaID.map { .init(id: $0, name: areaName) }, alternateURL: "https://example.invalid/\(id)",
            url: nil, snippet: nil, workFormat: workFormat, publishedAt: "2026-09-01T10:00:00+0300", areas: areas
        ))
    }
}
