import AppKit
import Foundation
import PDFKit
import XCTest
import SwiftUI
@testable import HHVacancyCBR

extension HHVacancyCBRTests {

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

    @MainActor
    func testOptInTrudLiveRefreshPersistsAllSixEmployers() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["HHVACANCYCBR_RUN_TRUD_LIVE"] == "1",
            "Opt-in real trudvsem.ru refresh; set HHVACANCYCBR_RUN_TRUD_LIVE=1. Maximum 24 HTTP attempts.")
        actor Journal {
            private var attempts = 0
            func begin(_ request: URLRequest) throws {
                guard attempts < 24 else { throw TrudvsemError.incomplete("Live diagnostic request budget exhausted") }
                attempts += 1
                print("TRUD LIVE attempt=\(attempts) GET \(request.url!.absoluteString)")
            }
            func finish(status: Int, bytes: Int, duration: TimeInterval) {
                print("TRUD LIVE status=\(status) bytes=\(bytes) seconds=\(String(format: "%.3f", duration))")
            }
        }
        let journal = Journal()
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let evidence = PDFSourceEvidence(root: directory.appendingPathComponent("evidence"))
        let client = TrudvsemAPIClient(evidence: evidence, transport: { request in
            try await journal.begin(request)
            let started = ProcessInfo.processInfo.systemUptime
            let (data, response) = try await TrudvsemAPIClient.session.data(for: request)
            guard let response = response as? HTTPURLResponse else { throw TrudvsemError.invalid("HTTP") }
            await journal.finish(status: response.statusCode, bytes: data.count,
                duration: ProcessInfo.processInfo.systemUptime - started)
            return (data, response)
        })
        let store = TrudvsemSnapshotStore(configuredURL: directory.appendingPathComponent("vacancies-trudvsem.json"))
        let model = TrudvsemViewModel(client: client, store: store)
        model.load()
        let started = Date()
        await model.refresh()
        XCTAssertNil(model.errorMessage, model.errorMessage ?? "")
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.collectionIssues.isEmpty)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(model.updatedAt), started)
        XCTAssertEqual(Set(model.metrics.map(\.organizationKey)), Set(OrganizationRegistry.available(on: .trudvsem).map(\.id)))
        XCTAssertTrue(model.metrics.allSatisfy { $0.declared == $0.unique })
        XCTAssertEqual(model.metrics.reduce(0) { $0 + $1.unique }, model.results.count)
        XCTAssertFalse(model.results.isEmpty, "The live collection must contain actual vacancies")
        let snapshot = try XCTUnwrap(store.load())
        XCTAssertEqual(snapshot.vacancies, model.results)
        XCTAssertEqual(snapshot.updatedAt, model.updatedAt)
        for value in model.results {
            XCTAssertFalse(value.observationIDs.isEmpty)
            for observation in value.observationIDs { _ = try evidence.observation(observation) }
        }
        for metric in model.metrics {
            print("TRUD LIVE employer=\(metric.organizationKey) declared=\(metric.declared) unique=\(metric.unique) pages=\(metric.pages)")
        }
        print("TRUD LIVE persisted=\(snapshot.vacancies.count) updatedAt=\(ISO8601DateFormatter().string(from: snapshot.updatedAt))")
        // The persisted result remains usable without issuing another network request.
        let offline = TrudvsemViewModel(client: TrudScriptedClient([try TrudFixture.page([])]), store: store)
        offline.load()
        XCTAssertEqual(offline.results, model.results)
        XCTAssertEqual(offline.updatedAt, model.updatedAt)
    }
}
