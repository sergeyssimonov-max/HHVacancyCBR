import AppKit
import Foundation
import PDFKit
import XCTest
import SwiftUI
@testable import HHVacancyCBR

extension HHVacancyCBRTests {
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
        catch { guard case TrudvsemError.network(.timedOut, _) = error else { return XCTFail("Unexpected error: \(error)") } }
        let waiting = TrudvsemAPIClient(gate: isolatedTrudGate(), transport: { _ in try await Task.sleep(nanoseconds: 30_000_000_000); throw CancellationError() })
        let task = Task { try await waiting.vacancies(inn: TrudFixture.bank.inn, page: 0) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTrudOutageStopsAfterOneEmployerRetryBudget() async throws {
        actor Requests {
            var inns: [String] = []
            func record(_ url: URL) { inns.append(url.lastPathComponent) }
        }
        let requests = Requests()
        let client = TrudvsemAPIClient(gate: isolatedTrudGate(), sleep: { _ in }, transport: { request in
            await requests.record(request.url!)
            throw URLError(.timedOut)
        })
        do {
            _ = try await TrudvsemCollectionService(client: client).collect { _ in }
            XCTFail("An unreachable API must stop the collection, not repeat the outage for every employer")
        } catch { XCTAssertFalse(error is CancellationError) }
        let inns = await requests.inns
        XCTAssertEqual(inns.count, 3, "One shared outage must not cause 18 timed-out requests")
        XCTAssertEqual(Set(inns), [TrudFixture.bank.inn])
    }

    @MainActor
    func testTrudIncompleteRefreshPreservesPublishedMetricsAndSnapshotBytes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrudvsemSnapshotStore(configuredURL: directory.appendingPathComponent("trud.json"))
        let value = try TrudFixture.documented("retained")
        let metrics: [TrudvsemCollection.Metrics] = [.init(organizationKey: TrudFixture.bank.id,
            declared: 1, received: 1, unique: 1, pages: 1)]
        try store.save(.init(version: 1, vacancies: [value], metrics: metrics, updatedAt: .distantPast))
        let bytes = try Data(contentsOf: store.url)
        let model = TrudvsemViewModel(client: TrudScriptedClient([try TrudFixture.page([], total: 2)]), store: store)
        model.load()
        await model.refresh()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.results, [value])
        XCTAssertEqual(model.updatedAt, .distantPast)
        XCTAssertEqual(model.metrics.map(\.organizationKey), metrics.map(\.organizationKey))
        XCTAssertEqual(model.metrics.map(\.unique), [1])
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
    }

    func testTrudTransientNetworkErrorsRecoverWithinTheSameRefresh() async throws {
        for code in [URLError.Code.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed] {
            let script = TrudTransportScript([.network(code), .network(code)])
            let evidence = PDFSourceEvidence(root: temporaryDirectory())
            let client = TrudvsemAPIClient(evidence: evidence, gate: isolatedTrudGate(), sleep: { _ in }, transport: { try await script.send($0) })
            let result = try await TrudvsemCollectionService(client: client).collect { _ in }
            XCTAssertTrue(result.isComplete, "\(code)")
            XCTAssertEqual(result.metrics.count, 6)
            let requests = await script.requests
            XCTAssertEqual(requests.count, 8)
            XCTAssertEqual(requests.prefix(3).map { $0.url!.lastPathComponent }, Array(repeating: TrudFixture.bank.inn, count: 3))
            XCTAssertTrue(requests.allSatisfy { $0.url?.scheme == "https" && $0.timeoutInterval == 30 })
        }
    }

    func testTrudMixedHTTPAndNetworkFailuresShareOneRetryBudget() async throws {
        let script = TrudTransportScript([.network(.timedOut), .http(503), .network(.networkConnectionLost)])
        let client = TrudvsemAPIClient(gate: isolatedTrudGate(), sleep: { _ in }, transport: { try await script.send($0) })
        do { _ = try await TrudvsemCollectionService(client: client).collect { _ in }; XCTFail("Expected outage") }
        catch { guard case TrudvsemError.network(.networkConnectionLost, _) = error else { return XCTFail("\(error)") } }
        let requests = await script.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(Set(requests.map { $0.url!.lastPathComponent }), [TrudFixture.bank.inn])
    }

    func testTrudServerFailuresStopCollectionAfterBoundedRetries() async throws {
        for status in [408, 429, 500, 502, 503, 504] {
            let script = TrudTransportScript(Array(repeating: .http(status), count: 3))
            let client = TrudvsemAPIClient(gate: isolatedTrudGate(), sleep: { _ in }, transport: { try await script.send($0) })
            do { _ = try await TrudvsemCollectionService(client: client).collect { _ in }; XCTFail("Expected HTTP \(status)") }
            catch { guard case TrudvsemError.http(status) = error else { return XCTFail("\(error)") } }
            let requests = await script.requests
            XCTAssertEqual(requests.count, 3)
        }
    }

    func testTrudOfflineAndCertificateFailuresAreNotRetried() async throws {
        for code in [URLError.Code.notConnectedToInternet, .secureConnectionFailed, .serverCertificateUntrusted] {
            let script = TrudTransportScript([.network(code)])
            let client = TrudvsemAPIClient(gate: isolatedTrudGate(), sleep: { _ in }, transport: { try await script.send($0) })
            do { _ = try await TrudvsemCollectionService(client: client).collect { _ in }; XCTFail("Expected failure") }
            catch { guard case TrudvsemError.network(code, _) = error else { return XCTFail("\(error)") } }
            let requests = await script.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testTrudOutageCooldownSurvivesNewClientAndDoesNotExtendOnBlockedRefresh() async throws {
        let clock = AuditClock()
        let gate = TrudvsemRequestGate(minimumInterval: 0, now: { clock.now }, sleep: { clock.advance(Double($0) / 1e9) })
        let script = TrudTransportScript(Array(repeating: .network(.timedOut), count: 3))
        let first = TrudvsemAPIClient(gate: gate, sleep: { _ in }, transport: { try await script.send($0) })
        let second = TrudvsemAPIClient(evidence: PDFSourceEvidence(root: temporaryDirectory()), gate: gate, transport: { try await script.send($0) })
        do { _ = try await first.vacancies(inn: TrudFixture.bank.inn, page: 0); XCTFail("Expected failure") } catch { }
        for remaining in [30, 1] {
            if remaining == 1 { clock.advance(29) }
            do { _ = try await second.vacancies(inn: OrganizationRegistry.all[1].inn, page: 0); XCTFail("Expected cooldown") }
            catch { guard case TrudvsemError.network(.timedOut, retryAfter: remaining) = error else { return XCTFail("\(error)") } }
        }
        let blocked = await script.requests.count
        XCTAssertEqual(blocked, 3)
        clock.advance(1)
        let result = try await TrudvsemCollectionService(client: second).collect { _ in }
        XCTAssertTrue(result.isComplete)
        let recovered = await script.requests.count
        XCTAssertEqual(recovered, 9, "Recovery must permit all six employers without restarting the app")
    }

    func testTrudPageDeadlineCancelsActualURLSessionTask() async throws {
        TrudHangingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrudHangingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = TrudvsemAPIClient(gate: TrudvsemRequestGate(minimumInterval: 0), maximumPageDuration: 0.15, transport: { request in
            let (data, response) = try await session.data(for: request)
            return (data, response as! HTTPURLResponse)
        })
        let started = ProcessInfo.processInfo.systemUptime
        do { _ = try await client.vacancies(inn: TrudFixture.bank.inn, page: 0); XCTFail("Expected deadline") }
        catch { guard case TrudvsemError.network(.timedOut, _) = error else { return XCTFail("\(error)") } }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - started, 2)
        // URLSession cancellation delivery can finish on its delegate queue after data(for:) resumes.
        for _ in 0..<100 where TrudHangingURLProtocol.counts.stopped == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(TrudHangingURLProtocol.counts.started, 1)
        XCTAssertEqual(TrudHangingURLProtocol.counts.stopped, 1)
    }

    func testTrudPageDeadlineIncludesRetryAfterAndPreservesServerEmbargo() async throws {
        let clock = AuditClock()
        let gate = TrudvsemRequestGate(minimumInterval: 0, now: { clock.now })
        let script = TrudTransportScript([.http(503, retryAfter: "60")])
        let client = TrudvsemAPIClient(gate: gate, maximumPageDuration: 0.05, transport: { try await script.send($0) })
        do { _ = try await client.vacancies(inn: TrudFixture.bank.inn, page: 0); XCTFail("Expected deadline during backoff") }
        catch { guard case TrudvsemError.network(.timedOut, _) = error else { return XCTFail("\(error)") } }
        clock.advance(30)
        do { _ = try await client.vacancies(inn: TrudFixture.bank.inn, page: 0); XCTFail("Server embargo is still active") }
        catch { guard case TrudvsemError.network(.timedOut, _) = error else { return XCTFail("\(error)") } }
        let requests = await script.requests
        XCTAssertEqual(requests.count, 1, "Neither the page deadline nor the network cooldown may shorten Retry-After")
    }

    func testTrudCancellationDuringBackoffDoesNotPoisonNextRefresh() async throws {
        let beganBackoff = expectation(description: "Backoff began")
        let gate = TrudvsemRequestGate(minimumInterval: 0)
        let script = TrudTransportScript([.network(.timedOut)])
        let first = TrudvsemAPIClient(gate: gate, sleep: { _ in
            beganBackoff.fulfill()
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }, transport: { try await script.send($0) })
        let task = Task { try await first.vacancies(inn: TrudFixture.bank.inn, page: 0) }
        await fulfillment(of: [beganBackoff], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let second = TrudvsemAPIClient(evidence: PDFSourceEvidence(root: temporaryDirectory()), gate: gate, transport: { try await script.send($0) })
        _ = try await second.vacancies(inn: TrudFixture.bank.inn, page: 0)
        let requests = await script.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testTrudCancellationOfActiveURLSessionStopsTaskWithoutOutageCooldown() async throws {
        TrudHangingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TrudHangingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let gate = TrudvsemRequestGate(minimumInterval: 0)
        let client = TrudvsemAPIClient(gate: gate, transport: { request in
            let (data, response) = try await session.data(for: request)
            return (data, response as! HTTPURLResponse)
        })
        let task = Task { try await client.vacancies(inn: TrudFixture.bank.inn, page: 0) }
        for _ in 0..<1000 where TrudHangingURLProtocol.counts.started == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(TrudHangingURLProtocol.counts.started, 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        for _ in 0..<100 where TrudHangingURLProtocol.counts.stopped == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(TrudHangingURLProtocol.counts.stopped, 1)
        // No cooldown after a user cancellation.
        try await gate.wait()
    }

    @MainActor
    func testTrudTimeoutPreservesOfflineSnapshotThenRecoversAtomically() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrudvsemSnapshotStore(configuredURL: directory.appendingPathComponent("trud.json"))
        let value = try TrudFixture.documented("offline")
        let metrics: [TrudvsemCollection.Metrics] = [.init(organizationKey: TrudFixture.bank.id, declared: 1, received: 1, unique: 1, pages: 1)]
        try store.save(.init(version: 1, vacancies: [value], metrics: metrics, updatedAt: .distantPast))
        let bytes = try Data(contentsOf: store.url)
        let script = TrudTransportScript(Array(repeating: .network(.timedOut), count: 3))
        let clock = AuditClock()
        let gate = TrudvsemRequestGate(minimumInterval: 0, now: { clock.now })
        let client = TrudvsemAPIClient(evidence: PDFSourceEvidence(root: directory.appendingPathComponent("evidence")),
            gate: gate, sleep: { _ in }, transport: { try await script.send($0) })
        let model = TrudvsemViewModel(client: client, store: store)
        model.load()
        model.selectedEmployerID = TrudFixture.bank.id
        model.searchDraft = value.title; model.applySearch()
        let visible = model.displayedResults
        for _ in 0..<2 {
            await model.refresh()
            XCTAssertFalse(model.isLoading)
            XCTAssertNil(model.currentEmployerName)
            XCTAssertEqual(model.results, [value])
            XCTAssertEqual(model.displayedResults, visible)
            XCTAssertEqual(model.updatedAt, .distantPast)
            XCTAssertEqual(model.metrics.map(\.unique), [1])
            XCTAssertEqual(try Data(contentsOf: store.url), bytes)
            XCTAssertTrue(model.errorMessage?.contains("не ответил вовремя") == true)
            XCTAssertTrue(model.errorMessage?.contains("дата обновления не изменилась") == true)
            XCTAssertFalse(model.errorMessage?.contains("The request timed out") == true)
            XCTAssertTrue(model.collectionIssues.isEmpty)
        }
        let blockedRequests = await script.requests.count
        XCTAssertEqual(blockedRequests, 3)
        clock.advance(30)
        await model.refresh()
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNotEqual(model.updatedAt, .distantPast)
        XCTAssertEqual(model.metrics.count, 6)
        XCTAssertEqual(try store.load()?.vacancies, [])
        XCTAssertEqual(model.selectedEmployerID, TrudFixture.bank.id)
        XCTAssertEqual(model.searchText, value.title)
    }

    @MainActor
    func testTrudFailureOnLaterEmployerNeverPublishesEarlierPages() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrudvsemSnapshotStore(configuredURL: directory.appendingPathComponent("trud.json"))
        let old = try TrudFixture.documented("old")
        try store.save(.init(version: 1, vacancies: [old], metrics: [], updatedAt: .distantPast))
        let bytes = try Data(contentsOf: store.url)
        let firstPage = try TrudFixture.data([TrudFixture.row("new")])
        let script = TrudTransportScript([.success(firstPage)] + Array(repeating: .network(.timedOut), count: 3))
        let client = TrudvsemAPIClient(evidence: PDFSourceEvidence(root: directory.appendingPathComponent("evidence")),
            gate: isolatedTrudGate(), sleep: { _ in }, transport: { try await script.send($0) })
        let model = TrudvsemViewModel(client: client, store: store)
        model.load(); await model.refresh()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.results, [old])
        XCTAssertEqual(model.updatedAt, .distantPast)
        XCTAssertEqual(try Data(contentsOf: store.url), bytes)
        let requests = await script.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.map { $0.url!.lastPathComponent }, [TrudFixture.bank.inn] + Array(repeating: OrganizationRegistry.all[1].inn, count: 3))
    }

    @MainActor
    func testTrudFirstRunOutageDoesNotClaimSavedDataOrCreateSnapshot() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrudvsemSnapshotStore(configuredURL: directory.appendingPathComponent("trud.json"))
        let script = TrudTransportScript([.network(.notConnectedToInternet)])
        let model = TrudvsemViewModel(client: TrudvsemAPIClient(gate: isolatedTrudGate(), transport: { try await script.send($0) }), store: store)
        model.load(); await model.refresh()
        XCTAssertNil(model.updatedAt)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(try store.load())
        XCTAssertTrue(model.errorMessage?.contains("Полная выборка ещё не загружена") == true)
        XCTAssertFalse(model.errorMessage?.contains("сохранённая") == true)
    }
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
}
