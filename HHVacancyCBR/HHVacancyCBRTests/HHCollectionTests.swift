import AppKit
import Foundation
import PDFKit
import XCTest
import SwiftUI
@testable import HHVacancyCBR

extension HHVacancyCBRTests {



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
}
