import Foundation

protocol TrudvsemAPI: Sendable {
    func vacancies(inn: String, page: Int, limit: Int) async throws -> TrudvsemPage
}

/// Shared pacing uses elapsed time, so a clock adjustment cannot create a burst.
actor TrudvsemRequestGate {
    static let shared = TrudvsemRequestGate()
    private let minimumInterval: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let sleep: @Sendable (UInt64) async throws -> Void
    private var nextRequest: TimeInterval = 0
    private var cooldownUntil: TimeInterval = 0
    private var cooldownStatus = 429
    private var unavailableUntil: TimeInterval = 0
    private var networkFailure: URLError.Code = .timedOut

    init(minimumInterval: TimeInterval = 1.5,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.minimumInterval = max(0, minimumInterval)
        self.now = now
        self.sleep = sleep
    }

    func imposeCooldown(seconds: TimeInterval, status: Int) {
        let until = now() + max(0, seconds)
        if until > cooldownUntil { cooldownUntil = until; cooldownStatus = status }
    }

    /// A failed API connection affects every employer. Repeated refreshes must not
    /// start another full retry cycle until this short recovery window has passed.
    func recordNetworkFailure(_ code: URLError.Code) throws -> TrudvsemError {
        try Task.checkCancellation()
        unavailableUntil = now() + 30
        networkFailure = code
        return .network(code, retryAfter: 30)
    }

    func wait() async throws {
        while true {
            try Task.checkCancellation()
            let instant = now()
            if unavailableUntil > instant {
                throw TrudvsemError.network(networkFailure, retryAfter: Int(ceil(unavailableUntil - instant)))
            }
            let cooldown = cooldownUntil - instant
            // Retain long server embargoes across refreshes without holding the UI for minutes.
            guard cooldown.isFinite, cooldown <= 90 else { throw TrudvsemError.http(cooldownStatus) }
            let remaining = max(nextRequest, cooldownUntil) - instant
            if remaining <= 0 {
                nextRequest = instant + minimumInterval
                return
            }
            try await sleep(UInt64(ceil(remaining * 1_000_000_000)))
            // Recheck after suspension: other requests or server cooldowns may have moved the slot.
        }
    }
}

struct TrudvsemAPIClient: TrudvsemAPI, Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private let evidence: PDFSourceEvidence
    private let gate: TrudvsemRequestGate
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let maximumPageDuration: TimeInterval
    private static let transientURLErrorCodes: Set<URLError.Code> = [
        .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed
    ]
    private static let transientStatusCodes: Set<Int> = [408, 500, 502, 503, 504]
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 90
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
    init(evidence: PDFSourceEvidence = .shared, gate: TrudvsemRequestGate = .shared,
         sleep: @escaping @Sendable (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
         maximumPageDuration: TimeInterval = 90,
         transport: @escaping Transport = { request in
             let (data, response) = try await Self.session.data(for: request)
             guard let response = response as? HTTPURLResponse else { throw TrudvsemError.invalid("HTTP") }
             return (data, response)
         }) {
        precondition(maximumPageDuration.isFinite && maximumPageDuration > 0 && maximumPageDuration <= 3600)
        self.transport = transport; self.evidence = evidence; self.gate = gate; self.sleep = sleep
        self.maximumPageDuration = maximumPageDuration
    }
    static func url(inn: String, page: Int, limit: Int) throws -> URL {
        guard [10, 12].contains(inn.count), inn.allSatisfy(\.isNumber), page >= 0, (1...100).contains(limit) else { throw TrudvsemError.invalid("Параметры запроса") }
        var c = URLComponents(string: "https://opendata.trudvsem.ru/api/v1/vacancies/company/inn/\(inn)")!
        c.queryItems = [.init(name: "limit", value: String(limit)), .init(name: "offset", value: String(page))]
        guard let url = c.url else { throw TrudvsemError.invalid("URL") }; return url
    }
    func vacancies(inn: String, page: Int, limit: Int = 100) async throws -> TrudvsemPage {
        let url = try Self.url(inn: inn, page: page, limit: limit)
        do {
            // URLSession's request timeout resets when data arrives. A separate
            // deadline bounds the whole page, including pacing, retries and a
            // response that keeps trickling bytes without ever finishing.
            let reply = try await withThrowingTaskGroup(of: Reply.self) { group in
                group.addTask { try await response(for: url) }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(maximumPageDuration * 1_000_000_000))
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            try Task.checkCancellation()
            var result = try TrudvsemPage(data: reply.data)
            do {
                result.observationID = try evidence.capture(data: reply.data, url: url, status: reply.status,
                    sent: reply.sent, received: reply.received)?.id
            } catch {
                NSLog("Не удалось сохранить исходный ответ trudvsem.ru для PDF: %@", error.localizedDescription)
            }
            try Task.checkCancellation()
            return result
        } catch {
            // Cancellation wins even when it races with a timeout or a response.
            // It must never open the outage cooldown or be shown as a network error.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            if let error = error as? URLError {
                let failure = try await gate.recordNetworkFailure(error.code)
                throw failure
            }
            throw error
        }
    }

    private struct Reply: Sendable {
        let data: Data
        let status: Int
        let sent: Date
        let received: Date
    }

    private func response(for url: URL) async throws -> Reply {
        for attempt in 0..<3 {
            try await gate.wait()
            try Task.checkCancellation()
            var request = URLRequest(url: url); request.timeoutInterval = 30
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let sent = Date()
            do {
                let (data, response) = try await transport(request)
                if response.statusCode == 429 || Self.transientStatusCodes.contains(response.statusCode) {
                    let retry = max(pow(2, Double(attempt)), Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After"), now: Date()) ?? 0)
                    await gate.imposeCooldown(seconds: retry, status: response.statusCode)
                    try Task.checkCancellation()
                    guard attempt < 2, retry <= 90 else { throw TrudvsemError.http(response.statusCode) }
                    try await sleep(UInt64(ceil(retry * 1_000_000_000)))
                    continue
                }
                try Task.checkCancellation()
                guard (200...299).contains(response.statusCode) else { throw TrudvsemError.http(response.statusCode) }
                return Reply(data: data, status: response.statusCode, sent: sent, received: Date())
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch let error as URLError where Self.transientURLErrorCodes.contains(error.code) && attempt < 2 {
                try Task.checkCancellation()
                try await sleep(UInt64(pow(2, Double(attempt)) * 1_000_000_000))
            }
        }
        throw TrudvsemError.invalid("Повторы исчерпаны")
    }
    static func retryAfter(_ value: String?, now: Date) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        // An overflowing positive delay must stop requests, not fall back to a short retry.
        if let seconds = Double(value), !seconds.isNaN { return max(0, seconds) }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"; f.isLenient = false
        return f.date(from: value).map { max(0, $0.timeIntervalSince(now)) }
    }
}
