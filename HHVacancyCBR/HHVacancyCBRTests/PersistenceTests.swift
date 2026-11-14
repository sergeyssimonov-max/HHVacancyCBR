import AppKit
import Foundation
import PDFKit
import XCTest
import SwiftUI
@testable import HHVacancyCBR

extension HHVacancyCBRTests {

    @MainActor
    func testRefreshSchedulerCancellationDoesNotLeakPermit() async throws {
        try await VacancyRefreshScheduler.acquire()
        let waiting = Task { try await VacancyRefreshScheduler.acquire() }
        await Task.yield()
        waiting.cancel()
        do { try await waiting.value; XCTFail("Cancelled waiter acquired a permit") }
        catch { XCTAssertTrue(error is CancellationError) }
        VacancyRefreshScheduler.release()
        try await VacancyRefreshScheduler.acquire()
        VacancyRefreshScheduler.release()
    }

    @MainActor
    func testRefreshSchedulerTransfersPermit() async throws {
        try await VacancyRefreshScheduler.acquire()
        let waiting = Task {
            try await VacancyRefreshScheduler.acquire()
            VacancyRefreshScheduler.release()
        }
        await Task.yield()
        VacancyRefreshScheduler.release()
        try await waiting.value
        try await VacancyRefreshScheduler.acquire()
        VacancyRefreshScheduler.release()
    }

    @MainActor
    func testSnapshotRestoresCompleteAndPartialResultsWithoutNetworkAndRefreshUsesNetwork() async throws {
        for partial in [false, true] {
            let directory = temporaryDirectory()
            let store = VacancySnapshotStore(fileURL: directory.appendingPathComponent("vacancies.json"))
            let entries = ["1", "2", "3"].map { EmployerConfigurationEntry(id: $0, name: $0, comment: "test") }
            let date = Date(timeIntervalSince1970: 1_788_200_000)
            let client = EmployerScriptedClient(behaviors: [
                "1": .vacancies(2), "2": partial ? .restriction(.rateLimited(retryAfterSeconds: 60)) : .vacancies(1),
                "3": .vacancies(1)
            ])
            let original = VacancySearchViewModel(apiClient: client, employerStore: TestEmployerStore(entries: entries),
                areaStore: AreaDirectoryStore(fileURL: directory.appendingPathComponent("areas.json")),
                snapshotStore: store, currentDate: { date })
            await original.refreshVacancies()
            XCTAssertNil(original.errorMessage)
            XCTAssertNil(original.snapshotWarning)
            XCTAssertTrue(original.canSearch)
            if partial {
                XCTAssertNil(try store.load()); XCTAssertTrue(original.results.isEmpty)
                XCTAssertNotNil(original.collectionWarning)
                continue
            }
            let saved = try XCTUnwrap(store.load())
            XCTAssertEqual(saved.updatedAt, date)
            XCTAssertEqual(saved.issues.isEmpty, !partial)
            XCTAssertEqual(saved.vacancies.count, partial ? 2 : 4)
            if partial {
                XCTAssertTrue(original.collectionWarning?.contains("Сбор остановлен ограничением hh.ru") == true)
                let requested = await client.requestedEmployerIDs
                XCTAssertEqual(requested, ["1", "2"])
            }
            let offline = EmployerScriptedClient(behaviors: ["1": .vacancies(5), "2": .vacancies(0), "3": .vacancies(0)])
            let restored = VacancySearchViewModel(apiClient: offline, employerStore: TestEmployerStore(entries: entries),
                areaStore: AreaDirectoryStore(fileURL: directory.appendingPathComponent("areas-restored.json")),
                snapshotStore: store, currentDate: { date })
            await restored.loadPersistenceIfNeeded()
            let initialRequests = await offline.requestedEmployerIDs
            XCTAssertTrue(initialRequests.isEmpty)
            XCTAssertEqual(restored.results.map(\.id), original.results.map(\.id))
            XCTAssertEqual(restored.results.map(\.location), original.results.map(\.location))
            XCTAssertEqual(restored.updatedAtMessage, original.updatedAtMessage)
            XCTAssertEqual(restored.collectionWarning, original.collectionWarning)
            XCTAssertTrue(restored.hasSearched)
            XCTAssertTrue(restored.canSearch)
            XCTAssertTrue(restored.canExportStatisticsPDF)
            XCTAssertEqual(restored.statisticsReportSnapshot().sourceNote.contains("Выгрузка общего списка неполная"), partial)
            if partial {
                // Incomplete snapshots never satisfy the in-memory TTL path.
                await restored.search()
            } else {
                await restored.refreshVacancies()
            }
            let refreshedRequests = await offline.requestedEmployerIDs
            XCTAssertEqual(refreshedRequests, ["1", "2", "3"])
            XCTAssertEqual(restored.results.count, 5)
            XCTAssertNil(restored.collectionWarning)
            XCTAssertTrue(try XCTUnwrap(store.load()).issues.isEmpty)
        }
    }

