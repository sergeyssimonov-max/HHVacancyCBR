import AppKit
import Foundation
import PDFKit
import XCTest
import SwiftUI
@testable import HHVacancyCBR

extension HHVacancyCBRTests {
    @MainActor
    func testUpdateTimestampUsesLeadingZerosAnd24HourTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        for (hour, minute, expected) in [(7, 6, "07:06"), (0, 0, "00:00"), (23, 59, "23:59")] {
            let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 3, hour: hour, minute: minute)))
            XCTAssertEqual(VacancyDisplayFormat.updatedAt(date), "Обновлено: 03.01.2026, \(expected)")
        }
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
}
