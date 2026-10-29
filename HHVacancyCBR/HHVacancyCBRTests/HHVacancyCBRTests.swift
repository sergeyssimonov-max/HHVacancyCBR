import AppKit
import Foundation
import PDFKit
import XCTest
import SwiftUI
@testable import HHVacancyCBR

final class HHVacancyCBRTests: XCTestCase {
    @MainActor
    func testUpdateTimestampUsesLeadingZerosAnd24HourTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        for (hour, minute, expected) in [(7, 6, "07:06"), (0, 0, "00:00"), (23, 59, "23:59")] {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 3, hour: hour, minute: minute)))
            XCTAssertEqual(VacancyDisplayFormat.updatedAt(date), "Обновлено: 03.01.2026, \(expected)")
        }
    }

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

    private func fieldSummary(_ title: String, id: String = "field", employer: String = "47858", description: String? = nil,
                              area: HHArea = .init(id: "1", name: "Москва")) -> HHVacancySummary {
        .init(id: id, name: title, employer: .init(name: "Банк России", id: employer), salary: nil,
              area: area, alternateURL: nil, url: nil, snippet: .init(requirement: description, responsibility: nil),
              publishedAt: "2026-10-17T10:00:00+0300")
    }

    func testFieldInstitutionPositiveAndNegativeEvidence() {
        for title in ["Кассир полевого учреждения Банка России", "Инженер (ПУ Инское)",
                      "Кассир ПУ № 10513", "Полевое учреждение Центрального банка № 99999"] {
            let result = FieldInstitutionClassifier.classify(summary: fieldSummary(title))
            XCTAssertTrue(result.isMember, title)
            XCTAssertNotNil(result.reason)
        }
        for title in ["Полевой инженер", "Работа в полевых условиях", "Кассир, Инское", "Кассир, Заводское",
                      "Специалист Департамента полевых учреждений", "Разработчик для полевых учреждений Банка России",
                      "Документ № 10513", "Кассир ПУ Инское-2"] {
            XCTAssertFalse(FieldInstitutionClassifier.classify(summary: fieldSummary(title)).isMember, title)
        }
        XCTAssertFalse(FieldInstitutionClassifier.classify(summary: fieldSummary("Полевое учреждение Банка России", employer: "999")).isMember)
        XCTAssertFalse(FieldInstitutionClassifier.classify(summary: fieldSummary("Кассир", description: "Взаимодействие с полевыми учреждениями Банка России")).isMember)
        XCTAssertFalse(FieldInstitutionClassifier.classify(summary: fieldSummary("Кассир", description: "Опыт работы в полевом учреждении Банка России")).isMember)
        XCTAssertTrue(FieldInstitutionClassifier.classify(summary: fieldSummary("Кассир", description: "Место работы: в полевом учреждении Банка России Инское")).isMember)
        XCTAssertTrue(FieldInstitutionClassifier.classify(summary: fieldSummary("Кассир", description: "Работа в ПУ Инское")).isMember)
    }

    func testFieldInstitutionVerifiedAccountRequiresDocumentedRegistryEntry() {
        let summary = fieldSummary("Водитель", employer: "123")
        XCTAssertTrue(FieldInstitutionClassifier.classify(summary: summary, registry: [
            .init(aliases: ["Тестовое"], employerIDs: ["123"], source: "https://example.org/test-evidence")
        ]).isMember)
        XCTAssertFalse(FieldInstitutionClassifier.classify(summary: summary, registry: [
            .init(aliases: ["Тестовое"], employerIDs: ["123"], source: "")
        ]).isMember)
    }



    func testFieldInstitutionAdditionalSearchBoundedDeduplicatedAndVerified() async throws {
        let matching = fieldSummary("Кассир ПУ Инское")
        let unrelated = fieldSummary("Полевой инженер", id: "unrelated")
        let foreign = fieldSummary("Кассир ПУ № 10513", id: "foreign", area: .init(id: "foreign", name: "Кант"))
        let client = FieldSearchClient(rows: [matching, unrelated, foreign])
        let result = try await VacancyCollectionService(client: client).collect(
            employers: [.init(id: "47858", name: "Банк России", comment: "test")],
            areas: AreaDirectoryIndex(root: .init(id: "113", name: "Россия")), progress: { _ in })
        XCTAssertEqual(Set(result.vacancies.map(\.id)), ["field", "foreign"])
        XCTAssertEqual(result.vacancies.count, 2)
        XCTAssertFalse(result.isComplete, "A capped supplemental search must disclose the limit")
        let requests = await client.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.filter { $0.text != nil }.map(\.page), [0, 1])
        XCTAssertTrue(requests.filter { $0.text != nil }.allSatisfy { $0.areaID.isEmpty })
    }

    func testFieldInstitutionSupplementalRestrictionIsReported() async throws {
        let client = FieldSearchClient(rows: [fieldSummary("Кассир")], restrictSupplement: true)
        let result = try await VacancyCollectionService(client: client).collect(
            employers: [.init(id: "47858", name: "Банк России", comment: "test")],
            areas: AreaDirectoryIndex(root: .init(id: "113", name: "Россия")), progress: { _ in })
        XCTAssertEqual(result.vacancies.count, 1)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.issues.first?.employerName, "Полевые учреждения")
    }



    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testEmbeddedApplicationTokenIsConfigured() {
        XCTAssertNotNil(HHAuthConfig.configuredAccessToken)
        XCTAssertFalse(HHAuthConfig.configuredAccessToken?.isEmpty ?? true)
    }

    func testEmployerConfigurationRejectsEmptyDuplicateAndInvalidIDs() throws {
        XCTAssertThrowsError(try EmployerConfiguration(version: 1, employers: []).validated())
        XCTAssertThrowsError(try EmployerConfiguration(version: 1, employers: [
            .init(id: "47858", name: "Банк России", comment: "ok"),
            .init(id: "47858", name: "Дубль", comment: "bad")
        ]).validated())
        XCTAssertThrowsError(try EmployerConfiguration(version: 1, employers: [
            .init(id: "not-a-number", name: "Банк России", comment: "bad")
        ]).validated())
    }

    func testEmployerConfigurationCopiesBundledDefaultOnlyOnce() throws {
        let directory = temporaryDirectory()
        let bundled = directory.appendingPathComponent("bundled.json")
        let runtime = directory.appendingPathComponent("runtime/employers.json")
        try Data(#"{"version":1,"employers":[{"id":"47858","name":"Банк России","comment":"verified"}]}"#.utf8).write(to: bundled)
        let store = EmployerConfigurationStore(fileURL: runtime, bundledDefaultURL: bundled)
        XCTAssertEqual(try store.loadOrCreate().employers.first?.id, "47858")
        try Data(#"{"version":1,"employers":[{"id":"1654251","name":"НСПК","comment":"runtime"}]}"#.utf8).write(to: runtime)
        XCTAssertEqual(try store.loadOrCreate().employers.first?.id, "1654251")
    }

    func testEmployerConfigurationDoesNotMigrateFromLegacyFiles() throws {
        let directory = temporaryDirectory()
        let bundled = directory.appendingPathComponent("employers.json")
        let runtime = directory.appendingPathComponent("runtime.json")
        let existing = EmployerConfiguration(version: 1, employers: [.init(id: "47858", name: "Банк России", comment: "existing")])
        let updated = EmployerConfiguration(version: 1, employers: existing.employers + [.init(id: "1654251", name: "НСПК", comment: "new")])
        try JSONEncoder().encode(existing).write(to: directory.appendingPathComponent("employers.legacy-v1.json"))
        try JSONEncoder().encode(existing).write(to: runtime)
        try JSONEncoder().encode(updated).write(to: bundled)
        let legacyURL = directory.appendingPathComponent("employers.legacy-v1.json")
        let before = try Data(contentsOf: legacyURL)
        let store = EmployerConfigurationStore(fileURL: runtime, bundledDefaultURL: bundled)
        XCTAssertEqual(try store.loadOrCreate().employers.first, existing.employers.first)
        XCTAssertEqual(try Data(contentsOf: legacyURL), before)
    }

    func testEmployerConfigurationPreservesEveryKindOfCustomization() throws {
        let directory = temporaryDirectory()
        let bundled = directory.appendingPathComponent("employers.json")
        let legacyURL = directory.appendingPathComponent("employers.legacy-v1.json")
        let runtime = directory.appendingPathComponent("runtime.json")
        let first = EmployerConfigurationEntry(id: "47858", name: "Банк России", comment: "old")
        let second = EmployerConfigurationEntry(id: "1654251", name: "НСПК", comment: "old")
        let extra = EmployerConfigurationEntry(id: "2608647", name: "РНПК", comment: "new")
        try JSONEncoder().encode(EmployerConfiguration(version: 1, employers: [first, second])).write(to: legacyURL)
        try JSONEncoder().encode(EmployerConfiguration(version: 1, employers: [first, second, extra])).write(to: bundled)
        for entries in [[first], [second, first], [first, second, extra],
                        [.init(id: first.id, name: first.name, comment: "my comment"), second],
                        [.init(id: first.id, name: "my name", comment: first.comment), second]] {
            let custom = EmployerConfiguration(version: 1, employers: entries)
            let data = try JSONEncoder().encode(custom)
            try data.write(to: runtime)
            let store = EmployerConfigurationStore(fileURL: runtime, bundledDefaultURL: bundled)
            XCTAssertEqual(Array(try store.loadOrCreate().employers.prefix(custom.employers.count)), custom.employers)
            XCTAssertEqual(try JSONDecoder().decode(EmployerConfiguration.self, from: Data(contentsOf: runtime)).version, 2)
        }
    }

    func testEmployerConfigurationRejectsInvalidRuntimeAndInvalidFirstRunDefault() throws {
        let directory = temporaryDirectory()
        let bundled = directory.appendingPathComponent("employers.json")
        let runtime = directory.appendingPathComponent("runtime.json")
        let invalid = Data("invalid JSON".utf8)
        let valid = try JSONEncoder().encode(EmployerConfiguration(version: 1, employers: [.init(id: "47858", name: "Банк России", comment: "verified")]))
        let store = EmployerConfigurationStore(fileURL: runtime, bundledDefaultURL: bundled)
        try valid.write(to: bundled)
        try invalid.write(to: runtime)
        XCTAssertThrowsError(try store.loadOrCreate())
        XCTAssertEqual(try Data(contentsOf: runtime), invalid)
        try FileManager.default.removeItem(at: runtime)
        try invalid.write(to: bundled)
        XCTAssertThrowsError(try store.loadOrCreate())
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.path))
        try valid.write(to: runtime)
        XCTAssertEqual(try store.loadOrCreate().employers.first?.id, "47858")
    }

    func testEmployerConfigurationBundledCBRPerimeterAndRecovery() throws {
        let bundled = try XCTUnwrap(Bundle.main.url(forResource: "employers", withExtension: "json"))
        let current = try JSONDecoder().decode(EmployerConfiguration.self, from: Data(contentsOf: bundled)).validated()
        XCTAssertEqual(Set(current.employers.map(\.id)), ["47858", "1654251", "125886", "2608647", "9942121"])
        for name in ["employers.legacy-v1", "employers.legacy-44", "employers.legacy-45"] {
            XCTAssertNil(Bundle.main.url(forResource: name, withExtension: "json"))
        }
        let runtime = temporaryDirectory().appendingPathComponent("runtime/employers.json")
        let store = EmployerConfigurationStore(fileURL: runtime, bundledDefaultURL: bundled)
        XCTAssertEqual(try store.loadOrCreate(), current)
        try FileManager.default.removeItem(at: runtime)
        XCTAssertEqual(try store.loadOrCreate(), current)
    }

    func testApplicationIdentityAndPDFNamesAreIndependent() throws {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "local.sergey.HHVacancyCBR")
        XCTAssertEqual(ApplicationSupportLocation.directoryName, "HHVacancyCBR")
        XCTAssertTrue(VacancyPDFDefaults.personalFileName(vacancyID: "1", vacancyName: "Аналитик").hasPrefix("цбвакансии_"))
        XCTAssertTrue(VacancyPDFDefaults.bulkFileName(part: 1, totalParts: 1).hasPrefix("цбвакансии_"))
    }

    func testEmployerConfigurationJointVentureMetadataRoundTrips() throws {
        let legacy = Data(#"{"id":"47858","name":"CBR","comment":"old"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(EmployerConfigurationEntry.self, from: legacy).jointVenture)
        let entry = EmployerConfigurationEntry(id: "999999", name: "Test Joint Venture", comment: "JV", jointVenture: true)
        let encoded = try JSONEncoder().encode(entry)
        XCTAssertEqual(try JSONDecoder().decode(EmployerConfigurationEntry.self, from: encoded), entry)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["joint_venture"] as? Bool, true)
        XCTAssertNil(json["jointVenture"])
    }




    func testSearchResponseSkipsMalformedItemsButKeepsEnvelopeStrict() throws {
        let data = Data(#"{"items":[{"id":"one","name":"One"},{"id":"bad","name":"Bad","salary":"unexpected"},null,42,{"id":"bad-name","name":[]},{"id":"two","name":"Two","new_field":true}],"found":6,"pages":1,"page":0,"per_page":100}"#.utf8)
        let page = try JSONDecoder().decode(HHVacancySearchResponse.self, from: data)
        XCTAssertEqual(page.items.map(\.id), ["one", "two"])
        XCTAssertEqual(page.rejectedItemCount, 4)
        XCTAssertEqual(page.found, 6)
        for invalid in [#"{"items":{},"found":1,"pages":1,"page":0,"per_page":100}"#,
                        #"{"items":[],"found":"one","pages":1,"page":0,"per_page":100}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(HHVacancySearchResponse.self, from: Data(invalid.utf8)))
        }
    }

    func testAreaLeavesAndOptionalDictionaryArraysDefaultToEmpty() throws {
        let root = try JSONDecoder().decode(HHAreaNode.self, from: Data(#"{"id":"113","name":"Россия","areas":[{"id":"1","name":"Москва"},{"id":"2","name":"Санкт-Петербург","areas":null}]}"#.utf8))
        XCTAssertEqual(root.areas.count, 2)
        XCTAssertTrue(root.areas.allSatisfy { $0.areas.isEmpty })
        XCTAssertNoThrow(try AreaDirectoryIndex(root: root))
        for json in [#"{"experience":[]}"#, #"{"experience":[],"work_format":null,"schedule":null}"#] {
            let dictionaries = try JSONDecoder().decode(HHVacancyDictionaries.self, from: Data(json.utf8))
            XCTAssertTrue(dictionaries.workFormat.isEmpty)
            XCTAssertTrue(dictionaries.schedule.isEmpty)
        }
        XCTAssertThrowsError(try JSONDecoder().decode(HHAreaNode.self, from: Data(#"{"id":"1","name":"Москва","areas":{}}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(HHVacancyDictionaries.self, from: Data(#"{"experience":[],"schedule":42}"#.utf8)))
    }

    func testMalformedVacancyTriggersOneLeafRereadAndPersistentShortfall() async throws {
        for repaired in [true, false] {
            var requests = 0
            let client = makeHTTPClient { _ in
                requests += 1
                let second = repaired && requests > 1 ? #"{"id":"two","name":"Two"}"# : #"{"id":"two","name":"Two","salary":[]}"#
                return (200, [:], Data((#"{"items":[{"id":"one","name":"One"},"# + second + #"],"found":2,"pages":1,"page":0,"per_page":100}"#).utf8))
            }
            let result = try await VacancyCollectionService(client: client).collect(
                employers: [.init(id: "1", name: "One", comment: "test")],
                areas: try AreaDirectoryIndex(root: Self.areaTree), progress: { _ in })
            XCTAssertEqual(requests, 2)
            XCTAssertEqual(result.vacancies.count, repaired ? 2 : 1)
            XCTAssertEqual(result.isComplete, repaired)
            if !repaired {
                XCTAssertEqual(result.issues.first?.expected, 2)
                XCTAssertEqual(result.issues.first?.actual, 1)
            }
        }
    }

    func testEntireMalformedPageDoesNotHideLaterPages() async throws {
        var pages: [Int] = []
        let client = makeHTTPClient { request in
            let page = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "page" }!.value!)!
            pages.append(page)
            let items: [[String: Any]] = page == 1
                ? (100..<200).map { ["id": String($0), "name": 42] }
                : (page == 0 ? Array(0..<100) : [200]).map { ["id": String($0), "name": "Valid"] }
            return (200, [:], try JSONSerialization.data(withJSONObject: ["items": items, "found": 201, "pages": 3, "page": page, "per_page": 100]))
        }
        let result = try await VacancyCollectionService(client: client).collect(
            employers: [.init(id: "1", name: "One", comment: "test")],
            areas: try AreaDirectoryIndex(root: Self.areaTree), progress: { _ in })
        XCTAssertEqual(pages, [0, 1, 2, 0, 1, 2])
        XCTAssertEqual(result.vacancies.count, 101)
        XCTAssertTrue(result.vacancies.contains { $0.id == "200" })
        XCTAssertEqual(result.issues.first?.expected, 201)
        XCTAssertEqual(result.issues.first?.actual, 101)
    }

    func testProductionSessionHasBoundedTimeoutsAndTLSDoesNotRetry() async {
        XCTAssertEqual(HHAPIClient.defaultSession.configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(HHAPIClient.defaultSession.configuration.timeoutIntervalForResource, 120)
        for code in [URLError.Code.secureConnectionFailed, .serverCertificateUntrusted, .notConnectedToInternet] {
            var requests = 0
            let client = makeHTTPClient { _ in requests += 1; throw URLError(code) }
            do {
                _ = try await client.searchVacancies(.init(employerID: "1"))
                XCTFail("Expected transport error")
            } catch { XCTAssertEqual((error as? URLError)?.code, code) }
            XCTAssertEqual(requests, 1)
        }
    }

    func testDatePartitionsShareBoundaryAndDeduplicateVacancies() async throws {
        var ranges: [(from: String?, to: String?)] = []
        let client = makeHTTPClient { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let from = query.first { $0.name == "date_from" }?.value
            let to = query.first { $0.name == "date_to" }?.value
            ranges.append((from, to))
            let json = from == nil
                ? #"{"items":[],"found":2001,"pages":20,"page":0,"per_page":100}"#
                : #"{"items":[{"id":"boundary","name":"Boundary"}],"found":1,"pages":1,"page":0,"per_page":100}"#
            return (200, [:], Data(json.utf8))
        }
        let result = try await VacancyCollectionService(client: client).collect(
            employers: [.init(id: "1", name: "One", comment: "test")],
            areas: try AreaDirectoryIndex(root: .init(id: "113", name: "Россия")), progress: { _ in })
        XCTAssertEqual(ranges.count, 3)
        XCTAssertNotNil(ranges[1].to)
        XCTAssertEqual(ranges[1].to, ranges[2].from)
        XCTAssertEqual(result.vacancies.map(\.id), ["boundary"])
    }

    func testLocationClassificationIsStrict() throws {
        let index = try AreaDirectoryIndex(root: Self.areaTree)
        XCTAssertEqual(index.location(for: summary(id: "m", areaID: "1", areaName: "Москва")),
                       .subject(id: "1", name: "Москва", cityID: "1", cityName: "Москва"))
        XCTAssertEqual(index.location(for: summary(id: "e", areaID: "3", areaName: "Екатеринбург")),
                       .subject(id: "66", name: "Свердловская область", cityID: "3", cityName: "Екатеринбург"))
        XCTAssertEqual(index.location(for: summary(id: "r", areaID: nil, areaName: nil,
                                                   workFormat: [.init(id: "REMOTE", name: "Удалённо")])), .remote)
        XCTAssertEqual(index.location(for: summary(id: "foreign", areaID: "999", areaName: "Минск")), .subject(id: "999", name: "Минск", cityID: "999", cityName: "Минск"))
        let multiple = summary(id: "multi", areaID: "1", areaName: "Москва", areas: [
            .init(id: "1", name: "Москва"), .init(id: "2", name: "Санкт-Петербург")
        ])
        XCTAssertEqual(index.location(for: multiple), .subject(id: "1", name: "Москва", cityID: "1", cityName: "Москва"))
    }



    func testCollectorPartitionsOver2000BySubjectAndDeduplicates() async throws {
        let client = MockAPIClient(mode: .partitioned)
        let service = VacancyCollectionService(client: client)
        let values = try await service.collect(
            employers: [.init(id: "47858", name: "Банк России", comment: "test")],
            areas: try AreaDirectoryIndex(root: .init(id: "113", name: "Россия", areas: [
                .init(id: "10", name: "Регион A"), .init(id: "20", name: "Регион B")
            ])),
            progress: { _ in }
        )
        XCTAssertTrue(values.isComplete)
        XCTAssertEqual(values.vacancies.count, 2_001)
        XCTAssertEqual(Set(values.vacancies.map(\.id)).count, 2_001)
    }

    func testCollectorAcceptsMoreVacanciesThanInitiallyFound() async throws {
        let result = try await VacancyCollectionService(client: MockAPIClient(mode: .surplus)).collect(
            employers: [.init(id: "47858", name: "Банк России", comment: "test")],
            areas: try AreaDirectoryIndex(root: Self.areaTree), progress: { _ in })
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(result.vacancies.count, 151)
    }

    func testCollectorRereadsShortLeafOnceThenKeepsPartialResultWithIssue() async throws {
        let client = MockAPIClient(mode: .mismatch)
        let result = try await VacancyCollectionService(client: client).collect(
            employers: [.init(id: "47858", name: "Банк России", comment: "test")],
            areas: try AreaDirectoryIndex(root: Self.areaTree),
            progress: { _ in }
        )

        let requestCount = await client.searchRequestCount
        XCTAssertEqual(result.vacancies.map(\.id), ["only-one"])
        XCTAssertEqual(result.issues, [.init(employerID: "47858", employerName: "Банк России", expected: 2, actual: 1, failures: [])])
        XCTAssertEqual(result.issues.first?.message, "Банк России – ожидалось 2, получено 1")
        XCTAssertEqual(requestCount, 3)
    }

    func testCollectorKeepsOtherEmployersWhenOneEmployerFails() async throws {
        let client = EmployerScriptedClient(behaviors: ["1": .vacancies(3), "2": .failure])
        let result = try await VacancyCollectionService(client: client).collect(
            employers: [.init(id: "1", name: "Первый", comment: "test"), .init(id: "2", name: "Второй", comment: "test")],
            areas: try AreaDirectoryIndex(root: Self.areaTree),
            progress: { _ in }
        )

        XCTAssertEqual(result.vacancies.count, 3)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.issues.map(\.employerID), ["2"])
        XCTAssertNil(result.issues.first?.expected)
        XCTAssertEqual(result.issues.first?.failures.count, 1)
    }

    func testCollectorKeepsPagesReadBeforeLeafFailure() async throws {
        let client = EmployerScriptedClient(behaviors: ["1": .failAfterFirstPage(150)])
        let result = try await VacancyCollectionService(client: client).collect(
            employers: [.init(id: "1", name: "Первый", comment: "test")],
            areas: try AreaDirectoryIndex(root: Self.areaTree),
            progress: { _ in }
        )

        XCTAssertEqual(result.vacancies.count, 100)
        XCTAssertEqual(result.issues.first?.expected, 150)
        XCTAssertEqual(result.issues.first?.actual, 100)
        XCTAssertEqual(result.issues.first?.failures.count, 1)
        XCTAssertTrue(result.issues.first?.failures.first?.contains("стр. 2") == true)
    }

    func testCollectorThrowsWhenNothingWasReadBecauseOfFailures() async throws {
        let client = EmployerScriptedClient(behaviors: ["1": .failure, "2": .failure])
        do {
            _ = try await VacancyCollectionService(client: client).collect(
                employers: [.init(id: "1", name: "Первый", comment: "test"), .init(id: "2", name: "Второй", comment: "test")],
                areas: try AreaDirectoryIndex(root: Self.areaTree),
                progress: { _ in }
            )
            XCTFail("Expected the transport failure")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
    }

    func testCollectorStopsOnAccessRestriction() async throws {
        for error in [HHAPIError.forbidden(requestID: nil), .captchaRequired(requestID: nil), .rateLimited(retryAfterSeconds: 60)] {
            let client = EmployerScriptedClient(behaviors: ["1": .vacancies(3), "2": .restriction(error), "3": .vacancies(1)])
            let result = try await VacancyCollectionService(client: client).collect(
                employers: ["1", "2", "3"].map { .init(id: $0, name: "Работодатель \($0)", comment: "test") },
                areas: try AreaDirectoryIndex(root: Self.areaTree), progress: { _ in })
            XCTAssertEqual(Set(result.vacancies.map(\.id)), Set(["1-0", "1-1", "1-2"]))
            XCTAssertEqual(result.issues.map(\.employerID), ["2", "3"])
            XCTAssertTrue(result.issues.allSatisfy { $0.failures.first?.contains("Сбор остановлен ограничением hh.ru") == true })
            let requested = await client.requestedEmployerIDs
            XCTAssertEqual(requested, ["1", "2"])
        }
    }

    func testCollectorRetainsPagesOfEmployerInterruptedByRateLimit() async throws {
        let client = EmployerScriptedClient(behaviors: [
            "1": .vacancies(2), "2": .restrictionAfterFirstPage(150, .rateLimited(retryAfterSeconds: nil)), "3": .vacancies(1)
        ])
        let result = try await VacancyCollectionService(client: client).collect(
            employers: ["1", "2", "3"].map { .init(id: $0, name: $0, comment: "test") },
            areas: try AreaDirectoryIndex(root: Self.areaTree), progress: { _ in })
        XCTAssertEqual(result.vacancies.count, 102)
        XCTAssertEqual(result.issues.map(\.employerID), ["2", "3"])
        XCTAssertEqual(result.issues.first?.expected, 150)
        XCTAssertEqual(result.issues.first?.actual, 100)
        let requested = await client.requestedEmployerIDs
        XCTAssertEqual(requested, ["1", "2", "2"])
    }

    func testCollectorRestrictionWithoutVacanciesStillThrows() async throws {
        let error = HHAPIError.rateLimited(retryAfterSeconds: 60)
        let client = EmployerScriptedClient(behaviors: ["1": .restriction(error), "2": .vacancies(1)])
        do {
            _ = try await VacancyCollectionService(client: client).collect(
                employers: ["1", "2"].map { .init(id: $0, name: $0, comment: "test") },
                areas: try AreaDirectoryIndex(root: Self.areaTree), progress: { _ in })
            XCTFail("Expected rate limit without a partial result")
        } catch let actual as HHAPIError { XCTAssertEqual(actual, error) }
        let requested = await client.requestedEmployerIDs
        XCTAssertEqual(requested, ["1"])
    }

    func testCollectorKeepsEarlierIssuesWhenAccessIsRestricted() async throws {
        let client = EmployerScriptedClient(behaviors: ["1": .failure, "2": .vacancies(2), "3": .forbidden])
        let result = try await VacancyCollectionService(client: client).collect(
            employers: ["1", "2", "3"].map { .init(id: $0, name: $0, comment: "test") },
            areas: try AreaDirectoryIndex(root: Self.areaTree), progress: { _ in })
        XCTAssertEqual(result.vacancies.count, 2)
        XCTAssertEqual(result.issues.map(\.employerID), ["1", "3"])
        XCTAssertTrue(result.issues[0].failures.contains(URLError(.timedOut).localizedDescription))
    }

    func testCollectorAuthenticationAndCancellationStillAbortAfterSuccessfulEmployer() async throws {
        let errors: [HHAPIError] = [.unauthorized, .missingApplicationToken, .placeholderApplicationToken]
        for behavior in errors.map(EmployerScriptedClient.Behavior.restriction) + [.cancelled] {
            let client = EmployerScriptedClient(behaviors: ["1": .vacancies(2), "2": behavior, "3": .vacancies(1)])
            do {
                _ = try await VacancyCollectionService(client: client).collect(
                    employers: ["1", "2", "3"].map { .init(id: $0, name: $0, comment: "test") },
                    areas: try AreaDirectoryIndex(root: Self.areaTree), progress: { _ in })
                XCTFail("Authentication failures and cancellation must not return a partial result")
            } catch {
                switch behavior {
                case .restriction(let expected): XCTAssertEqual(error as? HHAPIError, expected)
                case .cancelled: XCTAssertTrue(error is CancellationError)
                default: XCTFail("Unexpected scenario")
                }
            }
            let requested = await client.requestedEmployerIDs
            XCTAssertEqual(requested, ["1", "2"])
        }
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

    func testCollectorSearchRequestCountForOneLeaf() async throws {
        let client = MockAPIClient(mode: .simple)
        let values = try await VacancyCollectionService(client: client).collect(
            employers: [.init(id: "47858", name: "Банк России", comment: "test")],
            areas: try AreaDirectoryIndex(root: Self.areaTree),
            progress: { _ in }
        )

        let requestCount = await client.searchRequestCount
        XCTAssertEqual(values.vacancies.count, 1)
        XCTAssertTrue(values.isComplete)
        XCTAssertEqual(requestCount, 2)
    }

    func testCollectorSearchRequestCountForPartitionedResult() async throws {
        let client = MockAPIClient(mode: .partitioned)
        let values = try await VacancyCollectionService(client: client).collect(
            employers: [.init(id: "47858", name: "Банк России", comment: "test")],
            areas: try AreaDirectoryIndex(root: .init(id: "113", name: "Россия", areas: [
                .init(id: "10", name: "Регион A"), .init(id: "20", name: "Регион B")
            ])),
            progress: { _ in }
        )

        let requestCount = await client.searchRequestCount
        XCTAssertEqual(values.vacancies.count, 2_001)
        XCTAssertTrue(values.isComplete)
        XCTAssertEqual(requestCount, 23)
    }

    func testAreaDirectoryUsesFreshThenExplicitStaleCacheAndRejectsCorruptionWithoutNetwork() async throws {
        let file = temporaryDirectory().appendingPathComponent("areas.json")
        let instant = Date(timeIntervalSince1970: 1_788_200_000)
        let freshStore = AreaDirectoryStore(fileURL: file, now: { instant })
        let fresh = try await freshStore.load(using: MockAPIClient(mode: .simple))
        XCTAssertNil(fresh.warning)

        let staleStore = AreaDirectoryStore(
            fileURL: file,
            now: { instant.addingTimeInterval(AreaDirectoryStore.defaultTTL + 1) }
        )
        let stale = try await staleStore.load(using: MockAPIClient(mode: .failure))
        XCTAssertTrue(stale.warning?.contains("устаревший кэш") == true)

        let corrupted = temporaryDirectory().appendingPathComponent("areas.json")
        try Data("not-json".utf8).write(to: corrupted)
        do {
            _ = try await AreaDirectoryStore(fileURL: corrupted).load(using: MockAPIClient(mode: .failure))
            XCTFail("Expected unavailable directory")
        } catch let error as AreaDirectoryError {
            XCTAssertEqual(error, .unavailable)
        }
    }

    func testSemanticallyInvalidFreshAreaCacheIsRefreshed() async throws {
        let file = temporaryDirectory().appendingPathComponent("areas.json")
        let invalid = #"{"version":1,"fetchedAt":"2026-09-02T00:00:00Z","root":{"id":"113","name":"Россия","areas":[{"id":"1","name":"Москва","areas":[]},{"id":"1","name":"Дубликат","areas":[]}]}}"#
        try Data(invalid.utf8).write(to: file)
        let store = AreaDirectoryStore(
            fileURL: file,
            now: { Date(timeIntervalSince1970: 1_788_321_600) }
        )

        let snapshot = try await store.load(using: MockAPIClient(mode: .simple))

        XCTAssertNil(snapshot.warning)
        XCTAssertEqual(snapshot.index.subjects.map(\.id), ["1", "2", "66"])
    }

    func testAreaDirectoryCancellationNeverBecomesStaleSuccessOrUnavailable() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let instant = Date(timeIntervalSince1970: 1_788_200_000)
        let file = directory.appendingPathComponent("areas.json")
        _ = try await AreaDirectoryStore(fileURL: file, now: { instant }).load(using: MockAPIClient(mode: .simple))
        let original = try Data(contentsOf: file)
        for cached in [true, false] {
            let target = cached ? file : directory.appendingPathComponent("missing.json")
            let store = AreaDirectoryStore(fileURL: target, now: { instant.addingTimeInterval(AreaDirectoryStore.defaultTTL + 1) })
            do {
                _ = try await store.load(using: CancelledAreaClient())
                XCTFail("Cancellation must not return a stale snapshot")
            } catch is CancellationError {
                // Cancellation is not a failed directory lookup.
            } catch {
                XCTFail("Cancellation was replaced with \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("missing.json").path))
    }

    func testAreaDirectoryTaskCancellationDoesNotPublishLateResponse() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("areas.json")
        let started = expectation(description: "Area request started")
        let responseGate = TestAsyncSignal()
        let client = CancelledAreaClient(responseGate: responseGate, onRequest: { started.fulfill() })
        let task = Task { try await AreaDirectoryStore(fileURL: file).load(using: client) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await responseGate.signal()
        do {
            _ = try await task.value
            XCTFail("A late successful response must not complete a cancelled load")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func testFreshAreaTreeRemainsAvailableWhenCacheWriteFails() async throws {
        let directory = temporaryDirectory()
        let blockedParent = directory.appendingPathComponent("not-a-directory")
        try Data("file blocks directory creation".utf8).write(to: blockedParent)
        let store = AreaDirectoryStore(
            fileURL: blockedParent.appendingPathComponent("areas.json")
        )

        let snapshot = try await store.load(using: MockAPIClient(mode: .simple))

        XCTAssertEqual(snapshot.index.subjects.map(\.id), ["1", "2", "66"])
        XCTAssertTrue(snapshot.warning?.contains("Не удалось сохранить кэш регионов") == true)
    }

    func testTypedAPIRequestUsesRequiredQueryAndHeaders() async throws {
        let client = makeHTTPClient { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(components.path, "/vacancies")
            XCTAssertEqual(query["employer_id"], "47858")
            XCTAssertEqual(query["area"], "113")
            XCTAssertEqual(query["per_page"], "100")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer unit-token")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
            XCTAssertNotNil(request.value(forHTTPHeaderField: "HH-User-Agent"))
            return (200, [:], Data(#"{"items":[],"found":0,"pages":0,"page":0,"per_page":100}"#.utf8))
        }
        let response = try await client.searchVacancies(.init(employerID: "47858"))
        XCTAssertEqual(response.found, 0)
    }

    func testLiveAPIUsesEmbeddedTokenAndRetrievesOneVacancyWithDetails() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["HHVACANCYCBR_RUN_LIVE_API_TEST"] == "1",
            "Opt-in live check; set HHVACANCYCBR_RUN_LIVE_API_TEST=1."
        )
        let maximumRequestCount = 2
        var requestCount = 0
        let client = HHAPIClient(
            accessTokenProvider: HHDefaultAccessTokenProvider(),
            requestGate: HHRequestGate(minimumDelayNanoseconds: 0),
            maximumRateLimitRetries: 0,
            maximumTransientRetries: 0
        )

        requestCount += 1
        let response = try await client.searchVacancies(.init(employerID: "47858", perPage: 1))
        XCTAssertGreaterThan(response.found, 0)
        XCTAssertLessThanOrEqual(response.items.count, 1)
        let vacancy = try XCTUnwrap(response.items.first)
        XCTAssertFalse(vacancy.id.isEmpty)
        XCTAssertFalse(vacancy.name.isEmpty)

        requestCount += 1
        let details = try await client.vacancyDetails(id: vacancy.id)
        XCTAssertEqual(details.id, vacancy.id)
        XCTAssertFalse(details.name.isEmpty)
        XCTAssertLessThanOrEqual(requestCount, maximumRequestCount)
    }

    @MainActor
    func testLiveCancellationWhenEmployerFilterHidesDetails() async throws {
        try await checkLiveDetailCancellation(transition: .employer)
    }

    @MainActor
    func testLiveCancellationWhenRegionFilterHidesDetails() async throws {
        try await checkLiveDetailCancellation(transition: .region)
    }



    func testAPIPreserves401RateLimitCaptchaAndNetworkErrors() async throws {
        var client = makeHTTPClient { _ in (401, [:], Data(#"{"errors":[]}"#.utf8)) }
        await assertAPIError(client, equals: .unauthorized)

        client = makeHTTPClient { _ in (429, ["Retry-After": "17"], Data(#"{"errors":[]}"#.utf8)) }
        await assertAPIError(client, equals: .rateLimited(retryAfterSeconds: 17))

        client = makeHTTPClient { _ in
            (403, [:], Data(#"{"request_id":"req-1","errors":[{"type":"captcha","value":"required"}]}"#.utf8))
        }
        await assertAPIError(client, equals: .captchaRequired(requestID: "req-1"))

        URLProtocolStub.handler = { _ in throw URLError(.notConnectedToInternet) }
        let networkClient = HTTPClientFactory.make()
        do {
            _ = try await networkClient.searchVacancies(.init(employerID: "47858"))
            XCTFail("Expected network error")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .notConnectedToInternet)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSuccessfulSearchSurvivesEvidenceWriteFailure() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidRoot = directory.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: invalidRoot)
        URLProtocolStub.handler = { _ in
            (200, [:], Data(#"{"items":[],"found":0,"pages":0,"page":0,"per_page":100}"#.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = HHAPIClient(session: URLSession(configuration: configuration),
                                 accessTokenProvider: FixedTokenProvider(),
                                 requestGate: HHRequestGate(minimumDelayNanoseconds: 0),
                                 evidence: PDFSourceEvidence(root: invalidRoot))
        let response = try await client.searchVacancies(.init(employerID: "47858"))
        XCTAssertEqual(response.found, 0)
    }

    func testRateLimitRetriesTwiceThenReturnsSuccessfulResponse() async throws {
        var requests = 0
        let client = makeHTTPClient { _ in
            requests += 1
            if requests < 3 { return (429, ["Retry-After": "0"], Data(#"{"errors":[]}"#.utf8)) }
            return (200, [:], Data(#"{"items":[],"found":0,"pages":0,"page":0,"per_page":100}"#.utf8))
        }
        do {
            let response = try await client.searchVacancies(.init(employerID: "47858"))
            XCTAssertEqual(response.found, 0)
        } catch {
            XCTFail("Expected successful response after bounded retries: \(error)")
        }
        XCTAssertEqual(requests, 3)
    }

    @MainActor
    func testBulkPDFCollisionCreatesSuffixAndPreservesExistingFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_788_400_000)
        let name = VacanciesPDFExporter.fileName(part: 1, totalParts: 1, exportStartedAt: date)
        let original = directory.appendingPathComponent(name)
        let originalData = Data("existing user file".utf8)
        try originalData.write(to: original)
        let exporter = VacanciesPDFExporter(chooseDirectory: { directory }, now: { date })
        let outcome = try await exporter.export(vacancies: [makePDFVacancy(id: "suffix")]) { _ in }
        guard case .exported(let count, let pages) = outcome else { return XCTFail("Expected exported PDF") }
        XCTAssertEqual(count, 1)
        XCTAssertGreaterThan(pages, 0)
        XCTAssertLessThanOrEqual(pages, 100)
        XCTAssertEqual(try Data(contentsOf: original), originalData)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pdf" && $0.lastPathComponent != name }
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(try XCTUnwrap(files.first).lastPathComponent.hasSuffix("_2.pdf"))
        XCTAssertNotNil(PDFDocument(url: try XCTUnwrap(files.first)))
        // No hidden staging, backup or recovery directories are left next to the PDFs.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    func testPDFWriterUsesFreeSuffixesForOccupiedAndDuplicateNamesWithinUTF8Limit() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("keep".utf8).write(to: directory.appendingPathComponent("report.pdf"))
        try Data("keep too".utf8).write(to: directory.appendingPathComponent("report_2.pdf"))
        let written = try PDFNewFileWriter.write(
            [Data("a".utf8), Data("b".utf8)], names: ["report.pdf", "report.pdf"], in: directory
        )
        XCTAssertEqual(written.map(\.lastPathComponent), ["report_3.pdf", "report_4.pdf"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("report.pdf")), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("report_2.pdf")), Data("keep too".utf8))
        XCTAssertEqual(try Data(contentsOf: written[1]), Data("b".utf8))

        let longName = PDFFileNameBuilder.fileName(base: String(repeating: "ёж🙂/", count: 300), fallback: "vacancy")
        let long = try PDFNewFileWriter.write([Data("1".utf8), Data("2".utf8)], names: [longName, longName], in: directory)
        let names = long.map(\.lastPathComponent)
        XCTAssertEqual(Set(names).count, 2)
        XCTAssertTrue(names.allSatisfy { $0.utf8.count <= 240 && !$0.contains("/") })
        XCTAssertTrue(names[1].hasSuffix("_2.pdf"))

        XCTAssertThrowsError(try PDFNewFileWriter.write(
            [Data()], names: ["report.pdf"], in: directory, maximumCandidates: 2
        )) { error in
            guard case VacanciesPDFExporter.ExportError.noAvailableFileName = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPDFWriterRemovesItsFilesOnFailureOrCancellationAndKeepsExistingOnes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("part-2.pdf")
        try Data("user file".utf8).write(to: existing)

        XCTAssertThrowsError(try PDFNewFileWriter.write(
            [Data("1".utf8), Data("2".utf8)], names: ["part-1.pdf", "part-2.pdf"], in: directory,
            beforeEachFile: { index in if index == 1 { throw CocoaError(.fileWriteUnknown) } }
        ))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["part-2.pdf"])

        let cancelled = Task {
            // Cancelled while the second file is written: the check before the third file stops the
            // batch and both files already written by this call are removed.
            try PDFNewFileWriter.write(
                [Data("1".utf8), Data("3".utf8), Data("4".utf8)], names: ["part-1.pdf", "part-3.pdf", "part-4.pdf"],
                in: directory,
                beforeEachFile: { index in if index == 1 { withUnsafeCurrentTask { $0?.cancel() } } }
            )
        }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["part-2.pdf"])
        XCTAssertEqual(try Data(contentsOf: existing), Data("user file".utf8))
    }

    func testPDFWriterCancellationDuringLastFileRollsBackEntireBatch() async throws {
        for count in [1, 3] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let existing = directory.appendingPathComponent("existing.pdf")
            try Data("keep".utf8).write(to: existing)
            let task = Task {
                try PDFNewFileWriter.write(
                    Array(repeating: Data("PDF".utf8), count: count),
                    names: (0..<count).map { "part-\($0).pdf" }, in: directory,
                    beforeEachFile: { index in
                        if index == count - 1 { withUnsafeCurrentTask { $0?.cancel() } }
                    }
                )
            }
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.pdf"])
            XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
        }
    }

    func testPDFWriterRollbackPreservesReplacementFileAndSymlink() throws {
        for useSymlink in [false, true] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let replacement = directory.appendingPathComponent("part-0.pdf")
            let userFile = directory.appendingPathComponent("user.pdf")
            let userData = Data("user document".utf8)
            try userData.write(to: userFile)
            XCTAssertThrowsError(try PDFNewFileWriter.write(
                Array(repeating: Data("PDF".utf8), count: 3),
                names: ["part-0.pdf", "part-1.pdf", "part-2.pdf"], in: directory,
                beforeEachFile: { index in
                    guard index == 2 else { return }
                    try FileManager.default.removeItem(at: replacement)
                    if useSymlink {
                        try FileManager.default.createSymbolicLink(at: replacement, withDestinationURL: userFile)
                    } else {
                        try userData.write(to: replacement)
                    }
                    throw CocoaError(.fileWriteUnknown)
                }
            ))
            XCTAssertEqual(try Data(contentsOf: replacement), userData)
            XCTAssertEqual(try Data(contentsOf: userFile), userData)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("part-1.pdf").path))
            if useSymlink {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: replacement.path), userFile.path)
            }
        }
    }

    func testPathologicalRecursiveCollectionStopsAtBudget() async throws {
        var requests = 0
        let client = makeHTTPClient { _ in
            requests += 1
            return (200, [:], Data(#"{"items":[],"found":3000,"pages":20,"page":0,"per_page":100}"#.utf8))
        }
        let result = try await VacancyCollectionService(client: client, maximumRequests: 12).collect(
            employers: [.init(id: "1", name: "One", comment: "test")],
            areas: try AreaDirectoryIndex(root: Self.areaTree), progress: { _ in })
        XCTAssertEqual(requests, 12)
        XCTAssertFalse(result.isComplete)
        XCTAssertTrue(result.issues.first?.message.contains("защитный предел") == true)
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



    func testMixedHTTPFailuresShareThreeAttemptBudget() async {
        var requests = 0
        let client = makeHTTPClient { _ in
            requests += 1
            if requests == 1 { throw URLError(.timedOut) }
            return (requests == 2 ? 429 : 503, [:], Data(#"{"errors":[]}"#.utf8))
        }
        _ = try? await client.searchVacancies(.init(employerID: "1"))
        XCTAssertEqual(requests, 3)
    }

    func testCooldownSurvivesExhaustedRetryBudgetAcrossClientsAndEndpoints() async throws {
        let clock = AuditClock()
        let gate = HHRequestGate(minimumDelayNanoseconds: 0, monotonicNow: { clock.now },
                                 sleep: { clock.advance(Double($0) / 1e9) })
        var times: [Double] = []
        URLProtocolStub.handler = { request in
            times.append(clock.now)
            if times.count == 1 { return (429, ["Retry-After": "17"], Data()) }
            return (200, [:], Data(#"{"experience":[],"work_format":[],"schedule":[]}"#.utf8))
        }
        let first = HTTPClientFactory.make(maximumRateLimitRetries: 0, requestGate: gate)
        let second = HTTPClientFactory.make(requestGate: gate)
        _ = try? await first.searchVacancies(.init(employerID: "1"))
        _ = try await second.vacancyDictionaries()
        XCTAssertEqual(times, [0, 17])
    }

    func testLongCooldownRejectsNewOperationsWithoutShorteningServerDelay() async throws {
        for header in ["120", "9999999999999999999999999999999999999999"] {
            let clock = AuditClock()
            let gate = HHRequestGate(minimumDelayNanoseconds: 0, monotonicNow: { clock.now },
                                     sleep: { clock.advance(Double($0) / 1e9) })
            var requests = 0
            URLProtocolStub.handler = { _ in requests += 1; return (429, ["Retry-After": header], Data()) }
            let client = HTTPClientFactory.make(requestGate: gate)
            _ = try? await client.searchVacancies(.init(employerID: "1"))
            for _ in 0..<50 { _ = try? await client.vacancyDetails(id: "x") }
            XCTAssertEqual(requests, 1)
            clock.advance(119)
            if header == "120" {
                URLProtocolStub.handler = { _ in
                    requests += 1
                    XCTAssertGreaterThanOrEqual(clock.now, 120)
                    return (200, [:], Data(#"{"items":[],"found":0,"pages":0,"page":0,"per_page":100}"#.utf8))
                }
                _ = try await client.searchVacancies(.init(employerID: "1"))
                XCTAssertEqual(requests, 2)
            }
        }
    }

    func testLargeHTTPQueueHasOneSecondSpacingAndNoBurstAfterCooldown() async throws {
        let clock = AuditClock()
        let gate = HHRequestGate(monotonicNow: { clock.now }, sleep: { clock.advance(Double($0) / 1e9) })
        await gate.imposeCooldown(seconds: 17)
        var starts: [Double] = []
        URLProtocolStub.handler = { _ in
            starts.append(clock.now)
            return (200, [:], Data(#"{"items":[],"found":0,"pages":0,"page":0,"per_page":100}"#.utf8))
        }
        let client = HTTPClientFactory.make(requestGate: gate)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in 0..<100 { group.addTask { _ = try await client.searchVacancies(.init(employerID: String(id))) } }
            try await group.waitForAll()
        }
        XCTAssertEqual(starts.count, 100)
        XCTAssertEqual(starts.first, 17)
        XCTAssertTrue(zip(starts, starts.dropFirst()).allSatisfy { $1 - $0 >= 1 })
        let remaining = await gate.queuedRequestCount
        XCTAssertEqual(remaining, 0)
    }

    func testCooldownWaitCancellationRetainsEmbargoAndReleasesGate() async throws {
        let clock = AuditClock()
        let entered = expectation(description: "cooldown wait")
        let gate = HHRequestGate(minimumDelayNanoseconds: 0, monotonicNow: { clock.now }, sleep: { _ in
            entered.fulfill()
            try await Task.sleep(nanoseconds: 60_000_000_000)
        })
        await gate.imposeCooldown(seconds: 17)
        let task = Task { try await gate.perform { XCTFail("embargo bypassed"); return 1 } }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {} catch { XCTFail("\(error)") }
        clock.advance(17)
        let next = try await gate.perform { 2 }
        XCTAssertEqual(next, 2)
    }

    func testOfflineStopsImmediatelyAndNextRequestCanRecover() async throws {
        var requests = 0
        URLProtocolStub.handler = { _ in
            requests += 1
            if requests == 1 { throw URLError(.notConnectedToInternet) }
            return (200, [:], Data(#"{"items":[],"found":0,"pages":0,"page":0,"per_page":100}"#.utf8))
        }
        let client = HTTPClientFactory.make()
        _ = try? await client.searchVacancies(.init(employerID: "1"))
        XCTAssertEqual(requests, 1)
        _ = try await client.searchVacancies(.init(employerID: "1"))
        XCTAssertEqual(requests, 2)
    }

    func testCollectorBudgetRetainsPagesAndMarksUnvisitedEmployersIncomplete() async throws {
        let client = EmployerScriptedClient(behaviors: ["1": .vacancies(350), "2": .vacancies(1)])
        let result = try await VacancyCollectionService(client: client, maximumRequests: 2).collect(
            employers: ["1", "2"].map { .init(id: $0, name: $0, comment: "test") },
            areas: try AreaDirectoryIndex(root: Self.areaTree), progress: { _ in })
        XCTAssertEqual(result.vacancies.count, 200)
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.issues.map(\.employerID), ["1", "2"])
        let requests = await client.requestedEmployerIDs.count
        XCTAssertEqual(requests, 2)
    }

    func testCollectorDurationBudgetUsesMonotonicClock() async throws {
        let client = EmployerScriptedClient(behaviors: ["1": .vacancies(350)])
        let clock = AuditClock()
        let result = try await VacancyCollectionService(client: client, maximumDuration: 10, uptime: { clock.now }).collect(
            employers: [.init(id: "1", name: "One", comment: "test")],
            areas: try AreaDirectoryIndex(root: Self.areaTree), progress: { progress in
                // Advance after data arrives, not on the new pre-request employer notification.
                if progress.loadedCount > 0 { clock.advance(10) }
            })
        XCTAssertEqual(result.vacancies.count, 100)
        XCTAssertFalse(result.isComplete)
        let requests = await client.requestedEmployerIDs.count
        XCTAssertEqual(requests, 1)
    }

    func testAreaAccessRestrictionCannotFallBackAndContinueCollection() async throws {
        let file = temporaryDirectory().appendingPathComponent("areas.json")
        let date = Date(timeIntervalSince1970: 1_788_200_000)
        _ = try await AreaDirectoryStore(fileURL: file, now: { date }).load(using: MockAPIClient(mode: .simple))
        for cached in [true, false] {
            let client = makeHTTPClient { _ in (403, [:], Data()) }
            let store = AreaDirectoryStore(fileURL: cached ? file : file.appendingPathExtension("missing"),
                                           now: { date.addingTimeInterval(AreaDirectoryStore.defaultTTL + 1) })
            do { _ = try await store.load(using: client); XCTFail("expected forbidden") }
            catch let error as HHAPIError { XCTAssertEqual(error, .forbidden(requestID: nil)) }
        }
    }





    func testRateLimitWaitPreventsQueuedRequestsFromOvertakingRetry() async throws {
        let entered = expectation(description: "Retry owns gate")
        let release = TestAsyncSignal()
        let gate = HHRequestGate(minimumDelayNanoseconds: 0)
        var employers: [String] = []
        URLProtocolStub.handler = { request in
            let id = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                .first { $0.name == "employer_id" }!.value!
            employers.append(id)
            if employers.count == 1 { return (429, [:], Data(#"{"errors":[]}"#.utf8)) }
            return (200, [:], Data(#"{"items":[],"found":0,"pages":0,"page":0,"per_page":100}"#.utf8))
        }
        let client = HTTPClientFactory.make(requestGate: gate, retrySleep: { _ in
            entered.fulfill()
            await release.wait()
        })
        let first = Task { try await client.searchVacancies(.init(employerID: "47858")) }
        await fulfillment(of: [entered], timeout: 2)
        let second = Task { try await client.searchVacancies(.init(employerID: "1654251")) }
        for _ in 0..<200 {
            if await gate.queuedRequestCount == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let queued = await gate.queuedRequestCount
        XCTAssertEqual(queued, 1)
        XCTAssertEqual(employers, ["47858"])
        await release.signal()
        _ = try await first.value
        _ = try await second.value
        XCTAssertEqual(employers, ["47858", "47858", "1654251"])
    }

    func testRateLimitRetryStopsOnForbiddenCaptchaAndConfiguredCeiling() async {
        for (limit, terminal, captcha, expected) in [(99, 429, false, 3), (-1, 429, false, 1), (2, 403, false, 2), (2, 429, true, 1)] {
            var requests = 0
            URLProtocolStub.handler = { _ in
                requests += 1
                let body = captcha ? #"{"errors":[{"type":"captcha","value":"required"}]}"# : #"{"errors":[]}"#
                return (requests == 1 ? 429 : terminal, [:], Data(body.utf8))
            }
            let client = HTTPClientFactory.make(maximumRateLimitRetries: limit)
            do { _ = try await client.searchVacancies(.init(employerID: "47858")); XCTFail("Expected terminal failure") }
            catch { XCTAssertEqual(requests, expected) }
        }
    }

    func testRateLimitRetryBudgetAndServerDelayCeiling() async {
        for (header, expectedRequests) in [("0", 3), ("60", 3), ("61", 1), ("9999999999999999999999999999999999999999", 1)] {
            var requests = 0
            let client = makeHTTPClient { _ in
                requests += 1
                return (429, ["Retry-After": header], Data(#"{"errors":[]}"#.utf8))
            }
            do { _ = try await client.searchVacancies(.init(employerID: "47858")); XCTFail("Expected rate limit") }
            catch let error as HHAPIError {
                guard case .rateLimited = error else { return XCTFail("Expected rate limit") }
            } catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(requests, expectedRequests)
        }
    }

    func testRateLimitDelaySupportsHTTPDateAndNeverRetriesBeforeServerDelay() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(HHAPIClient.rateLimitDelay(header: nil, now: now, attempt: 0), 1)
        XCTAssertEqual(HHAPIClient.rateLimitDelay(header: "invalid", now: now, attempt: 1), 2)
        XCTAssertEqual(HHAPIClient.rateLimitDelay(header: "-1", now: now, attempt: 0), 1)
        XCTAssertEqual(HHAPIClient.rateLimitDelay(header: " 17 ", now: now, attempt: 0), 17)
        XCTAssertEqual(HHAPIClient.rateLimitDelay(header: "Thu, 01 Jan 1970 00:00:17 GMT", now: now, attempt: 0), 17)
        XCTAssertEqual(HHAPIClient.rateLimitDelay(header: "Wed, 31 Dec 1969 23:59:59 GMT", now: now, attempt: 1), 2)
        XCTAssertNil(HHAPIClient.rateLimitDelay(header: "Thu, 01 Jan 1970 00:01:01 GMT", now: now, attempt: 0))
    }

    func testRateLimitRetryUsesExpectedBackoffAndCanBeDisabledForLiveBudget() async throws {
        let waits = RetryWaitRecorder()
        var requests = 0
        URLProtocolStub.handler = { _ in
            requests += 1
            if requests <= 2 { return (429, [:], Data(#"{"errors":[]}"#.utf8)) }
            return (200, [:], Data(#"{"items":[],"found":0,"pages":0,"page":0,"per_page":100}"#.utf8))
        }
        let client = HTTPClientFactory.make(maximumRateLimitRetries: 99, retrySleep: { await waits.append($0) })
        _ = try await client.searchVacancies(.init(employerID: "47858"))
        let delays = await waits.values
        XCTAssertEqual(delays, [1_000_000_000, 2_000_000_000])
        XCTAssertEqual(requests, 3)
        requests = 0
        let noRetries = HTTPClientFactory.make(maximumRateLimitRetries: 0)
        do { _ = try await noRetries.searchVacancies(.init(employerID: "47858")); XCTFail("Expected rate limit") }
        catch { XCTAssertEqual(requests, 1) }
    }

    func testRateLimitWaitCancellationStopsRetriesAndReleasesSharedGate() async throws {
        let waiting = expectation(description: "Entered retry delay")
        var requests = 0
        URLProtocolStub.handler = { _ in
            requests += 1
            if requests == 1 { return (429, [:], Data(#"{"errors":[]}"#.utf8)) }
            return (200, [:], Data(#"{"items":[],"found":0,"pages":0,"page":0,"per_page":100}"#.utf8))
        }
        let client = HTTPClientFactory.make(retrySleep: { _ in
            waiting.fulfill()
            try await Task.sleep(nanoseconds: 60_000_000_000)
        })
        let task = Task { try await client.searchVacancies(.init(employerID: "47858")) }
        await fulfillment(of: [waiting], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(requests, 1)
        _ = try await client.searchVacancies(.init(employerID: "47858"))
        XCTAssertEqual(requests, 2)
    }

    func testAPIDoesNotRetryClientHTTPFailures() async {
        let failures: [(Int, HHAPIError)] = [
            (400, .requestFailed(statusCode: 400, message: nil)),
            (404, .requestFailed(statusCode: 404, message: nil)),
            (403, .forbidden(requestID: nil))
        ]
        for (status, expected) in failures {
            var requests = 0
            let client = makeHTTPClient { _ in
                requests += 1
                return (status, ["Retry-After": "17"], Data(#"{"errors":[]}"#.utf8))
            }
            await assertAPIError(client, equals: expected)
            XCTAssertEqual(requests, 1, "HTTP \(status) must finish without automatic retries")
        }
        var requests = 0
        let offline = makeHTTPClient { _ in
            requests += 1
            throw URLError(.notConnectedToInternet)
        }
        _ = try? await offline.searchVacancies(.init(employerID: "47858"))
        XCTAssertEqual(requests, 1, "Offline is not a transient failure")
    }

    func testAPIRetriesTransientFailuresTwiceThenReportsThem() async {
        for status in [500, 502, 503, 504] {
            var requests = 0
            let client = makeHTTPClient { _ in
                requests += 1
                return (status, [:], Data(#"{"errors":[]}"#.utf8))
            }
            await assertAPIError(client, equals: .requestFailed(statusCode: status, message: nil))
            XCTAssertEqual(requests, 3, "HTTP \(status) gets two bounded retries")
        }
        for code in [URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost] {
            var requests = 0
            let client = makeHTTPClient { _ in
                requests += 1
                throw URLError(code)
            }
            do {
                _ = try await client.searchVacancies(.init(employerID: "47858"))
                XCTFail("Expected transport failure")
            } catch let error as URLError {
                XCTAssertEqual(error.code, code)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(requests, 3, "\(code) gets two bounded retries")
        }
    }

    func testAPITransientRetriesUseBackoffAndRecover() async throws {
        let waits = RetryWaitRecorder()
        var requests = 0
        URLProtocolStub.handler = { _ in
            requests += 1
            if requests == 1 { throw URLError(.timedOut) }
            if requests == 2 { return (502, [:], Data(#"{"errors":[]}"#.utf8)) }
            return (200, [:], Data(#"{"items":[],"found":0,"pages":0,"page":0,"per_page":100}"#.utf8))
        }
        let client = HTTPClientFactory.make(retrySleep: { await waits.append($0) })
        let response = try await client.searchVacancies(.init(employerID: "47858"))
        let delays = await waits.values
        XCTAssertEqual(response.found, 0)
        XCTAssertEqual(requests, 3)
        XCTAssertEqual(delays, [1_000_000_000, 2_000_000_000])
    }

    func testAPIServerRetryHonorsRetryAfterCeilingAndCanBeDisabled() async {
        var requests = 0
        var client = makeHTTPClient { _ in
            requests += 1
            return (503, ["Retry-After": "120"], Data(#"{"errors":[]}"#.utf8))
        }
        await assertAPIError(client, equals: .requestFailed(statusCode: 503, message: nil))
        XCTAssertEqual(requests, 1, "A server delay above 60 seconds is not waited out")

        requests = 0
        URLProtocolStub.handler = { _ in
            requests += 1
            return (502, [:], Data(#"{"errors":[]}"#.utf8))
        }
        client = HTTPClientFactory.make(maximumTransientRetries: 0)
        await assertAPIError(client, equals: .requestFailed(statusCode: 502, message: nil))
        XCTAssertEqual(requests, 1)
    }

    func testRequestGateCancelsQueuedWaiterBeforeActiveRequestFinishes() async throws {
        let gate = HHRequestGate(minimumDelayNanoseconds: 0)
        let activeStarted = expectation(description: "active started")
        let blocker = TestAsyncSignal()
        let active = Task {
            try await gate.perform {
                activeStarted.fulfill()
                await blocker.wait()
                return 1
            }
        }
        await fulfillment(of: [activeStarted], timeout: 2)
        let cancelled = expectation(description: "queued task cancelled without releasing active")
        let queued = Task {
            do {
                _ = try await gate.perform { XCTFail("Cancelled request executed"); return 2 }
                XCTFail("Expected cancellation")
            } catch is CancellationError { cancelled.fulfill() }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        for _ in 0..<1000 {
            if await gate.queuedRequestCount == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        let before = await gate.queuedRequestCount
        XCTAssertEqual(before, 1)
        queued.cancel()
        await fulfillment(of: [cancelled], timeout: 1)
        let after = await gate.queuedRequestCount
        XCTAssertEqual(after, 0)
        await blocker.signal()
        _ = try await active.value
        await queued.value
        let next = try await gate.perform { 3 }
        XCTAssertEqual(next, 3)
    }

    func testRequestGateCancellationRaceReleasesEveryWaiterAndPreservesSerialization() async throws {
        let gate = HHRequestGate(minimumDelayNanoseconds: 0)
        let tracker = ConcurrentOperationTracker()
        for _ in 0..<10 {
            let tasks = (0..<20).map { index in
                Task {
                    try await gate.perform {
                        await tracker.begin()
                        await Task.yield()
                        await tracker.end()
                        return index
                    }
                }
            }
            for (index, task) in tasks.enumerated() where index.isMultiple(of: 2) { task.cancel() }
            for task in tasks { _ = await task.result }
        }
        let queued = await gate.queuedRequestCount
        let peak = await tracker.maximumConcurrentOperations
        XCTAssertEqual(queued, 0)
        XCTAssertEqual(peak, 1)
        let next = try await gate.perform { true }
        XCTAssertTrue(next)
    }

    func testRequestGateCancellationDuringPacingDoesNotRunOperation() async throws {
        let gate = HHRequestGate(minimumDelayNanoseconds: 500_000_000)
        _ = try await gate.perform { 1 }
        let task = Task { try await gate.perform { XCTFail("Must cancel during pacing"); return 2 } }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let next = try await gate.perform { 3 }
        XCTAssertEqual(next, 3)
    }

    func testRequestGateSerializesConcurrentOperations() async throws {
        let gate = HHRequestGate(minimumDelayNanoseconds: 0)
        let tracker = ConcurrentOperationTracker()

        async let first: Int = gate.perform {
            await tracker.begin()
            try await Task.sleep(nanoseconds: 100_000_000)
            await tracker.end()
            return 1
        }
        async let second: Int = gate.perform {
            await tracker.begin()
            try await Task.sleep(nanoseconds: 100_000_000)
            await tracker.end()
            return 2
        }

        _ = try await (first, second)
        let maximumConcurrentOperations = await tracker.maximumConcurrentOperations
        XCTAssertEqual(maximumConcurrentOperations, 1)
    }

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
    func testBulkPDFExportProducesBoundedValidPartsAndMainActorProgress() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixedDate = Date(timeIntervalSince1970: 1_788_400_000)
        let vacancies = (0..<101).map { makePDFVacancy(id: String($0)) }
        var progressValues: [BulkPDFExportProgress] = []
        var progressWasOnMainThread = true
        let exporter = VacanciesPDFExporter(
            chooseDirectory: { directory },
            now: { fixedDate }
        )

        let outcome = try await exporter.export(vacancies: vacancies) { progress in
            progressWasOnMainThread = progressWasOnMainThread && Thread.isMainThread
            progressValues.append(progress)
        }

        if case .exported(let files, let pages) = outcome { XCTAssertGreaterThanOrEqual(files, 2); XCTAssertGreaterThanOrEqual(pages, files); XCTAssertLessThanOrEqual(pages, files * 100) } else { XCTFail("Expected files") }
        XCTAssertEqual(progressValues.first, .init(completedVacancies: 1, totalVacancies: 101))
        XCTAssertEqual(progressValues.last?.completedVacancies, 101)
        XCTAssertEqual(progressValues.last?.stage, "Сохранение файлов")
        XCTAssertTrue(progressValues.allSatisfy { $0.totalVacancies == 101 })
        XCTAssertTrue(zip(progressValues, progressValues.dropFirst()).allSatisfy {
            $0.completedVacancies <= $1.completedVacancies
        })
        XCTAssertGreaterThanOrEqual(progressValues.filter { $0.completedVacancies == 101 }.count, 1)
        XCTAssertTrue(progressWasOnMainThread)

        let pdfs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "pdf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(pdfs.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, pdfs.count, "Only the PDFs are written")
        for url in pdfs {
            let count = try XCTUnwrap(PDFDocument(url: url)).pageCount
            XCTAssertLessThanOrEqual(count, 100)
            try VacanciesPDFExporter.validatePDF(at: url, expectedPages: count)
        }
        let documents = try pdfs.map { try XCTUnwrap(PDFDocument(url: $0)) }
        let text = try documents.map(extractedStatisticsText).joined(separator: "\n")
        var previous = text.startIndex
        for vacancy in vacancies {
            let titleLine = vacancy.name + "\n"
            XCTAssertEqual(text.components(separatedBy: titleLine).count - 1, 1)
            let range = try XCTUnwrap(text.range(of: titleLine))
            XCTAssertGreaterThanOrEqual(range.lowerBound, previous)
            previous = range.upperBound
        }
        for document in documents {
            XCTAssertNotNil(document.documentAttributes?[PDFDocumentAttribute.creationDateAttribute] as? Date)
            XCTAssertNotNil(document.documentAttributes?[PDFDocumentAttribute.producerAttribute] as? String)
        }
    }

    @MainActor
    func testCancelledBulkPDFSelectionReleasesPreparationAndAllowsNextExport() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var selectedDirectory: URL?
        let exporter = VacanciesPDFExporter(
            chooseDirectory: { selectedDirectory },
            now: { Date(timeIntervalSince1970: 1_788_400_000) }
        )
        let vacancy = makePDFVacancy(id: "cancel-retry")

        let cancelled = try await exporter.export(vacancies: [vacancy]) { _ in }
        XCTAssertEqual(cancelled, .cancelled)

        selectedDirectory = directory
        let completed = try await exporter.export(vacancies: [vacancy]) { _ in }
        guard case .exported(let count, let pages) = completed else { return XCTFail("Expected exported PDF after cancellation") }
        XCTAssertEqual(count, 1)
        XCTAssertGreaterThan(pages, 0)
        XCTAssertLessThanOrEqual(pages, 100)
    }

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

    func testPDFListContinuationRetainsIndentAndLinkAcrossPages() throws {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 4
        style.headIndent = 18
        let url = URL(string: "https://example.com/list")!
        let source = (0..<120).map { String(format: "line%03d", $0) }.joined(separator: "\u{2028}")
        let text = NSAttributedString(string: source, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .paragraphStyle: style, .link: url
        ])
        let pages = VacanciesPDFExporter.pages(for: text)
        XCTAssertGreaterThan(pages.count, 1)
        let pdf = try XCTUnwrap(PDFDocument(data: VacanciesPDFExporter.pdfData(for: pages)))
        for index in 1..<pages.count {
            let firstLine = try XCTUnwrap(pages[index].content.string.components(separatedBy: "\u{2028}").first)
            let page = try XCTUnwrap(pdf.page(at: index))
            let pageString = try XCTUnwrap(page.string) as NSString
            let range = pageString.range(of: firstLine)
            XCTAssertNotEqual(range.location, NSNotFound)
            let selection = try XCTUnwrap(page.selection(for: range))
            XCTAssertEqual(selection.bounds(for: page).minX, VacancyPDFDefaults.horizontalMargin + 18, accuracy: 2)
            XCTAssertTrue(page.annotations.contains { $0.url == url })
        }
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
    func testPersonalPDFWorkerCreatesAtomicValidDocument() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("personal.pdf")
        let worker = PDFExportWorker()

        try await worker.exportPersonal(
            vacancy: PDFVacancySnapshot(value: makePDFVacancy(id: "personal")),
            destination: destination
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        try VacanciesPDFExporter.validatePDF(at: destination, expectedPages: 2)
        let text = try XCTUnwrap(PDFDocument(url: destination)?.string)
        XCTAssertFalse(text.contains("Идентификатор документа"))
    }

    func testPersonalPDFCancellationOnLastPageNeverPublishesAndAllowsRetry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vacancy = makePDFVacancy(id: "last-page-cancel")
        let worker = PDFExportWorker()
        let originalURL = directory.appendingPathComponent("original.pdf")
        try await worker.exportPersonal(vacancy: .init(value: makePDFVacancy(id: "original")), destination: originalURL)
        let original = try Data(contentsOf: originalURL)
        for existing in [false, true] {
            let destination = directory.appendingPathComponent(existing ? "existing.pdf" : "new.pdf")
            if existing { try original.write(to: destination, options: .atomic) }
            let task = Task {
                try await worker.exportPersonal(vacancy: .init(value: vacancy), destination: destination) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            do {
                try await task.value
                XCTFail("Cancellation on the final page must prevent publication")
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            if existing {
                XCTAssertEqual(try Data(contentsOf: destination), original)
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            }
            try await worker.exportPersonal(vacancy: .init(value: vacancy), destination: destination)
            let pdf = try XCTUnwrap(PDFDocument(url: existing ? directory.appendingPathComponent("existing_2.pdf") : destination))
            XCTAssertEqual(pdf.pageCount, 2)
            XCTAssertTrue(pdf.string?.contains("last-page-cancel") == true)
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       Set(["original.pdf", "existing.pdf", "existing_2.pdf", "new.pdf"]))
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

    private var statisticsFilterRows: [(id: String, employer: String, region: String)] {
        [("filter-moscow", "47858", "subject:1"), ("filter-ekb", "47858", "subject:66"),
         ("filter-unknown", "47858", "unknown"), ("filter-remote", "1654251", "remote"),
         ("filter-spb", "9999", "subject:2")]
    }

    @MainActor
    private final class StatisticsDestinationSpy {
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
    private func makeStatisticsExportModel(directory: URL, mode: MockAPIClient.Mode = .filters)
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


    private func extractedStatisticsText(_ pdf: PDFDocument) throws -> String {
        // macOS 13 Quartz/PDFKit can expose the shared SF glyph for Cyrillic к as kra.
        // Exact original Unicode is checked separately on the attributed page sequence.
        try XCTUnwrap(pdf.string).replacingOccurrences(of: "\u{0138}", with: "к")
            .precomposedStringWithCanonicalMapping
    }

    private func statisticsFixture(_ vacancies: [VacancySearchResult]) -> VacancyStatisticsReport {
        VacancyStatisticsReport(
            entries: vacancies.map(VacancyStatisticsReport.Entry.init), modeName: "Все вакансии",
            employerID: "47858", employerName: "Банк России", regionID: "subject:1", regionName: "Москва",
            createdAt: Date(timeIntervalSince1970: 1_788_400_000), timeZoneIdentifier: "UTC", sourceNote: "Локальная выборка."
        )
    }

    private func statisticsVacancy(id: String, date: String?, salary: Bool = false, archived: Bool = false) -> VacancySearchResult {
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
    func testTrudSearchFindsDescriptionAndKeepsNewestFirst() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrudvsemSnapshotStore(configuredURL: directory.appendingPathComponent("trud.json"))
        var old = TrudFixture.row("old"), newest = TrudFixture.row("new")
        var oldData = try XCTUnwrap(old["vacancy"] as? [String: Any])
        var newData = try XCTUnwrap(newest["vacancy"] as? [String: Any])
        oldData["creation-date"] = "2026-09-01"
        newData["creation-date"] = "2026-10-01"
        oldData["duty"] = "Подготовка отчётов"
        newData["duty"] = "Подготовка отчётов"
        old["vacancy"] = oldData; newest["vacancy"] = newData
        let values = try TrudFixture.page([old, newest]).vacancies.map {
            TrudvsemVacancy(dto: $0, organization: TrudFixture.bank, observationIDs: [])
        }
        try store.save(.init(version: 1, vacancies: values, metrics: [], updatedAt: Date()))
        let model = TrudvsemViewModel(client: TrudScriptedClient([]), store: store)
        model.load()
        model.searchDraft = "отчётов"
        XCTAssertEqual(model.displayedResults.count, 2)
        model.applySearch()
        XCTAssertEqual(model.displayedResults.map(\.dto.id), ["new", "old"])
        model.clearSearch()
        XCTAssertEqual(model.displayedResults.map(\.dto.id), ["new", "old"])
    }

    func testPublicationDateParserPreservesOffsetsFractionsAndMissingValues() throws {
        let parser = HHPublicationDateParser()
        let whole = try XCTUnwrap(parser.date(from: "2026-09-01T10:00:00Z"))
        for date in ["2026-09-01T13:00:00+0300", "2026-09-01T13:00:00+03:00", "2026-09-01T10:00:00.000Z"] {
            XCTAssertEqual(parser.date(from: date), whole)
        }
        let fraction = try XCTUnwrap(parser.date(from: "2026-09-01T10:00:00.125Z"))
        XCTAssertEqual(fraction.timeIntervalSince(whole), 0.125, accuracy: 0.0001)
        for date: String? in [nil, "", "not-a-date"] { XCTAssertNil(parser.date(from: date)) }
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
    func testLargePDFPreparationAllowsFilterChangesAndInteractiveHHDetails() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, client, _) = makeStatisticsExportModel(directory: directory)
        await model.search()
        let initialSearchRequests = await client.searchRequestCount
        let worker = PDFExportWorker()
        let snapshot = PDFVacanciesSnapshot(values: (0..<100).map { makePDFVacancy(id: "joint-\($0)") })
        var completed = 0
        let preparation = Task {
            try await worker.prepare(vacancies: snapshot) { completed = $0.completedVacancies }
        }
        var interactionsDuringPDF = 0
        for index in 0..<20 {
            if completed < 100 { interactionsDuringPDF += 1 }
            model.selectedEmployerID = index.isMultiple(of: 2) ? "bank_of_russia" : "all"
            model.selectedRegionID = index.isMultiple(of: 2) ? "subject:1" : "all"
            XCTAssertEqual(model.displayedResults.count, index.isMultiple(of: 2) ? 1 : 5)
            await model.loadVacancyDetails(id: index.isMultiple(of: 2) ? "filter-moscow" : "filter-ekb")
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let prepared = try await preparation.value
        XCTAssertGreaterThan(interactionsDuringPDF, 1)
        XCTAssertGreaterThanOrEqual(prepared.pageCount, prepared.partCount)
        XCTAssertLessThanOrEqual(prepared.pageCount, prepared.partCount * 100)
        XCTAssertEqual(completed, 100)
        let details = await client.requestedDetailIDs
        let searches = await client.searchRequestCount
        XCTAssertEqual(details, ["filter-moscow", "filter-ekb"])
        XCTAssertEqual(searches, initialSearchRequests)
        await worker.discardPreparedExport()
        await model.refreshVacancies()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.displayedResults.count, 5)
    }

    @MainActor
    func testRepeatedBulkPDFEnrichmentReusesSessionDetailsWithoutChangingSnapshot() async {
        let client = PDFEnrichmentClient()
        let exporter = PDFEnrichmentExporter()
        let model = await enrichmentModel(client: client, exporter: exporter)
        await model.exportVacanciesPDF()
        let firstCount = await client.requests
        XCTAssertEqual(firstCount, 3)
        await client.setError(HHAPIError.rateLimited(retryAfterSeconds: 60))
        await model.exportVacanciesPDF()
        let repeatedCount = await client.requests
        XCTAssertEqual(repeatedCount, firstCount)
        XCTAssertEqual(exporter.snapshots.count, 2)
        XCTAssertEqual(exporter.snapshots[0].map(\.id), exporter.snapshots[1].map(\.id))
        XCTAssertEqual(exporter.snapshots[0].map(\.details), exporter.snapshots[1].map(\.details))
        XCTAssertTrue(exporter.snapshots[1].allSatisfy { $0.isDetailLoaded && $0.exportDataNotice == nil })
    }

    @MainActor
    func testFailedBulkPDFEnrichmentIsNotCachedAndCanRecover() async {
        let client = PDFEnrichmentClient(error: URLError(.timedOut))
        let exporter = PDFEnrichmentExporter()
        let model = await enrichmentModel(client: client, exporter: exporter)
        await model.exportVacanciesPDF()
        await client.setError(nil)
        await model.exportVacanciesPDF()
        let count = await client.requests
        XCTAssertEqual(count, 4)
        XCTAssertEqual(exporter.snapshots.count, 1)
        XCTAssertTrue(exporter.snapshots[0].allSatisfy { $0.isDetailLoaded && $0.exportDataNotice == nil })
    }

    @MainActor
    func testBulkPDFEnrichmentStopsOnAccessRestrictionsAndAllowsRetry() async {
        let errors: [HHAPIError] = [.unauthorized, .forbidden(requestID: "test"),
            .rateLimited(retryAfterSeconds: 60), .captchaRequired(requestID: "test"),
            .missingApplicationToken, .placeholderApplicationToken]
        for error in errors {
            let client = PDFEnrichmentClient(error: error)
            let exporter = PDFEnrichmentExporter()
            let model = await enrichmentModel(client: client, exporter: exporter)
            await model.exportVacanciesPDF()
            let stoppedCount = await client.requests
            XCTAssertEqual(stoppedCount, 1, "\(error)")
            XCTAssertEqual(exporter.snapshots.count, 0, "Restricted export must not be presented as complete")
            XCTAssertFalse(model.isExportingBulkPDF)
            XCTAssertNil(model.bulkPDFExportProgress)
            XCTAssertTrue(model.canExportBulkPDF)
            XCTAssertTrue(model.statusMessage?.contains(error.localizedDescription) == true)
            await client.setError(nil)
            await model.exportVacanciesPDF()
            let retryCount = await client.requests
            XCTAssertEqual(retryCount, 4)
            XCTAssertEqual(exporter.snapshots.count, 1)
            XCTAssertEqual(exporter.snapshots.first?.count, 3)
        }
    }

    @MainActor
    func testBulkPDFEnrichmentPropagatesCancellationWithoutPublishing() async {
        let client = PDFEnrichmentClient(error: CancellationError())
        let exporter = PDFEnrichmentExporter()
        let model = await enrichmentModel(client: client, exporter: exporter)
        await model.exportVacanciesPDF()
        let count = await client.requests
        XCTAssertEqual(count, 1)
        XCTAssertTrue(exporter.snapshots.isEmpty)
        XCTAssertFalse(model.isExportingBulkPDF)
        XCTAssertNil(model.bulkPDFExportProgress)
        XCTAssertEqual(model.statusMessage, "Сохранение вакансий в PDF отменено.")
    }

    @MainActor
    func testBulkPDFEnrichmentTaskCancellationStopsInFlightAndAllowsNextExport() async throws {
        let client = PDFEnrichmentClient(delay: 300_000_000)
        let exporter = PDFEnrichmentExporter()
        let model = await enrichmentModel(client: client, exporter: exporter)
        let task = Task { await model.exportVacanciesPDF() }
        for _ in 0..<1000 {
            if await client.requests == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        await task.value
        let count = await client.requests
        XCTAssertEqual(count, 1)
        XCTAssertTrue(exporter.snapshots.isEmpty)
        XCTAssertTrue(model.canExportBulkPDF)
        await client.setDelay(0)
        await model.exportVacanciesPDF()
        XCTAssertEqual(exporter.snapshots.count, 1)
    }

    @MainActor
    func testBulkPDFFailsClosedWhenFullDescriptionIsUnavailable() async {
        for error in [HHAPIError.requestFailed(statusCode: 404, message: nil) as Error, URLError(.timedOut)] {
            let client = PDFEnrichmentClient(error: error)
            let exporter = PDFEnrichmentExporter()
            let model = await enrichmentModel(client: client, exporter: exporter)
            await model.exportVacanciesPDF()
            let count = await client.requests
            XCTAssertEqual(count, 1)
            XCTAssertTrue(exporter.snapshots.isEmpty)
            XCTAssertNotNil(model.statusMessage)
        }
    }



    private func makePDFVacancy(id: String) -> VacancySearchResult {
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
    private func checkLiveDetailCancellation(transition: LiveCancellationTransition) async throws {
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
    private func makeFilterViewModel() -> VacancySearchViewModel {
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
    private func assertStatisticsExport(_ model: VacancySearchViewModel, client: MockAPIClient,
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
    private func enrichmentModel(client: PDFEnrichmentClient, exporter: PDFEnrichmentExporter) async -> VacancySearchViewModel {
        let dir = temporaryDirectory()
        let store = VacancySnapshotStore(fileURL: dir.appendingPathComponent("vacancies.json"))
        try! store.save(VacancySnapshot(values: (1...3).map { statisticsVacancy(id: String($0), date: "2026-09-01T10:00:00Z") }, issues: [], updatedAt: Date()))
        let model = VacancySearchViewModel(apiClient: client,
            employerStore: TestEmployerStore(entries: [.init(id: "47858", name: "Банк России", comment: "test")]),
            snapshotStore: store, bulkPDFExporter: exporter)
        await model.loadPersistenceIfNeeded()
        return model
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("HHVacancyCBRTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }


    private func makeHTTPClient(
        handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)
    ) -> HHAPIClient {
        URLProtocolStub.handler = handler
        return HTTPClientFactory.make()
    }

    private func assertAPIError(_ client: HHAPIClient, equals expected: HHAPIError) async {
        do {
            _ = try await client.searchVacancies(.init(employerID: "47858"))
            XCTFail("Expected \(expected)")
        } catch let error as HHAPIError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static let areaTree = HHAreaNode(id: "113", name: "Россия", areas: [
        .init(id: "1", name: "Москва"),
        .init(id: "2", name: "Санкт-Петербург"),
        .init(id: "66", name: "Свердловская область", areas: [.init(id: "3", name: "Екатеринбург")])
    ])

    private func summary(
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

private struct TestEmployerStore: EmployerConfigurationStoring {
    let entries: [EmployerConfigurationEntry]
    func loadOrCreate() throws -> EmployerConfiguration {
        try EmployerConfiguration(version: 1, employers: entries).validated()
    }
}

private struct CancelledAreaClient: HHVacancyAPIClient {
    var responseGate: TestAsyncSignal? = nil
    var onRequest: @Sendable () -> Void = {}
    func validateVacanciesAccess() throws {}
    func areaTree() async throws -> HHAreaNode {
        onRequest()
        if let responseGate {
            await responseGate.wait()
            return .init(id: "113", name: "Россия", areas: [.init(id: "1", name: "Москва")])
        }
        throw CancellationError()
    }
    func searchVacancies(_ request: HHVacancySearchRequest) async throws -> HHVacancySearchResponse {
        XCTFail("Search must not follow a cancelled area request")
        throw CancellationError()
    }
    func vacancyDetails(id: String) async throws -> HHVacancyDetails {
        XCTFail("Unexpected detail request")
        throw CancellationError()
    }
    func vacancyDictionaries() async throws -> HHVacancyDictionaries {
        XCTFail("Unexpected dictionary request")
        throw CancellationError()
    }
}

private actor EmployerScriptedClient: HHVacancyAPIClient {
    enum Behavior: Sendable { case vacancies(Int), failAfterFirstPage(Int), failure, forbidden, restriction(HHAPIError), restrictionAfterFirstPage(Int, HHAPIError), cancelled }
    var behaviors: [String: Behavior]
    func setBehavior(_ value: Behavior, employerID: String) { behaviors[employerID] = value }
    private(set) var requestedEmployerIDs: [String] = []
    init(behaviors: [String: Behavior]) { self.behaviors = behaviors }
    nonisolated func validateVacanciesAccess() throws {}
    func areaTree() async throws -> HHAreaNode { .init(id: "113", name: "Россия", areas: [.init(id: "1", name: "Москва")]) }
    func vacancyDictionaries() async throws -> HHVacancyDictionaries { .init(experience: [], workFormat: [], schedule: []) }
    func vacancyDetails(id: String) async throws -> HHVacancyDetails {
        XCTFail("Unexpected detail request"); throw HHAPIError.invalidResponse
    }
    func searchVacancies(_ request: HHVacancySearchRequest) async throws -> HHVacancySearchResponse {
        requestedEmployerIDs.append(request.employerID)
        let count: Int
        switch behaviors[request.employerID] ?? .vacancies(0) {
        case .failure: throw URLError(.timedOut)
        case .forbidden: throw HHAPIError.forbidden(requestID: nil)
        case .restriction(let error): throw error
        case .cancelled: throw CancellationError()
        case .restrictionAfterFirstPage(let value, let error):
            if request.page > 0 { throw error }
            count = value
        case .vacancies(let value): count = value
        case .failAfterFirstPage(let value):
            if request.page > 0 { throw HHAPIError.requestFailed(statusCode: 502, message: nil) }
            count = value
        }
        let start = request.page * request.perPage
        let end = min(start + request.perPage, count)
        let items = start < end ? (start..<end).map { index in
            HHVacancySummary(
                id: "\(request.employerID)-\(index)", name: "Вакансия \(index)",
                employer: .init(name: "Работодатель", id: request.employerID), salary: nil,
                area: .init(id: "1", name: "Москва"), alternateURL: nil, url: nil, snippet: nil,
                publishedAt: "2026-09-01T10:00:00+0300"
            )
        } : []
        return .init(items: items, found: count, pages: Int(ceil(Double(count) / Double(request.perPage))),
                     page: request.page, perPage: request.perPage)
    }
}

private actor MockAPIClient: HHVacancyAPIClient {
    enum Mode: Sendable {
        case simple, partitioned, mismatch, surplus, failure, delayedArchive, archiveNotFound
        case archiveRecoverableFailure, archiveTerminalFailure, archiveCancelled, delayedRefreshFailure, filters
    }
    let mode: Mode
    private(set) var detailRequestCount = 0
    private(set) var requestedDetailIDs: [String] = []
    private(set) var searchRequestCount = 0
    private var shouldFailSearch = false
    private let beforeFirstDetailResponse: (@Sendable () async throws -> Void)?
    private let beforeSearchResponse: (@Sendable () async throws -> Void)?
    init(mode: Mode, beforeFirstDetailResponse: (@Sendable () async throws -> Void)? = nil,
         beforeSearchResponse: (@Sendable () async throws -> Void)? = nil) {
        self.mode = mode
        self.beforeFirstDetailResponse = beforeFirstDetailResponse
        self.beforeSearchResponse = beforeSearchResponse
    }
    func enableDelayedSearchFailure() { shouldFailSearch = true }
    nonisolated func validateVacanciesAccess() throws {}
    func areaTree() async throws -> HHAreaNode {
        if case .failure = mode { throw URLError(.notConnectedToInternet) }
        return .init(id: "113", name: "Россия", areas: [
            .init(id: "1", name: "Москва"),
            .init(id: "2", name: "Санкт-Петербург"),
            .init(id: "66", name: "Свердловская область", areas: [.init(id: "3", name: "Екатеринбург")])
        ])
    }
    func vacancyDictionaries() async throws -> HHVacancyDictionaries {
        if case .failure = mode { throw URLError(.notConnectedToInternet) }
        return .init(
            experience: ["noExperience", "between1And3", "between3And6", "moreThan6"].map { .init(id: $0, name: $0) },
            workFormat: [.init(id: "REMOTE", name: "Удалённо")],
            schedule: [.init(id: "remote", name: "Удалённая работа")]
        )
    }
    func vacancyDetails(id: String) async throws -> HHVacancyDetails {
        requestedDetailIDs.append(id)
        if case .archiveCancelled = mode, id.hasSuffix("cancel") { throw CancellationError() }
        if case .failure = mode { throw URLError(.notConnectedToInternet) }
        if case .archiveRecoverableFailure = mode, id.hasSuffix("fail") {
            throw URLError(.timedOut)
        }
        if case .archiveTerminalFailure = mode, id.hasSuffix("fail") {
            throw HHAPIError.rateLimited(retryAfterSeconds: 60)
        }
        if case .archiveNotFound = mode, id.hasSuffix("missing") {
            throw HHAPIError.requestFailed(statusCode: 404, message: nil)
        }
        detailRequestCount += 1
        if detailRequestCount == 1 { try await beforeFirstDetailResponse?() }
        if case .delayedArchive = mode {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let employerID: String
        if case .filters = mode {
            // Search IDs use the "filter-" prefix, not the employer ID.
            switch id {
            case "filter-remote": employerID = "1654251"
            case "filter-spb": employerID = "9999"
            default: employerID = "47858"
            }
        } else {
            employerID = id.components(separatedBy: "-").first ?? "47858"
        }
        let archived: Bool
        switch mode {
        case .archiveNotFound, .archiveRecoverableFailure, .archiveTerminalFailure, .archiveCancelled: archived = true
        default: archived = false
        }
        let employerName = employerID == "1654251" ? "НСПК" : employerID == "9999" ? "Альфа Банк" : "Банк России"
        return .init(id: id, name: "Вакансия \(id)", employer: .init(name: employerName, id: employerID),
                     area: .init(id: "1", name: "Москва"), salary: nil, alternateURL: nil,
                     description: "<p>Полное описание</p>", archived: archived)
    }
    func searchVacancies(_ request: HHVacancySearchRequest) async throws -> HHVacancySearchResponse {
        searchRequestCount += 1
        if request.text != nil { return .init(items: [], found: 0, pages: 0, page: request.page, perPage: request.perPage) }
        try await beforeSearchResponse?()
        if case .delayedRefreshFailure = mode, shouldFailSearch {
            try await Task.sleep(nanoseconds: 100_000_000)
            throw URLError(.timedOut)
        }
        switch mode {
        case .filters:
            let values: [HHVacancySummary]
            switch request.employerID {
            case "47858":
                values = [
                    makeSummary(id: "filter-moscow", employerID: "47858", employerName: "Банк России", areaID: "1", areaName: "Москва"),
                    makeSummary(id: "filter-ekb", employerID: "47858", employerName: "Банк России", areaID: "3", areaName: "Екатеринбург"),
                    makeSummary(id: "filter-unknown", employerID: "47858", employerName: "Банк России", areaID: "", areaName: "")
                ]
            case "1654251":
                values = [makeSummary(id: "filter-remote", employerID: "1654251", employerName: "НСПК", remote: true)]
            default:
                values = [makeSummary(id: "filter-spb", employerID: "9999", employerName: "Альфа Банк", areaID: "2", areaName: "Санкт-Петербург")]
            }
            return page(values, found: values.count, request: request)
        case .simple, .delayedArchive, .archiveNotFound, .archiveRecoverableFailure, .archiveTerminalFailure, .archiveCancelled,
             .delayedRefreshFailure:
            let remote = request.employerID == "1654251"
            let item = makeSummary(id: "\(request.employerID)-vacancy", employerID: request.employerID,
                                   employerName: remote ? "НСПК" : "Банк России", remote: remote)
            return page([item], found: 1, request: request)
        case .surplus:
            let start = request.page == 0 ? 1 : 101
            let end = request.page == 0 ? 100 : 151
            let values = (start...end).map { makeSummary(id: "surplus-\($0)", employerID: request.employerID, employerName: "Банк России") }
            return .init(items: values, found: request.page == 0 ? 150 : 151, pages: 2, page: request.page, perPage: request.perPage)
        case .mismatch:
            return page([makeSummary(id: "only-one", employerID: request.employerID, employerName: "Банк России")], found: 2, request: request)
        case .partitioned:
            let count: Int
            let prefix: String
            switch request.areaID {
            case "10": count = 1_200; prefix = "a"
            case "20": count = 801; prefix = "b"
            default: count = 2_001; prefix = "root"
            }
            let start = request.page * request.perPage
            let end = min(start + request.perPage, count)
            let values = start < end ? (start..<end).map {
                makeSummary(id: "\(prefix)-\($0)", employerID: request.employerID, employerName: "Банк России")
            } : []
            return .init(items: values, found: count, pages: Int(ceil(Double(count) / Double(request.perPage))), page: request.page, perPage: request.perPage)
        case .failure:
            throw URLError(.notConnectedToInternet)
        }
    }
    private func page(_ all: [HHVacancySummary], found: Int, request: HHVacancySearchRequest) -> HHVacancySearchResponse {
        let start = request.page * request.perPage
        let end = min(start + request.perPage, all.count)
        let items = start < end ? Array(all[start..<end]) : []
        return .init(items: items, found: found, pages: Int(ceil(Double(found) / Double(request.perPage))), page: request.page, perPage: request.perPage)
    }
    private func makeSummary(
        id: String,
        employerID: String,
        employerName: String,
        remote: Bool = false,
        areaID: String = "1",
        areaName: String = "Москва"
    ) -> HHVacancySummary {
        documentedTestSummary(HHVacancySummary(id: id, name: "Вакансия \(id)", employer: .init(name: employerName, id: employerID), salary: nil,
              area: remote ? nil : .init(id: areaID, name: areaName), alternateURL: nil, url: nil, snippet: nil,
              workFormat: remote ? [.init(id: "REMOTE", name: "Удалённо")] : nil,
              publishedAt: employerID == "47858" ? "2026-09-02T10:00:00+0300" : "2026-09-01T10:00:00+0300"))
    }
}

private struct FixedTokenProvider: HHAccessTokenProviding {
    let accessToken: String? = "unit-token"
}

@MainActor
private final class PDFEnrichmentExporter: VacanciesPDFExporting {
    var snapshots: [[VacancySearchResult]] = []
    var onExport: (() -> Void)?
    var beforeCompletion: (@MainActor () async -> Void)?
    func export(vacancies: [VacancySearchResult], progress: @escaping @MainActor @Sendable (BulkPDFExportProgress) -> Void) async throws -> BulkPDFExportOutcome {
        onExport?()
        snapshots.append(vacancies)
        await beforeCompletion?()
        return .cancelled
    }
}

private actor SuspendedEnrichmentClient: HHVacancyAPIClient {
    private var requests = 0
    private let resume = TestAsyncSignal()
    private let onFirstRequest: @Sendable () -> Void
    init(onFirstRequest: @escaping @Sendable () -> Void) { self.onFirstRequest = onFirstRequest }
    nonisolated func validateVacanciesAccess() throws {}
    func resumeFirstRequest() async { await resume.signal() }
    func vacancyDetails(id: String) async throws -> HHVacancyDetails {
        requests += 1
        if requests == 1 {
            onFirstRequest()
            await resume.wait()
            throw URLError(.timedOut)
        }
        return .init(id: id, name: "Вакансия \(id)", employer: nil, area: nil,
            salary: nil, alternateURL: nil, description: nil, archived: true)
    }
    func searchVacancies(_ request: HHVacancySearchRequest) async throws -> HHVacancySearchResponse {
        XCTFail("Unexpected search"); throw HHAPIError.invalidResponse
    }
    func areaTree() async throws -> HHAreaNode { XCTFail("Unexpected areas"); throw HHAPIError.invalidResponse }
    func vacancyDictionaries() async throws -> HHVacancyDictionaries { XCTFail("Unexpected dictionaries"); throw HHAPIError.invalidResponse }
}

private struct FixedSummaryAPIClient: HHVacancyAPIClient {
    let rows: [HHVacancySummary]
    private let detailLoader: (@Sendable (String) async throws -> HHVacancyDetails)?
    init(rows: [HHVacancySummary], detailLoader: (@Sendable (String) async throws -> HHVacancyDetails)? = nil) {
        self.rows = rows
        self.detailLoader = detailLoader
    }
    func validateVacanciesAccess() throws {}
    func searchVacancies(_ request: HHVacancySearchRequest) async throws -> HHVacancySearchResponse {
        .init(items: rows, found: rows.count, pages: 1, page: 0, perPage: request.perPage)
    }
    func areaTree() async throws -> HHAreaNode { .init(id: "113", name: "Россия", areas: [.init(id: "1", name: "Москва")]) }
    func vacancyDictionaries() async throws -> HHVacancyDictionaries { .init(experience: [], workFormat: [], schedule: []) }
    func vacancyDetails(id: String) async throws -> HHVacancyDetails {
        if let detailLoader { return try await detailLoader(id) }
        XCTFail("Search must not enrich"); throw HHAPIError.invalidResponse
    }
}

private actor PDFEnrichmentClient: HHVacancyAPIClient {
    var requests = 0
    private var error: Error?
    private var delay: UInt64
    init(error: Error? = nil, delay: UInt64 = 0) { self.error = error; self.delay = delay }
    func setError(_ error: Error?) { self.error = error }
    func setDelay(_ delay: UInt64) { self.delay = delay }
    nonisolated func validateVacanciesAccess() throws {}
    func vacancyDetails(id: String) async throws -> HHVacancyDetails {
        requests += 1
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let error { throw error }
        return .init(id: id, name: "Вакансия \(id)", employer: nil, area: nil, salary: nil,
            alternateURL: nil, description: "<p>Полные данные \(id)</p>")
    }
    func searchVacancies(_ request: HHVacancySearchRequest) async throws -> HHVacancySearchResponse {
        XCTFail("PDF must not search"); throw HHAPIError.invalidResponse
    }
    func areaTree() async throws -> HHAreaNode { XCTFail("PDF must not load areas"); throw HHAPIError.invalidResponse }
    func vacancyDictionaries() async throws -> HHVacancyDictionaries { XCTFail("PDF must not load dictionaries"); throw HHAPIError.invalidResponse }
}

private actor TestAsyncSignal {
    private var signalled = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { if !signalled { await withCheckedContinuation { waiter = $0 } } }
    func signal() { signalled = true; waiter?.resume(); waiter = nil }
}

private actor ConcurrentOperationTracker {
    private var activeOperations = 0
    private(set) var maximumConcurrentOperations = 0

    func begin() {
        activeOperations += 1
        maximumConcurrentOperations = max(maximumConcurrentOperations, activeOperations)
    }

    func end() { activeOperations -= 1 }
}


private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock(); defer { unlock() }; return operation()
    }
}

private actor RetryWaitRecorder {
    var values: [UInt64] = []
    func append(_ value: UInt64) { values.append(value) }
}

private enum HTTPClientFactory {
    static func make(
        maximumRateLimitRetries: Int = 2,
        maximumTransientRetries: Int = 2,
        requestGate: HHRequestGate? = nil,
        retrySleep: @escaping @Sendable (UInt64) async throws -> Void = { _ in }
    ) -> HHAPIClient {
        let clock = AuditClock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return HHAPIClient(
            session: URLSession(configuration: configuration),
            accessTokenProvider: FixedTokenProvider(),
            requestGate: requestGate ?? HHRequestGate(minimumDelayNanoseconds: 0,
                monotonicNow: { clock.now }, sleep: { clock.advance(Double($0) / 1e9) }),
            maximumRateLimitRetries: maximumRateLimitRetries,
            maximumTransientRetries: maximumTransientRetries,
            retrySleep: { value in
                try await retrySleep(value)
                clock.advance(Double(value) / 1e9)
            }
        )
    }
}

private final class URLProtocolStub: URLProtocol {
    private final class HandlerBox: @unchecked Sendable {
        let lock = NSRecursiveLock()
        var value: ((URLRequest) throws -> (Int, [String: String], Data))?
    }
    private static let box = HandlerBox()
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))? {
        get { box.lock.lock(); defer { box.lock.unlock() }; return box.value }
        set { box.lock.lock(); defer { box.lock.unlock() }; box.value = newValue }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, headers, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}


private enum LiveCancellationTransition: Int {
    case employer = 0, region = 1
}

private enum LiveCancellationFailure: Error {
    case stopped, budgetExhausted, responseShape, http(Int), transport(Int), apiFailure
}

private final class LiveCancellationHTTPObserver: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String] = []

    var journal: String {
        lock.lock(); defer { lock.unlock() }
        return records.joined(separator: "\n")
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let formatter = ISO8601DateFormatter()
        let entries = metrics.transactionMetrics.map { transaction in
            let timestamp = formatter.string(from: transaction.requestStartDate ?? transaction.fetchStartDate ?? metrics.taskInterval.start)
            let path = transaction.request.url?.path ?? "unknown"
            let status = (transaction.response as? HTTPURLResponse).map { String($0.statusCode) } ?? "no-http-response"
            return "\(timestamp) GET \(path) status=\(status)"
        }
        lock.lock(); records.append(contentsOf: entries); lock.unlock()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // No additional redirect request outside the live group's explicit budget.
        completionHandler(nil)
    }
}

@MainActor
private final class LiveCancellationRun {
    static let shared = LiveCancellationRun()
    private let observer: LiveCancellationHTTPObserver
    private let session: URLSession
    private let client: HHAPIClient
    private var rows: [HHVacancySummary]?
    private(set) var stopped = false
    private(set) var requestCount = 0
    private var attempts: [String] = []
    var journal: String { (attempts + [observer.journal]).joined(separator: "\n") }

    private init() {
        let observer = LiveCancellationHTTPObserver()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: observer, delegateQueue: nil)
        self.observer = observer
        self.session = session
        self.client = HHAPIClient(session: session, requestGate: HHRequestGate(minimumDelayNanoseconds: 1_000_000_000), maximumRateLimitRetries: 0, maximumTransientRetries: 0)
    }

    private func begin(path: String) throws {
        guard !stopped else { throw LiveCancellationFailure.stopped }
        guard requestCount < 4 else { throw LiveCancellationFailure.budgetExhausted }
        requestCount += 1
        attempts.append("\(ISO8601DateFormatter().string(from: Date())) attempt=\(requestCount) GET \(path)")
    }

    private func stop(after error: Error) -> LiveCancellationFailure {
        stopped = true
        let safe: LiveCancellationFailure
        if let error = error as? URLError {
            safe = .transport(error.code.rawValue)
        } else if let error = error as? HHAPIError {
            switch error {
            case .forbidden: safe = .http(403)
            case .rateLimited: safe = .http(429)
            case .unauthorized: safe = .http(401)
            case .requestFailed(let status, _): safe = .http(status)
            default: safe = .apiFailure
            }
        } else {
            safe = .responseShape
        }
        attempts.append("Group stopped: \(safe)")
        return safe
    }

    func searchRows() async throws -> [HHVacancySummary] {
        if let rows { return rows }
        try begin(path: "/vacancies")
        do {
            let response = try await client.searchVacancies(.init(employerID: "47858", areaID: "1", perPage: 3))
            let parser = HHPublicationDateParser()
            guard response.items.count <= 3,
                  Set(response.items.map(\.id)).count == response.items.count,
                  response.items.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty && $0.employer?.id == "47858"
                      && parser.date(from: $0.publishedAt) != nil }) else {
                throw LiveCancellationFailure.responseShape
            }
            rows = response.items
            return response.items
        } catch { throw stop(after: error) }
    }

    func detail(id: String) async throws -> HHVacancyDetails {
        try begin(path: "/vacancies/\(id)")
        do {
            let response = try await client.vacancyDetails(id: id)
            let parser = HHPublicationDateParser()
            guard response.id == id, !response.name.isEmpty,
                  parser.date(from: response.publishedAt) != nil else {
                throw LiveCancellationFailure.responseShape
            }
            return response
        } catch { throw stop(after: error) }
    }
}


/// A locked virtual monotonic clock; advancing it never waits on wall time.
private final class AuditClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value += seconds }
}


private final class TestSupportFileManager: FileManager, @unchecked Sendable {
    let base: URL?
    init(base: URL?) { self.base = base; super.init() }
    override func url(for directory: FileManager.SearchPathDirectory, in domain: FileManager.SearchPathDomainMask,
                      appropriateFor url: URL?, create shouldCreate: Bool) throws -> URL {
        guard let base else { throw CocoaError(.fileReadNoPermission) }
        return base
    }
    override var temporaryDirectory: URL {
        XCTFail("Persistent data must never fall back to TMPDIR")
        return super.temporaryDirectory
    }
}

private actor FieldSearchClient: HHVacancyAPIClient {
    let rows: [HHVacancySummary]
    var requests: [HHVacancySearchRequest] = []
    let restrictSupplement: Bool
    init(rows: [HHVacancySummary], restrictSupplement: Bool = false) { self.rows = rows; self.restrictSupplement = restrictSupplement }
    nonisolated func validateVacanciesAccess() throws {}
    func searchVacancies(_ request: HHVacancySearchRequest) async throws -> HHVacancySearchResponse {
        requests.append(request)
        if restrictSupplement, request.text != nil { throw HHAPIError.rateLimited(retryAfterSeconds: 60) }
        return .init(items: request.text == nil ? [rows[0]] : rows, found: request.text == nil ? 1 : 500,
                     pages: request.text == nil ? 1 : 5, page: request.page, perPage: request.perPage)
    }
    func vacancyDetails(id: String) async throws -> HHVacancyDetails {
        let row = rows[0]
        return .init(id: id, name: row.name, employer: row.employer, area: row.area, salary: nil,
                     alternateURL: nil, description: "Место работы: полевое учреждение Банка России Инское")
    }
    func areaTree() async throws -> HHAreaNode { .init(id: "113", name: "Россия") }
    func vacancyDictionaries() async throws -> HHVacancyDictionaries { .init(experience: [], workFormat: [], schedule: []) }
}

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

// Independent-source regression fixtures. These bytes are synthetic test data, never live evidence.
private enum TrudFixture {
    static let bank = OrganizationRegistry.all[0]
    static func row(_ id: String, org: Organization = bank, company: String = "division-a", title: String = "Аналитик") -> [String: Any] {
        ["vacancy": ["id": id, "job-name": title, "company": ["inn": org.inn, "ogrn": org.ogrn, "companycode": company, "name": "Подразделение \(company)"],
            "region": ["region_code": "77", "name": "Москва"], "creation-date": "2026-10-21", "salary_min": 100000,
            "duty": "Полное описание Unicode ё Ω", "custom": ["boolean": true, "nullable": NSNull(), "list": [1, "два"]]]]
    }
    static func data(_ rows: [[String: Any]], total: Any? = nil, status: Any = "200") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["status": status, "meta": ["total": total ?? rows.count], "results": ["vacancies": rows]], options: [.sortedKeys])
    }
    static func page(_ rows: [[String: Any]], total: Any? = nil) throws -> TrudvsemPage { try TrudvsemPage(data: data(rows, total: total)) }
    static func documented(_ id: String = "test", org: Organization = bank) throws -> TrudvsemVacancy {
        let data = try data([row(id, org: org)])
        let url = try TrudvsemAPIClient.url(inn: org.inn, page: 0, limit: 100)
        let observation = try XCTUnwrap(PDFSourceEvidence.shared.capture(data: data, url: url, status: 200, sent: Date(), received: Date()))
        let dto = try XCTUnwrap(TrudvsemPage(data: data).vacancies.first)
        return TrudvsemVacancy(dto: dto, organization: org, observationIDs: [observation.id])
    }
}
private actor TrudScriptedClient: TrudvsemAPI {
    var calls: [(String, Int, Int)] = []
    let responses: [TrudvsemPage]
    let delay: UInt64
    init(_ responses: [TrudvsemPage], delay: UInt64 = 0) { self.responses = responses; self.delay = delay }
    func vacancies(inn: String, page: Int, limit: Int) async throws -> TrudvsemPage {
        calls.append((inn, page, limit))
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return responses[min(page, responses.count - 1)]
    }
}

extension HHVacancyCBRTests {
    func testTrudSearchSucceedsWhenEvidenceCannotBeWritten() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let root = directory.appendingPathComponent("file")
        try Data("not a directory".utf8).write(to: root)
        let data = try TrudFixture.data([TrudFixture.row("one")])
        let client = TrudvsemAPIClient(evidence: PDFSourceEvidence(root: root),
            gate: TrudvsemRequestGate(minimumInterval: 0), transport: { request in
                (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            })
        let page = try await client.vacancies(inn: TrudFixture.bank.inn, page: 0, limit: 100)
        XCTAssertEqual(page.vacancies.count, 1)
        XCTAssertNil(page.observationID)
    }

    func testTrudEmployerRegistryMigrationPreservesAndResetsConfirmedCodes() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("employers.json")
        let organizations = OrganizationRegistry.available(on: .trudvsem)
        let first = try XCTUnwrap(organizations.first)
        let old = TrudvsemEmployerConfiguration(version: 1, employers: [
            .init(organizationKey: first.id, inn: first.inn, ogrn: first.ogrn, confirmedCompanyCodes: ["retained"]),
            .init(organizationKey: organizations[1].id, inn: "old", ogrn: "old", confirmedCompanyCodes: ["stale"])
        ])
        try JSONEncoder().encode(old).write(to: url)
        let store = TrudvsemEmployerConfigurationStore(configuredURL: url)
        let updated = try store.loadOrCreate()
        XCTAssertEqual(updated.employers.count, organizations.count)
        XCTAssertEqual(updated.employers.first?.confirmedCompanyCodes, ["retained"])
        XCTAssertEqual(updated.employers[1].inn, organizations[1].inn)
        XCTAssertTrue(updated.employers[1].confirmedCompanyCodes.isEmpty)
        XCTAssertEqual(try store.loadOrCreate().employers.count, organizations.count)
    }

    func testTrudDescriptionAndSalaryAreHumanReadable() throws {
        var row = TrudFixture.row("format")
        var vacancy = try XCTUnwrap(row["vacancy"] as? [String: Any])
        vacancy["requirement"] = ["education": "Общее образование", "experience": 1, "code": 42]
        vacancy["salary"] = 60000
        vacancy.removeValue(forKey: "salary_min")
        row["vacancy"] = vacancy
        let dto = try XCTUnwrap(TrudFixture.page([row]).vacancies.first)
        let value = TrudvsemVacancy(dto: dto, organization: TrudFixture.bank, observationIDs: [])
        let html = TrudvsemDescriptionFormatter.html(for: value)
        XCTAssertTrue(html.contains("Образование: Общее образование"))
        XCTAssertTrue(html.contains("Опыт работы: 1 год"))
        XCTAssertFalse(html.contains("education:"))
        XCTAssertFalse(html.contains("experience:"))
        XCTAssertFalse(html.contains("42"))
        XCTAssertEqual(value.salary, "60 000 руб.")
    }

    func testTrudSalaryRemovesCurrencyQuotationMarks() throws {
        for currency in ["«руб.»", "\"руб.\"", "'RUR'", "„руб.“"] {
            var row = TrudFixture.row("currency")
            var vacancy = try XCTUnwrap(row["vacancy"] as? [String: Any])
            vacancy["salary_min"] = 50000
            vacancy["salary_max"] = 65000
            vacancy["currency"] = currency
            row["vacancy"] = vacancy
            let dto = try XCTUnwrap(TrudFixture.page([row]).vacancies.first)
            let value = TrudvsemVacancy(dto: dto, organization: TrudFixture.bank, observationIDs: [])
            XCTAssertEqual(value.salary, "50 000-65 000 руб.")
        }
    }

    func testTrudSalaryBoundsMatchHHFormat() throws {
        var row = TrudFixture.row("salary")
        var vacancy = try XCTUnwrap(row["vacancy"] as? [String: Any])
        vacancy["salary_min"] = 60000
        vacancy["salary_max"] = 90000
        row["vacancy"] = vacancy
        let dto = try XCTUnwrap(TrudFixture.page([row]).vacancies.first)
        XCTAssertEqual(TrudvsemVacancy(dto: dto, organization: TrudFixture.bank, observationIDs: []).salary,
                       HHSalary(from: 60000, to: 90000, currency: "RUR", gross: nil).displayText)
    }

    func testCanonicalSixOrganizationsAndSafeUnknownHHProfile() {
        XCTAssertEqual(OrganizationRegistry.all.map(\.id), ["bank_of_russia", "rosinkas", "nspk", "rnpk", "nsis", "uk_fkbs"])
        XCTAssertEqual(Set(OrganizationRegistry.all.map(\.inn)).count, 6)
        XCTAssertEqual(OrganizationRegistry.all[4].hhEmployerIDs, ["9942121"])
        XCTAssertTrue(OrganizationRegistry.all[5].hhEmployerIDs.isEmpty)
    }
    func testVersionedEmployerMigrationPreservesOverridesUnknownRecordsAndHistoricalData() throws {
        let dir = temporaryDirectory(), url = dir.appendingPathComponent("employers.json")
        let historical = dir.appendingPathComponent("favorites.json")
        let historicalBytes = Data("historical user data".utf8); try historicalBytes.write(to: historical)
        let old = EmployerConfiguration(version: 1, employers: [
            .init(id: "47858", name: "Моё название", comment: "Моя запись"),
            .init(id: "999", name: "Дополнительный", comment: "Подтверждён пользователем")])
        try JSONEncoder().encode(old).write(to: url)
        let store = EmployerConfigurationStore(fileURL: url)
        let migrated = try store.loadOrCreate(), once = try Data(contentsOf: url)
        XCTAssertEqual(migrated.version, 2)
        XCTAssertEqual(migrated.employers.prefix(2), old.employers[...])
        XCTAssertEqual(Set(migrated.employers.map(\.id)).count, 6)
        XCTAssertEqual(try store.loadOrCreate(), migrated)
        XCTAssertEqual(try Data(contentsOf: url), once)
        XCTAssertEqual(try Data(contentsOf: historical), historicalBytes)
        let unsupported = Data(#"{"version":99,"employers":[]}"#.utf8); try unsupported.write(to: url)
        XCTAssertThrowsError(try store.loadOrCreate()); XCTAssertEqual(try Data(contentsOf: url), unsupported)
    }
    func testTrudDTOHeterogeneousOptionalFieldsAndStatus() throws {
        let data = try TrudFixture.data([TrudFixture.row("one")], total: "1")
        let page = try TrudvsemPage(data: data)
        XCTAssertEqual(page.total, 1); XCTAssertEqual(page.malformedCount, 0)
        XCTAssertEqual(page.vacancies[0].raw["custom"]["boolean"], .bool(true))
        XCTAssertEqual(page.vacancies[0].raw["custom"]["nullable"], .null)
        XCTAssertNil(page.vacancies[0].raw["missing_salary"].number)
        XCTAssertThrowsError(try TrudvsemPage(data: TrudFixture.data([], status: "500")))
        XCTAssertThrowsError(try TrudvsemPage(data: Data("not JSON".utf8)))
        XCTAssertEqual(try TrudFixture.page([], total: "0").vacancies.count, 0)
        XCTAssertEqual(try TrudvsemPage(data: TrudFixture.data([], status: 200)).total, 0)
        let mixed = try TrudFixture.page([TrudFixture.row("good"), ["vacancy": ["id": "bad"]]], total: 2)
        XCTAssertEqual(mixed.malformedCount, 1); XCTAssertEqual(mixed.vacancies.count, 1)
    }
    func testTrudURLPaginationAndSixIndependentINNs() async throws {
        let url = try TrudvsemAPIClient.url(inn: "7702235133", page: 2, limit: 100)
        XCTAssertEqual(url.scheme, "https"); XCTAssertTrue(url.absoluteString.contains("offset=2"))
        XCTAssertThrowsError(try TrudvsemAPIClient.url(inn: "bad", page: 0, limit: 100))
        XCTAssertThrowsError(try TrudvsemAPIClient.url(inn: "7702235133", page: 0, limit: 101))
        let client = TrudScriptedClient([try TrudFixture.page([])])
        let result = try await TrudvsemCollectionService(client: client).collect { _ in }
        let calls = await client.calls
        XCTAssertTrue(result.isComplete); XCTAssertEqual(calls.map(\.0), OrganizationRegistry.all.map(\.inn))
        XCTAssertTrue(calls.allSatisfy { $0.1 == 0 && $0.2 == 100 })
    }
    func testTrudCollectorPagesDedupAndCompanyDivisions() async throws {
        let client = TrudScriptedClient([
            try TrudFixture.page([TrudFixture.row("a"), TrudFixture.row("b")], total: 3),
            try TrudFixture.page([TrudFixture.row("b"), TrudFixture.row("a", company: "division-b")], total: 3)])
        let result = try await TrudvsemCollectionService(client: client, pageSize: 2).collect(organizations: [TrudFixture.bank]) { _ in }
        XCTAssertTrue(result.isComplete); XCTAssertEqual(result.vacancies.count, 3)
        XCTAssertEqual(result.metrics.first?.received, 4)
        let calls = await client.calls; XCTAssertEqual(calls.map(\.1), [0, 1])
        XCTAssertEqual(Set(result.vacancies.map(\.id)).count, 3)
        XCTAssertTrue(result.vacancies.allSatisfy { $0.id.hasPrefix("trudvsem.ru:") })
    }
    func testTrudCollectorFailsClosedOnRepeatsChangingTotalsMalformedAndForeignCompany() async throws {
        let cases = [
            [try TrudFixture.page([TrudFixture.row("a")], total: 2)],
            [try TrudFixture.page([TrudFixture.row("a")], total: 2), try TrudFixture.page([TrudFixture.row("b")], total: 3)],
            [try TrudFixture.page([["vacancy": ["id": "broken"]]], total: 1)],
            [try TrudFixture.page([TrudFixture.row("foreign", org: OrganizationRegistry.all[4])])],
            [try TrudFixture.page([], total: 2)]
        ]
        for pages in cases {
            let result = try await TrudvsemCollectionService(client: TrudScriptedClient(pages)).collect(organizations: [TrudFixture.bank]) { _ in }
            XCTAssertFalse(result.isComplete); XCTAssertFalse(result.issues.isEmpty)
        }
    }
    func testTrudFieldClassificationAndNegativeCases() throws {
        for (title, expected) in [("Полевое учреждение Инское Банка России", true), ("Полевой инженер", false), ("Опыт работы в полевом учреждении", false), ("Взаимодействие с полевыми учреждениями", false)] {
            let dto = try XCTUnwrap(TrudFixture.page([TrudFixture.row("one", title: title)]).vacancies.first)
            let value = TrudvsemVacancy(dto: dto, organization: TrudFixture.bank, observationIDs: [])
            XCTAssertEqual(value.fieldInstitution.isMember, expected, title)
            XCTAssertFalse(TrudvsemVacancy(dto: dto, organization: OrganizationRegistry.all[4], observationIDs: []).fieldInstitution.isMember)
        }
    }
    func testTrudClientRetriesAndCapturesUnchangedBytes() async throws {
        actor Counter { var n = 0; func next() -> Int { n += 1; return n } }
        let counter = Counter(), data = try TrudFixture.data([TrudFixture.row("a")])
        let evidence = PDFSourceEvidence(root: temporaryDirectory())
        let client = TrudvsemAPIClient(evidence: evidence, gate: isolatedTrudGate(), sleep: { _ in }, transport: { request in
            let n = await counter.next()
            return (data, HTTPURLResponse(url: request.url!, statusCode: n == 1 ? 429 : (n == 2 ? 503 : 200), httpVersion: nil, headerFields: ["Retry-After": "0"])!)
        })
        let result = try await client.vacancies(inn: TrudFixture.bank.inn, page: 0)
        let count = await counter.n; XCTAssertEqual(count, 3)
        let record = try evidence.observation(XCTUnwrap(result.observationID))
        XCTAssertEqual(record.resolvedSource, .trudvsem); XCTAssertEqual(record.hash, try MaterialHash.digest(data))
        let materials = try evidence.materials(for: DocumentContext(kind: "test", vacancyIDs: ["trudvsem.ru:division-a:a"], observationIDs: [record.id], source: .trudvsem))
        XCTAssertEqual(materials.first?.data, data)
        XCTAssertThrowsError(try evidence.materials(for: DocumentContext(kind: "test", vacancyIDs: ["trudvsem.ru:division-a:a"], observationIDs: [record.id])))
    }
    @MainActor
    func testTrudDisplayCacheInvalidatesAfterFiltersAndRefresh() async throws {
        let store = TrudvsemSnapshotStore(configuredURL: temporaryDirectory().appendingPathComponent("cache.json"))
        let value = try TrudFixture.documented()
        try store.save(.init(version: 1, vacancies: [value], metrics: [], updatedAt: .distantPast))
        let model = TrudvsemViewModel(client: TrudScriptedClient([try TrudFixture.page([])]), store: store)
        model.load()
        XCTAssertEqual(model.displayedResults, [value])
        model.selectedEmployerID = "nsis"
        XCTAssertTrue(model.displayedResults.isEmpty)
        model.selectedEmployerID = "all"
        XCTAssertEqual(model.displayedResults, [value])
        model.selectedRegionID = "missing"
        XCTAssertTrue(model.displayedResults.isEmpty)
        model.selectedRegionID = "all"
        XCTAssertEqual(model.displayedResults, [value])
        XCTAssertGreaterThan(model.regions.count, 1)
        await model.refresh()
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.displayedResults.isEmpty)
        XCTAssertEqual(model.regions.count, 1)
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

    @MainActor
    func testThreeTrudPDFModesAttachExactSourcesAndRejectMissingEvidence() async throws {
        let values = [try TrudFixture.documented("one"), try TrudFixture.documented("two")]
        let dir = temporaryDirectory(), worker = PDFExportWorker()
        let documents = [TrudvsemPDFFormatter.personal(values[0]), TrudvsemPDFFormatter.statistics(values, filters: ["Регион": "Москва"])]
        for (index, document) in documents.enumerated() {
            let url = dir.appendingPathComponent("mode\(index).pdf")
            try await worker.exportDocument(document: document, destination: url)
            let data = try Data(contentsOf: url), pdf = try XCTUnwrap(PDFDocument(data: data))
            XCTAssertGreaterThan(pdf.pageCount, 0)
            XCTAssertTrue(pdf.string?.contains("trudvsem.ru") == true)
            XCTAssertFalse(pdf.string?.contains("HeadHunter") == true)
            for material in try PDFSourceEvidence.shared.materials(for: document.context) { XCTAssertNotNil(data.range(of: material.data)) }
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("/EmbeddedFiles"))
        }
        let prepared = try await worker.prepareTrudvsem(vacancies: values, filters: ["Регион": "Москва"]) { _ in }
        let urls = try await worker.writePrepared(names: (0..<prepared.partCount).map { "bulk\($0).pdf" }, directory: dir)
        XCTAssertEqual(urls.count, prepared.partCount)
        for url in urls {
            let pdf = try XCTUnwrap(PDFDocument(url: url)); XCTAssertLessThanOrEqual(pdf.pageCount, 100)
            XCTAssertTrue(pdf.string?.contains("Москва") == true)
        }
        let missing = PDFVacancySnapshot(context: .init(kind: "Missing", vacancyIDs: ["missing"], source: .trudvsem), document: NSAttributedString(string: "Missing evidence"))
        try await worker.exportDocument(document: missing, destination: dir.appendingPathComponent("missing.pdf"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("missing.pdf").path))
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
}

private func documentedTestSummary(_ input: HHVacancySummary) -> HHVacancySummary {
    var value = input
    let bytes = try! JSONEncoder().encode(input)
    value.observationID = try! PDFSourceEvidence.shared.capture(data: bytes,
        url: URL(string: "https://api.hh.ru/vacancies/" + input.id)!, status: 200, sent: Date(), received: Date())!.id
    return value
}

extension HHVacancyCBRTests {
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
    func testTrudHTTPFailureBudgetTimeoutAndCancellation() async throws {
        actor Counter { var count = 0; func increment() { count += 1 } }
        let counter = Counter()
        let failure = TrudvsemAPIClient(gate: isolatedTrudGate(), sleep: { _ in }, transport: { req in
            await counter.increment()
            return (Data(), HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!)
        })
        do { _ = try await failure.vacancies(inn: TrudFixture.bank.inn, page: 0); XCTFail("Expected 500") } catch { }
        let count = await counter.count; XCTAssertEqual(count, 3)
        let timeout = TrudvsemAPIClient(gate: isolatedTrudGate(), sleep: { _ in }, transport: { _ in throw URLError(.timedOut) })
        do { _ = try await timeout.vacancies(inn: TrudFixture.bank.inn, page: 0); XCTFail("Expected timeout") }
        catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        let waiting = TrudvsemAPIClient(gate: isolatedTrudGate(), transport: { _ in try await Task.sleep(nanoseconds: 30_000_000_000); throw CancellationError() })
        let task = Task { try await waiting.vacancies(inn: TrudFixture.bank.inn, page: 0) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testTrudSnapshotCorruptionAndFailedWriteAreNotSilentlyAccepted() throws {
        let dir = temporaryDirectory(), url = dir.appendingPathComponent("snapshot.json")
        let bytes = Data("{bad".utf8); try bytes.write(to: url)
        let store = TrudvsemSnapshotStore(configuredURL: url)
        XCTAssertThrowsError(try store.load()); XCTAssertEqual(try Data(contentsOf: url), bytes)
        let invalidParent = dir.appendingPathComponent("not-a-directory"); try bytes.write(to: invalidParent)
        let failing = TrudvsemSnapshotStore(configuredURL: invalidParent.appendingPathComponent("snapshot.json"))
        XCTAssertThrowsError(try failing.save(.init(version: 1, vacancies: [], metrics: [], updatedAt: Date())))
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
}

extension HHVacancyCBRTests {
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

private func isolatedTrudGate() -> TrudvsemRequestGate {
    let clock = AuditClock()
    return TrudvsemRequestGate(now: { clock.now }, sleep: { clock.advance(Double($0) / 1e9) })
}

extension HHVacancyCBRTests {
    func testTrudServerCooldownSurvivesNewClientAndLongDelayDoesNotRetryEarly() async throws {
        actor Counter {
            var count = 0
            func next() -> Int { count += 1; return count }
        }
        let clock = AuditClock(), counter = Counter()
        let gate = TrudvsemRequestGate(now: { clock.now }, sleep: { clock.advance(Double($0) / 1e9) })
        let data = try TrudFixture.data([])
        let transport: TrudvsemAPIClient.Transport = { request in
            let attempt = await counter.next()
            return (data, HTTPURLResponse(url: request.url!, statusCode: attempt == 1 ? 429 : 200,
                httpVersion: nil, headerFields: ["Retry-After": "120"])!)
        }
        let first = TrudvsemAPIClient(gate: gate, sleep: { _ in }, transport: transport)
        let second = TrudvsemAPIClient(evidence: PDFSourceEvidence(root: temporaryDirectory()), gate: gate, transport: transport)
        for client in [first, second] {
            do { _ = try await client.vacancies(inn: TrudFixture.bank.inn, page: 0); XCTFail("Server embargo must stop requests") }
            catch { guard case TrudvsemError.http(429) = error else { return XCTFail("Unexpected error: \(error)") } }
        }
        let before = await counter.count
        XCTAssertEqual(before, 1)
        clock.advance(120)
        _ = try await second.vacancies(inn: TrudFixture.bank.inn, page: 0)
        let after = await counter.count
        XCTAssertEqual(after, 2)
    }

    func testTrudOversizedRetryAfterDoesNotFallBackToShortRetry() {
        XCTAssertEqual(TrudvsemAPIClient.retryAfter(" " + String(repeating: "9", count: 400) + " ", now: Date()), .infinity)
        XCTAssertNil(TrudvsemAPIClient.retryAfter("NaN", now: Date()))
    }

    func testTrudURLCancellationIsNotRetried() async throws {
        actor Counter { var count = 0; func increment() { count += 1 } }
        let counter = Counter()
        let client = TrudvsemAPIClient(gate: isolatedTrudGate(), sleep: { _ in }, transport: { _ in
            await counter.increment()
            throw URLError(.cancelled)
        })
        do { _ = try await client.vacancies(inn: TrudFixture.bank.inn, page: 0); XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await counter.count
        XCTAssertEqual(calls, 1)
    }

    func testTrudRestrictionStopsRemainingEmployers() async throws {
        actor RestrictedClient: TrudvsemAPI {
            let status: Int
            var calls = 0
            init(_ status: Int) { self.status = status }
            func vacancies(inn: String, page: Int, limit: Int) async throws -> TrudvsemPage {
                calls += 1
                throw TrudvsemError.http(status)
            }
        }
        for status in [401, 403, 429] {
            let client = RestrictedClient(status)
            do { _ = try await TrudvsemCollectionService(client: client).collect { _ in }; XCTFail("Expected restriction") }
            catch { guard case TrudvsemError.http(status) = error else { return XCTFail("Unexpected error: \(error)") } }
            let calls = await client.calls
            XCTAssertEqual(calls, 1)
        }
    }

    func testTrudPageBudgetStopsChangingOverlappingPages() async throws {
        let pages = try ["a", "b", "c"].map { try TrudFixture.page([TrudFixture.row($0)], total: 100) }
        let client = TrudScriptedClient(pages)
        let result = try await TrudvsemCollectionService(client: client, maximumPagesPerEmployer: 2)
            .collect(organizations: [TrudFixture.bank]) { _ in }
        let calls = await client.calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(result.isComplete)
    }

    func testTrudExpiredCollectionMakesNoRequests() async throws {
        let client = TrudScriptedClient([try TrudFixture.page([])])
        do { _ = try await TrudvsemCollectionService(client: client, maximumDuration: 0).collect { _ in }; XCTFail("Expected deadline") }
        catch { XCTAssertTrue(error is TrudvsemError) }
        let calls = await client.calls
        XCTAssertTrue(calls.isEmpty)
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
