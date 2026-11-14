import AppKit
import Foundation
import PDFKit
import XCTest
import SwiftUI
@testable import HHVacancyCBR

extension HHVacancyCBRTests {

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

    func testTrudSnapshotDiscardsImpossibleFieldCategoryAndPreservesSourceData() throws {
        for organization in OrganizationRegistry.all {
            let dto = try XCTUnwrap(TrudFixture.page([
                TrudFixture.row(organization.id, org: organization, title: "Кассир ПУ Инское")
            ]).vacancies.first)
            let original = TrudvsemVacancy(dto: dto, organization: organization, observationIDs: ["observation"])
            XCTAssertEqual(original.fieldInstitution.isMember, organization.id == "bank_of_russia")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
            json["fieldInstitution"] = ["isMember": true, "reason": "Сохраненная отметка"]
            let restored = try JSONDecoder().decode(TrudvsemVacancy.self, from: JSONSerialization.data(withJSONObject: json))
            XCTAssertEqual(restored.fieldInstitution.isMember, organization.id == "bank_of_russia", organization.name)
            if organization.id != "bank_of_russia" { XCTAssertNil(restored.fieldInstitution.reason) }
            XCTAssertEqual(restored.dto, original.dto)
            XCTAssertEqual(restored.organizationKey, original.organizationKey)
            XCTAssertEqual(restored.observationIDs, original.observationIDs)
            XCTAssertEqual(restored, try JSONDecoder().decode(TrudvsemVacancy.self, from: JSONEncoder().encode(restored)))
        }
    }

    @MainActor
    func testTrudFieldFilterResetsForEveryOtherOrganizationAndKeepsExportConsistent() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let values = try OrganizationRegistry.all.map { organization in
            let dto = try XCTUnwrap(TrudFixture.page([
                TrudFixture.row(organization.id, org: organization, title: "Кассир ПУ Инское")
            ]).vacancies.first)
            return TrudvsemVacancy(dto: dto, organization: organization, observationIDs: [])
        } + [try TrudFixture.documented("ordinary")]
        let store = TrudvsemSnapshotStore(configuredURL: directory.appendingPathComponent("trud.json"))
        try store.save(.init(version: 1, vacancies: values, metrics: [], updatedAt: .distantPast))
        let model = TrudvsemViewModel(client: TrudScriptedClient([]), store: store)
        model.load()
        for selection in ["all", "bank_of_russia"] {
            model.selectedEmployerID = selection
            XCTAssertTrue(model.isFieldInstitutionFilterAvailable)
            model.fieldInstitutionsOnly = true
            XCTAssertEqual(model.displayedResults.map(\.dto.id), ["bank_of_russia"])
            XCTAssertEqual(model.filters["Категория"], "Полевые учреждения")
            model.selectedRegionID = "missing"
            XCTAssertTrue(model.displayedResults.isEmpty)
            model.selectedRegionID = "all"
        }
        for organization in OrganizationRegistry.all where organization.id != "bank_of_russia" {
            model.selectedEmployerID = "all"
            model.fieldInstitutionsOnly = true
            model.selectedEmployerID = organization.id
            XCTAssertFalse(model.isFieldInstitutionFilterAvailable)
            XCTAssertFalse(model.fieldInstitutionsOnly)
            XCTAssertEqual(model.displayedResults.map(\.dto.id), [organization.id])
            model.fieldInstitutionsOnly = true
            XCTAssertFalse(model.fieldInstitutionsOnly)
            XCTAssertEqual(model.filters["Категория"], "Все вакансии")
            XCTAssertFalse(try XCTUnwrap(model.displayedResults.first).fieldInstitution.isMember)
        }
        model.selectedEmployerID = "bank_of_russia"
        XCTAssertTrue(model.isFieldInstitutionFilterAvailable)
        XCTAssertFalse(model.fieldInstitutionsOnly)
        XCTAssertEqual(Set(model.displayedResults.map(\.dto.id)), ["bank_of_russia", "ordinary"])
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
    func testTrudSnapshotCorruptionAndFailedWriteAreNotSilentlyAccepted() throws {
        let dir = temporaryDirectory(), url = dir.appendingPathComponent("snapshot.json")
        let bytes = Data("{bad".utf8); try bytes.write(to: url)
        let store = TrudvsemSnapshotStore(configuredURL: url)
        XCTAssertThrowsError(try store.load()); XCTAssertEqual(try Data(contentsOf: url), bytes)
        let invalidParent = dir.appendingPathComponent("not-a-directory"); try bytes.write(to: invalidParent)
        let failing = TrudvsemSnapshotStore(configuredURL: invalidParent.appendingPathComponent("snapshot.json"))
        XCTAssertThrowsError(try failing.save(.init(version: 1, vacancies: [], metrics: [], updatedAt: Date())))
    }
}
