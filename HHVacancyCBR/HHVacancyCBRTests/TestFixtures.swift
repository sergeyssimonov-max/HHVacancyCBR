import AppKit
import Foundation
import PDFKit
import XCTest
import SwiftUI
@testable import HHVacancyCBR


struct TestEmployerStore: EmployerConfigurationStoring {
    let entries: [EmployerConfigurationEntry]
    func loadOrCreate() throws -> EmployerConfiguration {
        try EmployerConfiguration(version: 1, employers: entries).validated()
    }
}

struct CancelledAreaClient: HHVacancyAPIClient {
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

actor EmployerScriptedClient: HHVacancyAPIClient {
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

actor MockAPIClient: HHVacancyAPIClient {
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

struct FixedTokenProvider: HHAccessTokenProviding {
    let accessToken: String? = "unit-token"
}

@MainActor
final class PDFEnrichmentExporter: VacanciesPDFExporting {
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

struct FixedSummaryAPIClient: HHVacancyAPIClient {
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

actor PDFEnrichmentClient: HHVacancyAPIClient {
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

actor TestAsyncSignal {
    private var signalled = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { if !signalled { await withCheckedContinuation { waiter = $0 } } }
    func signal() { signalled = true; waiter?.resume(); waiter = nil }
}

actor ConcurrentOperationTracker {
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

actor RetryWaitRecorder {
    var values: [UInt64] = []
    func append(_ value: UInt64) { values.append(value) }
}

enum HTTPClientFactory {
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

final class URLProtocolStub: URLProtocol {
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


enum LiveCancellationTransition: Int {
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
final class LiveCancellationRun {
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
final class AuditClock: @unchecked Sendable {
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

actor FieldSearchClient: HHVacancyAPIClient {
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

// Independent-source regression fixtures. These bytes are synthetic test data, never live evidence.
enum TrudFixture {
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
actor TrudScriptedClient: TrudvsemAPI {
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

func documentedTestSummary(_ input: HHVacancySummary) -> HHVacancySummary {
    var value = input
    let bytes = try! JSONEncoder().encode(input)
    value.observationID = try! PDFSourceEvidence.shared.capture(data: bytes,
        url: URL(string: "https://api.hh.ru/vacancies/" + input.id)!, status: 200, sent: Date(), received: Date())!.id
    return value
}

func isolatedTrudGate() -> TrudvsemRequestGate {
    let clock = AuditClock()
    return TrudvsemRequestGate(now: { clock.now }, sleep: { clock.advance(Double($0) / 1e9) })
}

actor TrudTransportScript {
    enum Step: Sendable {
        case network(URLError.Code)
        case http(Int, retryAfter: String? = nil)
        case success(Data)
    }
    private let steps: [Step]
    private(set) var requests: [URLRequest] = []
    init(_ steps: [Step]) { self.steps = steps }
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let index = requests.count
        requests.append(request)
        let step = index < steps.count ? steps[index] : .success(try TrudFixture.data([]))
        switch step {
        case .network(let code): throw URLError(code)
        case .http(let status, let retryAfter):
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                headerFields: retryAfter.map { ["Retry-After": $0] })!)
        case .success(let data):
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
    }
}

/// Exercises Foundation's real async URLSession cancellation without a live server.
final class TrudHangingURLProtocol: URLProtocol {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var started = 0
        var stopped = 0
    }
    private static let state = State()
    static var counts: (started: Int, stopped: Int) {
        state.lock.lock(); defer { state.lock.unlock() }
        return (state.started, state.stopped)
    }
    static func reset() {
        state.lock.lock(); defer { state.lock.unlock() }
        state.started = 0; state.stopped = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.lock.lock(); defer { Self.state.lock.unlock() }
        Self.state.started += 1
    }
    override func stopLoading() {
        Self.state.lock.lock(); defer { Self.state.lock.unlock() }
        Self.state.stopped += 1
    }
}
