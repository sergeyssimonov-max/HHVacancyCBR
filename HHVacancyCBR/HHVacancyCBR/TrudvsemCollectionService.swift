import Foundation

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
    var maximumPagesPerEmployer = 500
    var now: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    func collect(organizations: [Organization] = OrganizationRegistry.available(on: .trudvsem),
                 progress: @escaping @MainActor @Sendable (String) -> Void) async throws -> TrudvsemCollection {
        let started = now()
        var all: [TrudvsemVacancy] = [], metrics: [TrudvsemCollection.Metrics] = [], issues: [String] = []
        for organization in organizations {
            try Task.checkCancellation()
            guard now() - started < maximumDuration else { throw TrudvsemError.incomplete("Истекло время сбора") }
            await progress(organization.name)
            var pageIndex = 0, received = 0, expected: Int?, values: [String: TrudvsemVacancy] = [:]
            var fingerprints = Set<String>()
            do {
                while true {
                    try Task.checkCancellation()
                    guard now() - started < maximumDuration else { throw TrudvsemError.incomplete("Истекло время сбора") }
                    guard pageIndex < maximumPagesPerEmployer else { throw TrudvsemError.incomplete("Превышен лимит страниц работодателя") }
                    let page = try await client.vacancies(inn: organization.inn, page: pageIndex, limit: pageSize)
                    try Task.checkCancellation()
                    guard now() - started < maximumDuration else { throw TrudvsemError.incomplete("Истекло время сбора") }
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
                    if values.count == page.total { break }
                    guard values.count < page.total, !page.vacancies.isEmpty, values.count > priorCount else { throw TrudvsemError.incomplete("Число уникальных вакансий не совпадает с meta.total") }
                }
            } catch is CancellationError { throw CancellationError() }
            catch let error as URLError {
                if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
                throw TrudvsemError.network(error.code, retryAfter: nil)
            }
            catch let error as TrudvsemError {
                try Task.checkCancellation()
                if error.stopsCollection { throw error }
                issues.append("\(organization.name): \(error.localizedDescription)")
            }
            catch { issues.append("\(organization.name): \(error.localizedDescription)") }
            metrics.append(.init(organizationKey: organization.id, declared: expected ?? 0, received: received, unique: values.count, pages: pageIndex))
            all += values.values.sorted { $0.id < $1.id }
        }
        return .init(vacancies: all, metrics: metrics, issues: issues)
    }
}
