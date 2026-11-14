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
