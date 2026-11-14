import Foundation

struct TrudvsemSnapshot: Codable, Sendable {
    let version: Int
    let vacancies: [TrudvsemVacancy]
    let metrics: [TrudvsemCollection.Metrics]
    let updatedAt: Date
}
struct TrudvsemSnapshotStore: Sendable {
    var configuredURL: URL?
    var url: URL { get throws { try configuredURL ?? ApplicationSupportLocation.fileURL(named: "vacancies-trudvsem.json", fileManager: .default) } }
    func load() throws -> TrudvsemSnapshot? {
        let url = try url
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let snapshot = try JSONDecoder().decode(TrudvsemSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.version == 1 else { throw TrudvsemError.invalid("Версия снимка") }
        guard Set(snapshot.vacancies.map(\.id)).count == snapshot.vacancies.count,
              snapshot.vacancies.allSatisfy({ v in OrganizationRegistry.all.contains { $0.id == v.organizationKey && $0.inn == v.dto.raw["company"]["inn"].text } }) else { throw TrudvsemError.invalid("Снимок повреждён") }
        return snapshot
    }
    func save(_ snapshot: TrudvsemSnapshot) throws {
        let url = try url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }
}
