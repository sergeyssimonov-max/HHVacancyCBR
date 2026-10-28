import AppKit
import Foundation
import PDFKit

/// Offline checks use the production implementation without the Xcode test service.
enum ReliabilityChecks {
    @MainActor static func run(directory: URL) async throws {
        precondition(TrudvsemAPIClient.retryAfter(String(repeating: "9", count: 400), now: Date()) == .infinity)
        let clock = CheckClock()
        let gate = TrudvsemRequestGate(now: { clock.now }, sleep: { clock.advance(Double($0) / 1e9) })
        let counter = CheckCounter()
        let empty = Data(#"{"status":"200","meta":{"total":0},"results":{"vacancies":[]}}"#.utf8)
        let transport: TrudvsemAPIClient.Transport = { request in
            let call = await counter.next()
            return (empty, HTTPURLResponse(url: request.url!, statusCode: call == 1 ? 429 : 200,
                httpVersion: nil, headerFields: ["Retry-After": "120"])!)
        }
        for _ in 0..<2 {
            do {
                _ = try await TrudvsemAPIClient(gate: gate, transport: transport).vacancies(inn: "7702235133", page: 0)
                preconditionFailure("Server embargo was ignored")
            } catch TrudvsemError.http(429) { }
        }
        let blockedCalls = await counter.count
        precondition(blockedCalls == 1)
        clock.advance(120)
        _ = try await TrudvsemAPIClient(gate: gate, transport: transport).vacancies(inn: "7702235133", page: 0)
        let recoveredCalls = await counter.count
        precondition(recoveredCalls == 2)

        let cancelled = TrudvsemAPIClient(gate: TrudvsemRequestGate(minimumInterval: 0), transport: { _ in throw URLError(.cancelled) })
        do {
            _ = try await cancelled.vacancies(inn: "7702235133", page: 0)
            preconditionFailure("Cancellation was swallowed")
        } catch is CancellationError { }

        for status in [401, 403, 429] {
            let client = CheckRestrictedClient(status: status)
            do {
                _ = try await TrudvsemCollectionService(client: client).collect { _ in }
                preconditionFailure("Collection continued after restriction")
            } catch TrudvsemError.http(let actual) { precondition(actual == status) }
            let calls = await client.calls
            precondition(calls == 1)
        }

        let client = CheckPageClient()
        let collection = try await TrudvsemCollectionService(client: client, maximumPagesPerEmployer: 2)
            .collect(organizations: [OrganizationRegistry.all[0]]) { _ in }
        let pagesRequested = await client.calls
        precondition(pagesRequested == 2 && !collection.isComplete)
        let expired = CheckPageClient()
        do {
            _ = try await TrudvsemCollectionService(client: expired, maximumDuration: 0).collect { _ in }
            preconditionFailure("Collection ignored its deadline")
        } catch TrudvsemError.incomplete { }
        let expiredCalls = await expired.calls
        precondition(expiredCalls == 0)

        // Repeated cancellation must neither hang the queue nor leak its permit.
        try await VacancyRefreshScheduler.acquire()
        for _ in 0..<30 {
            let task = Task { try await VacancyRefreshScheduler.acquire(); VacancyRefreshScheduler.release() }
            task.cancel()
            do { try await task.value; preconditionFailure("Cancelled waiter acquired permit") }
            catch is CancellationError { }
        }
        VacancyRefreshScheduler.release()
        try await VacancyRefreshScheduler.acquire()
        VacancyRefreshScheduler.release()

        let paragraph = (0..<1200).map { "Paragraph \($0): Unicode Ω, long text for pagination.\n" }.joined()
        let text = NSAttributedString(string: paragraph, attributes: [.font: VacancyPDFStyle.bodyFont])
        let pages = VacanciesPDFExporter.pages(for: text)
        precondition(pages.count > 1 && pages.map { $0.content.string }.joined() == paragraph)
        let link = URL(string: "https://example.com/vacancy/1")!
        let linked = NSAttributedString(string: "Clickable vacancy", attributes: [.font: VacancyPDFStyle.bodyFont, .link: link])
        let plain = NSAttributedString(string: "Plain description", attributes: [.font: VacancyPDFStyle.bodyFont])
        let rendered = try VacanciesPDFExporter.pdfData(for: [.init(content: linked), .init(content: plain)])
        let pdf = PDFDocument(data: rendered)!
        precondition(pdf.pageCount == 2 && pdf.page(at: 0)!.annotations.contains { $0.url == link })
        precondition(pdf.page(at: 1)!.annotations.isEmpty && pdf.string!.contains("Plain description"))

        // All three Trudvsem modes keep the exact original response embedded.
        let data = CheckPageClient.bytes(page: 0, total: 1)
        let url = try TrudvsemAPIClient.url(inn: "7702235133", page: 0, limit: 100)
        let record = try PDFSourceEvidence.shared.capture(data: data, url: url, status: 200, sent: Date(), received: Date())!
        let dto = try TrudvsemPage(data: data).vacancies[0]
        let vacancy = TrudvsemVacancy(dto: dto, organization: OrganizationRegistry.all[0], observationIDs: [record.id])
        let worker = PDFExportWorker()
        try await worker.exportTrudvsemPersonal(vacancy: vacancy, destination: directory.appendingPathComponent("personal.pdf"))
        try await worker.exportTrudvsemStatistics(vacancies: [vacancy], filters: [:], destination: directory.appendingPathComponent("statistics.pdf"))
        let prepared = try await worker.prepareTrudvsem(vacancies: [vacancy]) { _ in }
        let names = (0..<prepared.partCount).map { "bulk-\($0).pdf" }
        let written = try await worker.writePrepared(names: names, directory: directory)
        for file in written + [directory.appendingPathComponent("personal.pdf"), directory.appendingPathComponent("statistics.pdf")] {
            let bytes = try Data(contentsOf: file)
            precondition(bytes.range(of: data) != nil)
            precondition(PDFDocument(data: bytes)!.pageCount > 0)
        }
        let responseFile = try PDFSourceEvidence.shared.root.appendingPathComponent("observations/\(record.id)/response.json")
        try Data("corrupted".utf8).write(to: responseFile)
        defer { try? data.write(to: responseFile) }
        let degraded = try await worker.prepareTrudvsem(vacancies: [vacancy]) { _ in }
        precondition(degraded.partCount > 0)
        print("Offline reliability checks: cooldown, cancellation, restrictions, page/time budgets, scheduler, pagination, links, three PDF modes, evidence integrity: OK")
    }
}

private final class CheckClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0.0
    var now: Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; value += seconds }
}
private actor CheckCounter {
    var count = 0
    func next() -> Int { count += 1; return count }
}
private actor CheckRestrictedClient: TrudvsemAPI {
    let status: Int
    var calls = 0
    init(status: Int) { self.status = status }
    func vacancies(inn: String, page: Int, limit: Int) async throws -> TrudvsemPage {
        calls += 1
        throw TrudvsemError.http(status)
    }
}
private actor CheckPageClient: TrudvsemAPI {
    var calls = 0
    static func bytes(page: Int, total: Int = 100) -> Data {
        Data("""
        {"status":"200","meta":{"total":\(total)},"results":{"vacancies":[{"vacancy":{"id":"\(page)","job-name":"Vacancy \(page)","company":{"companycode":"division","inn":"7702235133","ogrn":"1037700013020"},"duty":"Description"}}]}}
        """.utf8)
    }
    func vacancies(inn: String, page: Int, limit: Int) async throws -> TrudvsemPage {
        calls += 1
        return try TrudvsemPage(data: Self.bytes(page: page))
    }
}
