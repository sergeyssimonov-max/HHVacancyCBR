import Foundation

struct EmployerConfigurationEntry: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let comment: String
    let jointVenture: Bool?
    var organizationKey: String? = nil
    var verifiedAt: String? = nil
    var verificationSource: String? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, comment, organizationKey, verifiedAt, verificationSource
        case jointVenture = "joint_venture"
    }

    init(id: String, name: String, comment: String, jointVenture: Bool? = nil) {
        self.id = id
        self.name = name
        self.comment = comment
        self.jointVenture = jointVenture
        if let org = OrganizationRegistry.all.first(where: { $0.hhEmployerIDs.contains(id) }) {
            organizationKey = org.id
            verificationSource = "https://hh.ru/employer/" + id
            verifiedAt = id == "9942121" ? "2026-10-22" : "2026-10-16"
        }
    }
}

struct EmployerConfiguration: Codable, Equatable, Sendable {
    static let currentVersion = 2
    let version: Int
    let employers: [EmployerConfigurationEntry]

    func validated() throws -> EmployerConfiguration {
        guard (1...Self.currentVersion).contains(version) else { throw EmployerConfigurationError.unsupportedVersion(version) }
        guard !employers.isEmpty else { throw EmployerConfigurationError.empty }
        var ids = Set<String>()
        for employer in employers {
            guard !employer.id.isEmpty,
                  employer.id.utf8.allSatisfy({ (48...57).contains($0) }),
                  employer.id.first != "0",
                  employer.name.nilIfBlank != nil,
                  employer.comment.nilIfBlank != nil else {
                throw EmployerConfigurationError.invalidEntry(employer.id)
            }
            guard ids.insert(employer.id).inserted else { throw EmployerConfigurationError.duplicateID(employer.id) }
        }
        return self
    }
}

enum EmployerConfigurationError: LocalizedError, Equatable {
    case missingBundledDefault
    case empty
    case unsupportedVersion(Int)
    case invalidEntry(String)
    case duplicateID(String)

    var errorDescription: String? {
        switch self {
        case .missingBundledDefault: return "В приложении отсутствует базовый employers.json."
        case .empty: return "Список работодателей пуст."
        case .unsupportedVersion(let version): return "Версия employers.json \(version) не поддерживается."
        case .invalidEntry(let id): return "Некорректная запись работодателя: \(id)."
        case .duplicateID(let id): return "Идентификатор работодателя \(id) указан повторно."
        }
    }
}

protocol EmployerConfigurationStoring: Sendable {
    func loadOrCreate() throws -> EmployerConfiguration
}

struct EmployerConfigurationStore: EmployerConfigurationStoring, @unchecked Sendable {
    private let configuredFileURL: URL?
    private let bundledDefaultURL: URL?
    private let fileManager: FileManager

    init(fileURL: URL? = nil, bundledDefaultURL: URL? = nil, fileManager: FileManager = .default) {
        configuredFileURL = fileURL
        self.bundledDefaultURL = bundledDefaultURL
        self.fileManager = fileManager
    }

    var fileURL: URL {
        get throws {
            if let configuredFileURL { return configuredFileURL }
            return try ApplicationSupportLocation.fileURL(named: "employers.json", fileManager: fileManager)
        }
    }

    func loadOrCreate() throws -> EmployerConfiguration {
        let fileURL = try self.fileURL
        if !fileManager.fileExists(atPath: fileURL.path) {
            guard let bundledDefaultURL else { throw EmployerConfigurationError.missingBundledDefault }
            let directory = fileURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Data(contentsOf: bundledDefaultURL)
            _ = try JSONDecoder().decode(EmployerConfiguration.self, from: data).validated()
            try data.write(to: fileURL, options: .atomic)
        }
        let current = try JSONDecoder().decode(EmployerConfiguration.self, from: Data(contentsOf: fileURL)).validated()
        var entries = current.employers
        let ids = Set(entries.map(\.id))
        // Add system accounts without replacing user names, comments or additional records.
        for org in OrganizationRegistry.all {
            for id in org.hhEmployerIDs where !ids.contains(id) {
                entries.append(.init(id: id, name: org.name, comment: "Подтверждённый профиль https://hh.ru/employer/\(id). Реестр 2026-10-21. " + org.sources.joined(separator: " ")))
            }
        }
        for index in entries.indices {
            if let org = OrganizationRegistry.all.first(where: { $0.hhEmployerIDs.contains(entries[index].id) }) {
                if entries[index].organizationKey == nil { entries[index].organizationKey = org.id }
                if entries[index].verificationSource == nil { entries[index].verificationSource = "https://hh.ru/employer/" + entries[index].id }
                if entries[index].verifiedAt == nil { entries[index].verifiedAt = entries[index].id == "9942121" ? "2026-10-22" : "2026-10-16" }
            }
        }
        let migrated = try EmployerConfiguration(version: EmployerConfiguration.currentVersion, employers: entries).validated()
        if migrated != current {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(migrated).write(to: fileURL, options: .atomic)
        }
        return migrated
    }
}
