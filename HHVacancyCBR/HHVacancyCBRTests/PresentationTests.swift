import AppKit
import Foundation
import PDFKit
import XCTest
import SwiftUI
@testable import HHVacancyCBR

extension HHVacancyCBRTests {

    @MainActor
    func testViewModelUsesEmployerAndRegionFiltersWithANDSemantics() async throws {
        let employerStore = TestEmployerStore(entries: [
            .init(id: "47858", name: "Банк России", comment: "test"),
            .init(id: "1654251", name: "НСПК", comment: "test")
        ])
        let model = VacancySearchViewModel(
            apiClient: MockAPIClient(mode: .simple),
            employerStore: employerStore,
            areaStore: AreaDirectoryStore(fileURL: temporaryDirectory().appendingPathComponent("areas.json")),
            currentDate: { Date(timeIntervalSince1970: 1_788_200_000) }
        )
        await model.search()
        XCTAssertEqual(model.results.count, 2)
        XCTAssertEqual(model.displayedResults.map(\.id), ["47858-vacancy", "1654251-vacancy"])
        model.selectedEmployerID = "bank_of_russia"
        model.selectedRegionID = "subject:1"
        XCTAssertEqual(model.displayedResults.map(\.id), ["47858-vacancy"])
        model.selectedRegionID = "remote"
        XCTAssertTrue(model.displayedResults.isEmpty)
    }

