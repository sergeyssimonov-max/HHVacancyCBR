import AppKit
import Foundation
import PDFKit
import XCTest
import SwiftUI
@testable import HHVacancyCBR

extension HHVacancyCBRTests {

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
}
