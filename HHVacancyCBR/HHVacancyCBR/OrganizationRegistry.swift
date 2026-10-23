import Foundation

enum VacancySource: String, Codable, CaseIterable, Sendable {
    case hh = "hh.ru", trudvsem = "trudvsem.ru"
    var displayName: String { self == .hh ? "HeadHunter (hh.ru)" : "Работа в России (trudvsem.ru)" }
}

struct Organization: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    let legalName: String
    let relationship: String
    let inn: String
    let ogrn: String
    let hhEmployerIDs: [String]
    let sources: [String]
}

enum OrganizationRegistry {
    static let all: [Organization] = [
        .init(id: "bank_of_russia", name: "Банк России", legalName: "Центральный банк Российской Федерации (Банк России)", relationship: "Головная организация системы Банка России", inn: "7702235133", ogrn: "1037700013020", hhEmployerIDs: ["47858"], sources: ["https://www.cbr.ru/"]),
        .init(id: "rosinkas", name: "РОСИНКАС", legalName: "Российское объединение инкассации Банка России (РОСИНКАС)", relationship: "Входит в систему Банка России", inn: "7703030058", ogrn: "1027739529641", hhEmployerIDs: ["125886"], sources: ["https://www.rosinkas.ru/info"]),
        .init(id: "nspk", name: "НСПК", legalName: "АО «Национальная система платежных карт»", relationship: "100% акций Банка России", inn: "7706812159", ogrn: "1147746831352", hhEmployerIDs: ["1654251"], sources: ["https://www.cbr.ru/about_br/history/"]),
        .init(id: "rnpk", name: "РНПК", legalName: "АО «Российская национальная перестраховочная компания»", relationship: "100% акций Банка России", inn: "7706440687", ogrn: "1167746727378", hhEmployerIDs: ["2608647"], sources: ["https://hh.ru/employer/2608647"]),
        .init(id: "nsis", name: "НСИС", legalName: "АО «Национальная страховая информационная система»", relationship: "Банк России — единственный акционер, 100% акций", inn: "7720895647", ogrn: "1237700279508", hhEmployerIDs: ["9942121"], sources: ["https://www.cbr.ru/press/event/?id=14592", "https://nsis.ru/", "https://hh.ru/employer/9942121"]),
        .init(id: "uk_fkbs", name: "УК ФКБС", legalName: "ООО «Управляющая компания Фонда консолидации банковского сектора»", relationship: "Банк России — единственный участник, 100% капитала", inn: "7714997584", ogrn: "1177746688130", hhEmployerIDs: [], sources: ["https://www.cbr.ru/banking_sector/PrBankrot/", "https://amfbc.ru/"])
    ]
    // Public company cards verified by matching INN on 2026-10-23, independently of open vacancies.
    static let trudvsemProfiles: [String: String] = [
        "bank_of_russia": "1037700013020", "rosinkas": "1027739529641",
        "nspk": "1147746831352", "rnpk": "1167746727378",
        "nsis": "1237700279508", "uk_fkbs": "1177746688130"
    ]

    static func available(on source: VacancySource) -> [Organization] {
        switch source {
        case .hh: return all.filter { !$0.hhEmployerIDs.isEmpty }
        case .trudvsem: return all.filter { trudvsemProfiles[$0.id] != nil }
        }
    }

    static func supportsHH(_ employer: EmployerConfigurationEntry) -> Bool {
        guard let key = employer.organizationKey, let organization = all.first(where: { $0.id == key }) else { return true }
        return !organization.hhEmployerIDs.isEmpty
    }

    static func key(forHH id: String) -> String {
        if let org = all.first(where: { $0.hhEmployerIDs.contains(id) }) { return org.id }
        if FieldInstitutionClassifier.registry.contains(where: { $0.employerIDs.contains(id) }) { return "bank_of_russia" }
        return "hh_account_" + id
    }
}

struct TrudvsemEmployerConfiguration: Codable, Sendable {
    struct Entry: Codable, Sendable {
        let organizationKey: String
        let inn: String
        let ogrn: String
        // A code can be reused only after the legal identifiers have matched an API response.
        var confirmedCompanyCodes: [String]
    }
    let version: Int
    var employers: [Entry]
    static var defaults: Self {
        .init(version: 1, employers: OrganizationRegistry.available(on: .trudvsem).map {
            .init(organizationKey: $0.id, inn: $0.inn, ogrn: $0.ogrn, confirmedCompanyCodes: [])
        })
    }
}

struct TrudvsemEmployerConfigurationStore: Sendable {
    var configuredURL: URL?
    var url: URL { get throws { try configuredURL ?? ApplicationSupportLocation.fileURL(named: "employers-trudvsem.json", fileManager: .default) } }
    func loadOrCreate() throws -> TrudvsemEmployerConfiguration {
        let url = try url
        guard FileManager.default.fileExists(atPath: url.path) else {
            let defaults = TrudvsemEmployerConfiguration.defaults
            try save(defaults); return defaults
        }
        let value = try JSONDecoder().decode(TrudvsemEmployerConfiguration.self, from: Data(contentsOf: url))
        guard value.version == 1, Set(value.employers.map(\.organizationKey)).count == value.employers.count else {
            throw TrudvsemError.invalid("Версия или дубликаты конфигурации работодателей")
        }
        for org in OrganizationRegistry.available(on: .trudvsem) {
            guard let entry = value.employers.first(where: { $0.organizationKey == org.id }), entry.inn == org.inn, entry.ogrn == org.ogrn else {
                throw TrudvsemError.invalid("Реквизиты \(org.name) в конфигурации")
            }
        }
        return value
    }
    func recordVerifiedCodes(_ vacancies: [TrudvsemVacancy]) throws {
        var value = try loadOrCreate()
        let activeKeys = Set(OrganizationRegistry.available(on: .trudvsem).map(\.id))
        for index in value.employers.indices where activeKeys.contains(value.employers[index].organizationKey) {
            let entry = value.employers[index]
            let verified = vacancies.filter { $0.organizationKey == entry.organizationKey && $0.dto.raw["company"]["inn"].text == entry.inn && ($0.dto.raw["company"]["ogrn"].text == nil || $0.dto.raw["company"]["ogrn"].text == entry.ogrn) }.map { $0.dto.companyCode }
            value.employers[index].confirmedCompanyCodes = Array(Set(entry.confirmedCompanyCodes + verified)).sorted()
        }
        try save(value)
    }
    private func save(_ value: TrudvsemEmployerConfiguration) throws {
        let url = try url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: url, options: .atomic)
    }
}

/// Serializes full refreshes without polling or blocking the main thread.
@MainActor enum VacancyRefreshScheduler {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private static var busy = false
    private static var waiters: [Waiter] = []

    static func acquire() async throws {
        try Task.checkCancellation()
        if !busy { busy = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor in cancel(id) }
        }
        // Cancellation can race with ownership transfer. Return the permit.
        if Task.isCancelled { release(); throw CancellationError() }
    }

    private static func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    static func release() {
        if waiters.isEmpty { busy = false }
        else { waiters.removeFirst().continuation.resume() }
    }
}

enum VacancyExtractionStatus {
    static func summary(employer: String, extracted: Int, expected: Int, pages: Int) -> String {
        "\(employer): \(extracted) из \(expected), страниц: \(pages)"
    }
}