    @MainActor
    func testFilterOptionsAreDeduplicatedSortedAndGroupCitiesBySubject() async {
        let model = makeFilterViewModel()
        await model.search()

        XCTAssertEqual(model.employerFilterOptions.map(\.id), ["all", "hh_account_9999", "bank_of_russia", "nsis", "nspk", "rnpk", "rosinkas"])
        XCTAssertEqual(model.employerFilterOptions.map(\.title), [
            "Все работодатели", "Альфа Банк", "Банк России", "НСИС", "НСПК", "РНПК", "РОСИНКАС"
        ])
        XCTAssertEqual(Set(model.employerFilterOptions.map(\.id)).count, model.employerFilterOptions.count)

        XCTAssertEqual(model.regionFilterOptions.first, .init(id: "all", title: "Все регионы"))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: model.regionFilterOptions.map { ($0.id, $0.title) }), [
            "all": "Все регионы",
            "remote": "Удалённо",
            "unknown": "Регион не определён",
            "subject:1": "Москва",
            "subject:2": "Санкт-Петербург",
            "subject:66": "Свердловская область"
        ])
        XCTAssertEqual(Set(model.regionFilterOptions.map(\.id)).count, model.regionFilterOptions.count)
    }

    @MainActor
    func testDropdownSelectionsApplyEmployerRegionAndANDCombinations() async {
        let model = makeFilterViewModel()
        await model.search()

        model.selectedEmployerID = "bank_of_russia"
        XCTAssertEqual(Set(model.displayedResults.map(\.id)), ["filter-moscow", "filter-ekb", "filter-unknown"])
        XCTAssertEqual(model.displayedVacancyCountMessage, "Вакансий: 3")

        model.selectedRegionID = "subject:66"
        XCTAssertEqual(model.displayedResults.map(\.id), ["filter-ekb"])
        XCTAssertEqual(model.displayedVacancyCountMessage, "Вакансий: 1")

        model.selectedEmployerID = "nspk"
        XCTAssertTrue(model.displayedResults.isEmpty)
        XCTAssertEqual(model.displayedVacancyCountMessage, "Вакансий: 0")

        model.selectedRegionID = "remote"
        XCTAssertEqual(model.displayedResults.map(\.id), ["filter-remote"])

        model.selectedEmployerID = "all"
        model.selectedRegionID = "all"
        XCTAssertEqual(model.displayedResults.count, 5)
        XCTAssertEqual(model.displayedVacancyCountMessage, "Вакансий: 5")
    }



    @MainActor
    func testChangingDropdownSelectionCollapsesAHiddenExpandedVacancy() async {
        let model = makeFilterViewModel()
        await model.search()
        model.toggleExplanation(for: "filter-moscow")
        XCTAssertEqual(model.expandedVacancyID, "filter-moscow")

        model.selectedRegionID = "subject:66"

        XCTAssertNil(model.expandedVacancyID)
    }


    @MainActor
    func testFilterChangeKeepingExpandedVacancyVisiblePreservesInFlightDetails() async throws {
        let started = expectation(description: "visible detail suspended")
        let resume = TestAsyncSignal()
        let client = MockAPIClient(mode: .simple, beforeFirstDetailResponse: {
            started.fulfill()
            await resume.wait()
            try Task.checkCancellation()
        })
        let model = VacancySearchViewModel(
            apiClient: client,
            employerStore: TestEmployerStore(entries: [.init(id: "47858", name: "Банк России", comment: "test")]),
            areaStore: AreaDirectoryStore(fileURL: temporaryDirectory().appendingPathComponent("areas.json"))
        )
        await model.search()
        model.toggleExplanation(for: "47858-vacancy")
        await fulfillment(of: [started], timeout: 2)
        model.selectedEmployerID = "bank_of_russia"
        model.selectedRegionID = "subject:1"
        XCTAssertEqual(model.expandedVacancyID, "47858-vacancy")
        await resume.signal()
        for _ in 0..<1000 where model.results[0].isDetailLoading {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(model.results[0].isDetailLoading)
        XCTAssertTrue(model.results[0].isDetailLoaded)
        XCTAssertNil(model.results[0].detailErrorMessage)
        let requestCount = await client.detailRequestCount
        XCTAssertEqual(requestCount, 1)
    }


    @MainActor
    func testLazyDetailsLoadUpdatesOnlyRequestedCard() async throws {
        let model = VacancySearchViewModel(
            apiClient: MockAPIClient(mode: .simple),
            employerStore: TestEmployerStore(entries: [.init(id: "47858", name: "Банк России", comment: "test")]),
            areaStore: AreaDirectoryStore(fileURL: temporaryDirectory().appendingPathComponent("areas.json"))
        )
        await model.search()
        XCTAssertFalse(model.results[0].isDetailLoaded)
        await model.loadVacancyDetails(id: "47858-vacancy")
        XCTAssertTrue(model.results.first { $0.id == "47858-vacancy" }?.isDetailLoaded == true)
        XCTAssertEqual(model.results.first { $0.id == "47858-vacancy" }?.plainTextDescription, "Полное описание")
    }

    @MainActor
    func testCompletedRefreshIgnoresDetailResponseFromPreviousResults() async {
        let client = MockAPIClient(mode: .delayedArchive)
        let model = VacancySearchViewModel(
            apiClient: client,
            employerStore: TestEmployerStore(entries: [.init(id: "47858", name: "Банк России", comment: "test")]),
            areaStore: AreaDirectoryStore(fileURL: temporaryDirectory().appendingPathComponent("areas.json"))
        )
        await model.search()

        let detail = Task { await model.loadVacancyDetails(id: "47858-vacancy") }
        while await client.detailRequestCount == 0 { await Task.yield() }
        await model.refreshVacancies()
        await detail.value

        XCTAssertFalse(model.results[0].isDetailLoaded)
    }

    @MainActor
    func testFailedRefreshDoesNotDiscardDetailLoadedWhileRefreshWasRunning() async {
        let client = MockAPIClient(mode: .delayedRefreshFailure)
        let model = VacancySearchViewModel(
            apiClient: client,
            employerStore: TestEmployerStore(entries: [.init(id: "47858", name: "Банк России", comment: "test")]),
            areaStore: AreaDirectoryStore(fileURL: temporaryDirectory().appendingPathComponent("areas.json"))
        )
        await model.search()

        let initialRequestCount = await client.searchRequestCount
        await client.enableDelayedSearchFailure()
        let refresh = Task { await model.refreshVacancies() }
        while await client.searchRequestCount == initialRequestCount { await Task.yield() }
        await model.loadVacancyDetails(id: "47858-vacancy")
        await refresh.value

        XCTAssertTrue(model.results[0].isDetailLoaded)
        XCTAssertEqual(model.results[0].plainTextDescription, "Полное описание")
    }














    @MainActor
    func testStartedRefreshCanBeCancelledAndKeepsPreviousResults() async {
        let client = MockAPIClient(mode: .delayedRefreshFailure)
        let model = VacancySearchViewModel(
            apiClient: client,
            employerStore: TestEmployerStore(entries: [.init(id: "47858", name: "Банк России", comment: "test")]),
            areaStore: AreaDirectoryStore(fileURL: temporaryDirectory().appendingPathComponent("areas.json"))
        )
        await model.search()
        let initialRequestCount = await client.searchRequestCount
        await client.enableDelayedSearchFailure()

        model.startRefresh()
        XCTAssertFalse(model.canSearch)
        while await client.searchRequestCount == initialRequestCount { await Task.yield() }
        XCTAssertTrue(model.canCancelSearch)
        model.cancelSearch()
        XCTAssertTrue(model.isCancellingSearch)
        XCTAssertFalse(model.canCancelSearch)
        while !model.canSearch { await Task.yield() }

        XCTAssertEqual(model.statusMessage, "Поиск отменён.")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isCancellingSearch)
        XCTAssertEqual(model.results.map(\.id), ["47858-vacancy"])
    }

    @MainActor
    func testHHSearchUsesSnippetAndLoadedDescriptionOnlyAfterSubmit() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = VacancySnapshotStore(fileURL: directory.appendingPathComponent("snapshot.json"))
        let row = statisticsVacancy(id: "search", date: "2026-09-01T10:00:00Z")
        let summary = HHVacancySummary(id: row.id, name: row.name, employer: row.summary.employer,
            salary: nil, area: row.summary.area, alternateURL: nil, url: nil,
            snippet: .init(requirement: "Требуется аналитик данных", responsibility: nil),
            publishedAt: row.summary.publishedAt)
        let value = VacancySearchResult(id: row.id, summary: summary,
            details: .init(id: row.id, name: row.name, employer: row.summary.employer,
                area: row.summary.area, salary: nil, alternateURL: nil,
                description: "<p>Управление рисками</p>"),
            location: row.location, isDetailLoaded: true)
        try store.save(.init(values: [value], issues: [], updatedAt: Date()))
        let model = VacancySearchViewModel(apiClient: FixedSummaryAPIClient(rows: []),
            employerStore: TestEmployerStore(entries: [.init(id: "47858", name: "Банк России", comment: "test")]),
            areaStore: AreaDirectoryStore(fileURL: directory.appendingPathComponent("areas.json")), snapshotStore: store)
        await model.loadPersistenceIfNeeded()
        model.searchDraft = "рисками"
        XCTAssertEqual(model.displayedResults.count, 1)
        model.applySearch()
        XCTAssertEqual(model.displayedResults.map(\.id), ["search"])
        model.searchDraft = "аналитик данных"
        model.applySearch()
        XCTAssertEqual(model.displayedResults.map(\.id), ["search"])
        model.searchDraft = "отсутствующее слово"
        model.applySearch()
        XCTAssertTrue(model.displayedResults.isEmpty)
        model.clearSearch()
        XCTAssertEqual(model.displayedResults.map(\.id), ["search"])
    }


    @MainActor
    func testSearchOrdersFractionalDatesBeforeOlderWholeSecondDates() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = [statisticsVacancy(id: "old", date: "2026-09-01T10:00:00Z"),
                    statisticsVacancy(id: "new", date: "2026-09-01T10:00:00.900Z")]
        let model = VacancySearchViewModel(apiClient: FixedSummaryAPIClient(rows: rows.map(\.summary)),
            employerStore: TestEmployerStore(entries: [.init(id: "47858", name: "Банк России", comment: "test")]),
            areaStore: AreaDirectoryStore(fileURL: directory.appendingPathComponent("areas.json")))
        await model.search()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.results.map(\.id), ["new", "old"])
    }
    @MainActor
    func testBulkLongVacancyContinuesAcrossPartsWithoutLosingParagraphs() async throws {
        let vacancy = try TrudFixture.documented("long")
        let text = (0..<6500).map { "Строка \($0): Полное описание вакансии, проверка продолжения.\n" }.joined()
        let document = PDFVacancySnapshot(context: vacancy.context, document: NSAttributedString(string: text, attributes: [.font: VacancyPDFStyle.bodyFont]))
        let worker = PDFExportWorker(), dir = temporaryDirectory()
        let prepared = try await worker.prepare(vacancies: PDFVacanciesSnapshot(snapshots: [document])) { _ in }
        XCTAssertGreaterThan(prepared.partCount, 1)
        let urls = try await worker.writePrepared(names: (0..<prepared.partCount).map { "part\($0).pdf" }, directory: dir)
        var combined = ""
        for url in urls {
            let pdf = try XCTUnwrap(PDFDocument(url: url)); XCTAssertLessThanOrEqual(pdf.pageCount, 100); XCTAssertGreaterThan(pdf.pageCount, 0)
            let partText = try XCTUnwrap(pdf.string)
            XCTAssertEqual(partText.components(separatedBy: "Данные для проверки").count - 1, 1)
            XCTAssertGreaterThan(try XCTUnwrap(partText.range(of: "Данные для проверки")?.lowerBound),
                                 try XCTUnwrap(partText.range(of: "Строка ", options: .backwards)?.lowerBound))
            combined += partText
            let raw = try Data(contentsOf: url)
            for material in try PDFSourceEvidence.shared.materials(for: vacancy.context) { XCTAssertNotNil(raw.range(of: material.data)) }
        }
        // Scan once: repeated Unicode substring searches made this assertion quadratic.
        let extracted = combined as NSString
        let markers = try NSRegularExpression(pattern: "Строка ([0-9]+):")
        let indices = markers.matches(in: combined, range: NSRange(location: 0, length: extracted.length))
            .compactMap { Int(extracted.substring(with: $0.range(at: 1))) }
        XCTAssertEqual(indices, Array(0..<6500), "Every source line must appear once, in order")
        XCTAssertTrue(combined.contains("Продолжение"))
    }
    @MainActor
    func testBulkFreezesFilteredRowsAndFiltersBeforeEnrichment() async throws {
        let client = PDFEnrichmentClient(delay: 20_000_000), exporter = PDFEnrichmentExporter()
        let model = await enrichmentModel(client: client, exporter: exporter)
        model.selectedEmployerID = "bank_of_russia"
        let expected = model.displayedResults.map(\.id)
        let export = Task { await model.exportVacanciesPDF() }
        for _ in 0..<1000 {
            if await client.requests > 0 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        model.selectedEmployerID = "nsis"
        XCTAssertTrue(model.displayedResults.isEmpty)
        await export.value
        XCTAssertEqual(exporter.snapshots.first?.map(\.id), expected)
        XCTAssertEqual(exporter.snapshots.first?.count, 3)
    }
}
