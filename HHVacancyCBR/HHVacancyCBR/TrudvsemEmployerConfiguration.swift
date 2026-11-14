import Foundation

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
        var merged = value
        var changed = false
        for org in OrganizationRegistry.available(on: .trudvsem) {
            if let index = merged.employers.firstIndex(where: { $0.organizationKey == org.id }) {
                let entry = merged.employers[index]
                if entry.inn != org.inn || entry.ogrn != org.ogrn {
                    merged.employers[index] = .init(organizationKey: org.id, inn: org.inn, ogrn: org.ogrn, confirmedCompanyCodes: [])
                    changed = true
                }
            } else {
                merged.employers.append(.init(organizationKey: org.id, inn: org.inn, ogrn: org.ogrn, confirmedCompanyCodes: []))
                changed = true
            }
        }
        if changed { try save(merged) }
        return merged
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