    @MainActor
    func testIncompleteFailedAndCancelledRefreshDoNotOverwriteCompleteDiskSnapshot() async throws {
        let directory = temporaryDirectory()
        let store = VacancySnapshotStore(fileURL: directory.appendingPathComponent("vacancies.json"))
        let client = EmployerScriptedClient(behaviors: ["1": .vacancies(150)])
        let model = VacancySearchViewModel(apiClient: client,
            employerStore: TestEmployerStore(entries: [.init(id: "1", name: "One", comment: "test")]),
            areaStore: AreaDirectoryStore(fileURL: directory.appendingPathComponent("areas.json")), snapshotStore: store)
        await model.refreshVacancies()
        let savedBytes = try Data(contentsOf: store.fileURL)
        let timestamp = model.updatedAtMessage
        for behavior: EmployerScriptedClient.Behavior in [
            .restrictionAfterFirstPage(150, .rateLimited(retryAfterSeconds: nil)), .failure, .cancelled
        ] {
            await client.setBehavior(behavior, employerID: "1")
            await model.refreshVacancies()
            XCTAssertEqual(model.results.count, 150)
            XCTAssertEqual(model.updatedAtMessage, timestamp)
            XCTAssertEqual(try Data(contentsOf: store.fileURL), savedBytes)
            XCTAssertTrue(model.canSearch)
        }
    }

    @MainActor
    func testSnapshotLoadFailureLeavesRefreshAvailableAndSuccessfulRefreshRepairsCache() async throws {
        for contents in ["not JSON", "{\"version\":99}"] {
            let directory = temporaryDirectory()
            let store = VacancySnapshotStore(fileURL: directory.appendingPathComponent("vacancies.json"))
            try Data(contents.utf8).write(to: store.fileURL)
            let client = EmployerScriptedClient(behaviors: ["1": .vacancies(1)])
            let model = VacancySearchViewModel(apiClient: client,
                employerStore: TestEmployerStore(entries: [.init(id: "1", name: "One", comment: "test")]),
                areaStore: AreaDirectoryStore(fileURL: directory.appendingPathComponent("areas.json")), snapshotStore: store)
            await model.loadPersistenceIfNeeded()
            XCTAssertNotNil(model.snapshotWarning)
            XCTAssertTrue(model.canSearch)
            XCTAssertTrue(model.results.isEmpty)
            XCTAssertEqual(try String(contentsOf: store.fileURL), contents)
            await model.refreshVacancies()
            XCTAssertNil(model.snapshotWarning)
            XCTAssertEqual(try XCTUnwrap(store.load()).vacancies.count, 1)
        }
    }

