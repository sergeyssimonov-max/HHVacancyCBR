import Foundation

protocol TrudvsemAPI: Sendable {
    func vacancies(inn: String, page: Int, limit: Int) async throws -> TrudvsemPage
}

actor TrudvsemRequestGate {
    private var next = Date.distantPast
    func wait() async throws {
        let now = Date(), slot = max(Date(), next)
        next = slot.addingTimeInterval(1.5)
        if slot > now { try await Task.sleep(nanoseconds: UInt64(slot.timeIntervalSince(now) * 1_000_000_000)) }
        try Task.checkCancellation()
    }
}

struct TrudvsemAPIClient: TrudvsemAPI, Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private let evidence: PDFSourceEvidence
    private let gate: TrudvsemRequestGate
    private let sleep: @Sendable (UInt64) async throws -> Void
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 90
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    init(evidence: PDFSourceEvidence = .shared, gate: TrudvsemRequestGate = TrudvsemRequestGate(),
         sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
         transport: @escaping Transport = { request in
             let (data, response) = try await Self.session.data(for: request)
             guard let response = response as? HTTPURLResponse else { throw TrudvsemError.invalid("HTTP") }
             return (data, response)
         }) {
        self.transport = transport; self.evidence = evidence; self.gate = gate; self.sleep = sleep
    }
    static func url(inn: String, page: Int, limit: Int) throws -> URL {
        guard [10, 12].contains(inn.count), inn.allSatisfy(\.isNumber), page >= 0, (1...100).contains(limit) else { throw TrudvsemError.invalid("Параметры запроса") }
        var c = URLComponents(string: "https://opendata.trudvsem.ru/api/v1/vacancies/company/inn/\(inn)")!
        c.queryItems = [.init(name: "limit", value: String(limit)), .init(name: "offset", value: String(page))]
        guard let url = c.url else { throw TrudvsemError.invalid("URL") }; return url
    }
    func vacancies(inn: String, page: Int, limit: Int = 100) async throws -> TrudvsemPage {
        let url = try Self.url(inn: inn, page: page, limit: limit)
        for attempt in 0..<3 {
            try await gate.wait()
            var request = URLRequest(url: url); request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let sent = Date()
            do {
                let (data, response) = try await transport(request)
                try Task.checkCancellation()
                if response.statusCode == 429 || (500...599).contains(response.statusCode) {
                    guard attempt < 2 else { throw TrudvsemError.http(response.statusCode) }
                    let retry = Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: Date()) ?? pow(2, Double(attempt))
                    // Long Retry-After is reported rather than retried earlier than the server allows.
                    guard retry <= 90 else { throw TrudvsemError.http(response.statusCode) }
                    try await sleep(UInt64(max(0, retry) * 1_000_000_000)); continue
                }
                guard (200...299).contains(response.statusCode) else { throw TrudvsemError.http(response.statusCode) }
                var page = try TrudvsemPage(data: data)
                page.observationID = try evidence.capture(data: data, url: url, status: response.statusCode, sent: sent, received: Date())?.id
                return page
            } catch let error as URLError where [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(error.code) && attempt < 2 {
                try await sleep(UInt64(pow(2, Double(attempt)) * 1_000_000_000))
            }
        }
        throw TrudvsemError.invalid("Повторы исчерпаны")
    }
    static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value else { return nil }
        if let seconds = Double(value), seconds.isFinite { return max(0, seconds) }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return f.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}

struct TrudvsemCollection: Sendable {
    struct Metrics: Codable, Sendable {
        let organizationKey: String
        let declared: Int
        let received: Int
        let unique: Int
        let pages: Int
    }
    let vacancies: [TrudvsemVacancy]
    let metrics: [Metrics]
    let issues: [String]
    var isComplete: Bool { issues.isEmpty }
}

struct TrudvsemCollectionService: Sendable {
    let client: any TrudvsemAPI
    var pageSize = 100
    var maximumDuration: TimeInterval = 15 * 60
    func collect(organizations: [Organization] = OrganizationRegistry.all,
                 progress: @escaping @MainActor @Sendable (String) -> Void) async throws -> TrudvsemCollection {
        let started = Date()
        var all: [TrudvsemVacancy] = [], metrics: [TrudvsemCollection.Metrics] = [], issues: [String] = []
        for organization in organizations {
            var pageIndex = 0, received = 0, expected: Int?, values: [String: TrudvsemVacancy] = [:]
            var fingerprints = Set<String>()
            do {
                while true {
                    try Task.checkCancellation()
                    guard Date().timeIntervalSince(started) < maximumDuration else { throw TrudvsemError.incomplete("Истекло время сбора") }
                    let page = try await client.vacancies(inn: organization.inn, page: pageIndex, limit: pageSize)
                    try Task.checkCancellation()
                    if let expected, expected != page.total { throw TrudvsemError.incomplete("meta.total изменился для \(organization.name)") }
                    expected = page.total; received += page.receivedCount; pageIndex += 1
                    guard page.malformedCount == 0 else { throw TrudvsemError.incomplete("Повреждённых записей: \(page.malformedCount)") }
                    let fingerprint = page.vacancies.map { $0.companyCode + ":" + $0.id }.sorted().joined(separator: "|")
                    if !page.vacancies.isEmpty && !fingerprints.insert(fingerprint).inserted { throw TrudvsemError.incomplete("Повторяющаяся страница") }
                    let priorCount = values.count
                    for dto in page.vacancies {
                        let company = dto.raw["company"]
                        // INN-route alone is not enough: reject mismatched legal identity.
                        guard company["inn"].text == organization.inn,
                              company["ogrn"].text == nil || company["ogrn"].text == organization.ogrn else { throw TrudvsemError.incomplete("Чужой или неподтверждённый работодатель") }
                        var value = TrudvsemVacancy(dto: dto, organization: organization, observationIDs: [page.observationID].compactMap { $0 })
                        value.observationIDs = Array(Set(value.observationIDs + (values[value.id]?.observationIDs ?? []))).sorted()
                        values[value.id] = value
                    }
                    await progress("\(organization.name): \(values.count) из \(page.total), страниц: \(pageIndex)")
                    if values.count == page.total { break }
                    guard values.count < page.total, !page.vacancies.isEmpty, values.count > priorCount else { throw TrudvsemError.incomplete("Число уникальных вакансий не совпадает с meta.total") }
                }
            } catch is CancellationError { throw CancellationError() }
            catch { issues.append("\(organization.name): \(error.localizedDescription)") }
            metrics.append(.init(organizationKey: organization.id, declared: expected ?? 0, received: received, unique: values.count, pages: pageIndex))
            all += values.values.sorted { $0.id < $1.id }
        }
        return .init(vacancies: all, metrics: metrics, issues: issues)
    }
}