    @MainActor
    func testSnapshotSaveFailureKeepsReceivedResultsAndReportsWarning() async throws {
        let directory = temporaryDirectory()
        let blocker = directory.appendingPathComponent("file")
        try Data("existing data".utf8).write(to: blocker)
        let store = VacancySnapshotStore(fileURL: blocker.appendingPathComponent("vacancies.json"))
        let model = VacancySearchViewModel(apiClient: EmployerScriptedClient(behaviors: ["1": .vacancies(2)]),
            employerStore: TestEmployerStore(entries: [.init(id: "1", name: "One", comment: "test")]),
            areaStore: AreaDirectoryStore(fileURL: directory.appendingPathComponent("areas.json")), snapshotStore: store)
        await model.refreshVacancies()
        XCTAssertEqual(model.results.count, 2)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.snapshotWarning?.contains("Не удалось сохранить снимок вакансий") == true)
        XCTAssertTrue(model.canSearch)
        XCTAssertEqual(try String(contentsOf: blocker), "existing data")
    }

    func testSnapshotStoreMissingEmptyAndDuplicateRecords() throws {
        let store = VacancySnapshotStore(fileURL: temporaryDirectory().appendingPathComponent("vacancies.json"))
        XCTAssertNil(try store.load())
        let date = Date(timeIntervalSince1970: 1_788_200_000)
        try store.save(.init(values: [], issues: [], updatedAt: date))
        let empty = try XCTUnwrap(store.load())
        XCTAssertEqual(empty.updatedAt, date)
        XCTAssertTrue(empty.vacancies.isEmpty)
        XCTAssertTrue(empty.issues.isEmpty)
        let row = VacancySearchResult(summary: summary(id: "duplicate", areaID: "1", areaName: "Москва"), location: .unknown)
        try store.save(.init(values: [row, row], issues: [], updatedAt: date))
        XCTAssertThrowsError(try store.load())
    }

    @MainActor
    func testPartialSearchShowsReceivedVacanciesWithWarningAndBypassesCache() async {
        let client = EmployerScriptedClient(behaviors: ["1": .vacancies(2), "2": .failure])
        let model = VacancySearchViewModel(
            apiClient: client,
            employerStore: TestEmployerStore(entries: [
                .init(id: "1", name: "Первый", comment: "test"), .init(id: "2", name: "Второй", comment: "test")
            ]),
            areaStore: AreaDirectoryStore(fileURL: temporaryDirectory().appendingPathComponent("areas.json"))
        )

        await model.search()
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.collectionWarning?.hasPrefix("Выгрузка неполная. Второй – вакансии не получены") == true)
        XCTAssertTrue(model.statusMessage?.hasPrefix("Обновление неполное") == true)
        XCTAssertFalse(model.canExportStatisticsPDF)

        let requestsAfterFirstSearch = await client.requestedEmployerIDs.count
        await model.search()
        let requestsAfterSecondSearch = await client.requestedEmployerIDs.count
        XCTAssertGreaterThan(requestsAfterSecondSearch, requestsAfterFirstSearch, "An incomplete result must not be served from cache")
    }

    @MainActor
    func testIncompleteRefreshPreservesPreviousCompleteSelection() async {
        let client = EmployerScriptedClient(behaviors: ["1": .vacancies(150)])
        let model = VacancySearchViewModel(apiClient: client,
            employerStore: TestEmployerStore(entries: [.init(id: "1", name: "One", comment: "test")]),
            areaStore: AreaDirectoryStore(fileURL: temporaryDirectory().appendingPathComponent("areas.json")))
        await model.search()
        let original = model.results.map(\.id)
        await client.setBehavior(.failAfterFirstPage(150), employerID: "1")
        await model.refreshVacancies()
        XCTAssertEqual(model.results.map(\.id), original)
        XCTAssertEqual(model.results.count, 150)
        XCTAssertTrue(model.collectionWarning?.contains("Сохранена предыдущая полная выборка") == true)
        await model.search()
        XCTAssertEqual(model.results.map(\.id), original)
        XCTAssertNil(model.collectionWarning)
    }

    @MainActor
    func testIndependentRefreshCancellationAndOfflineSnapshots() async throws {
        let dir = temporaryDirectory(), store = TrudvsemSnapshotStore(configuredURL: dir.appendingPathComponent("trud.json"))
        let value = try TrudFixture.documented()
        try store.save(.init(version: 1, vacancies: [value], metrics: [], updatedAt: .distantPast))
        let client = TrudScriptedClient([try TrudFixture.page([])], delay: 30_000_000_000)
        let tv = TrudvsemViewModel(client: client, store: store)
        let hh = makeFilterViewModel()
        tv.load(); hh.selectedEmployerID = "nsis"; tv.selectedEmployerID = "bank_of_russia"
        XCTAssertEqual(tv.results, [value]); XCTAssertFalse(hh.isLoading)
        tv.startRefresh()
        for _ in 0..<100 where !tv.isLoading { await Task.yield() }
        tv.cancelSearch()
        for _ in 0..<1000 where tv.isLoading { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(tv.isLoading); XCTAssertEqual(tv.results, [value]); XCTAssertEqual(tv.updatedAt, .distantPast)
        XCTAssertEqual(hh.selectedEmployerID, "nsis"); XCTAssertNil(hh.errorMessage)
        XCTAssertEqual(try store.load()?.vacancies, [value])
        let failed = TrudvsemViewModel(client: TrudScriptedClient([try TrudFixture.page([], total: 2)]), store: store)
        failed.load(); await failed.refresh()
        XCTAssertNotNil(failed.errorMessage); XCTAssertEqual(failed.results, [value]); XCTAssertEqual(try store.load()?.vacancies, [value])
    }
    func testHHLegacySnapshotAndNewOfflineDetailsRemainReadable() throws {
        let dir = temporaryDirectory(), store = VacancySnapshotStore(fileURL: dir.appendingPathComponent("vacancies.json"))
        let value = makePDFVacancy(id: "offline")
        try store.save(.init(values: [value], issues: [], updatedAt: .distantPast))
        let restored = try XCTUnwrap(store.load()).results[0]
        XCTAssertTrue(restored.isDetailLoaded); XCTAssertEqual(restored.details.description, value.details.description)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        var entries = try XCTUnwrap(json["vacancies"] as? [[String: Any]])
        entries[0].removeValue(forKey: "details"); json["vacancies"] = entries
        try JSONSerialization.data(withJSONObject: json).write(to: store.fileURL)
        let legacy = try XCTUnwrap(store.load()).results[0]
        XCTAssertFalse(legacy.isDetailLoaded); XCTAssertEqual(legacy.id, value.id)
    }
    @MainActor
    func testEachRefreshCallsOnlyItsOwnClientAndPreservesOtherSourceState() async throws {
        let hhClient = MockAPIClient(mode: .simple)
        let hh = VacancySearchViewModel(apiClient: hhClient,
            employerStore: TestEmployerStore(entries: [.init(id: "47858", name: "Банк России", comment: "fixture")]),
            areaStore: AreaDirectoryStore(fileURL: temporaryDirectory().appendingPathComponent("areas.json")))
        let tvClient = TrudScriptedClient([try TrudFixture.page([])])
        let tv = TrudvsemViewModel(client: tvClient, store: .init(configuredURL: temporaryDirectory().appendingPathComponent("tv.json")))
        tv.load()
        let tvBefore = await tvClient.calls.count; XCTAssertEqual(tvBefore, 0)
        await hh.refreshVacancies()
        let tvAfterHH = await tvClient.calls.count; XCTAssertEqual(tvAfterHH, 0)
        let hhRequests = await hhClient.searchRequestCount, hhIDs = hh.results.map(\.id), hhUpdated = hh.updatedAtMessage
        hh.selectedEmployerID = "bank_of_russia"; tv.selectedEmployerID = "nsis"
        await tv.refresh()
        let hhAfterTV = await hhClient.searchRequestCount, tvRequests = await tvClient.calls.count
        XCTAssertEqual(hhAfterTV, hhRequests); XCTAssertEqual(tvRequests, 6)
        XCTAssertEqual(hh.results.map(\.id), hhIDs); XCTAssertEqual(hh.updatedAtMessage, hhUpdated)
        XCTAssertEqual(hh.selectedEmployerID, "bank_of_russia"); XCTAssertEqual(tv.selectedEmployerID, "nsis")
        XCTAssertNil(hh.errorMessage); XCTAssertNil(tv.errorMessage)
    }
}
