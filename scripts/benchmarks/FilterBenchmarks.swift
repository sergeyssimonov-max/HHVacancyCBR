import CryptoKit
import Darwin
import Foundation

// Standalone synthetic workload. This file is not part of any application target.
private enum FilterBenchmarkError: Error {
    case invalidArguments
    case checkFailed(String)
    case unexpectedNetwork
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw FilterBenchmarkError.checkFailed(message) }
}

private final class NetworkCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    func record() { lock.lock(); calls += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}

private struct NoNetworkClient: HHVacancyAPIClient, TrudvsemAPI {
    let counter: NetworkCounter
    private func reject() throws {
        counter.record()
        throw FilterBenchmarkError.unexpectedNetwork
    }
    func searchVacancies(_ request: HHVacancySearchRequest) async throws -> HHVacancySearchResponse {
        try reject(); throw FilterBenchmarkError.unexpectedNetwork
    }
    func vacancyDetails(id: String) async throws -> HHVacancyDetails {
        try reject(); throw FilterBenchmarkError.unexpectedNetwork
    }
    func areaTree() async throws -> HHAreaNode {
        try reject(); throw FilterBenchmarkError.unexpectedNetwork
    }
    func vacancyDictionaries() async throws -> HHVacancyDictionaries {
        try reject(); throw FilterBenchmarkError.unexpectedNetwork
    }
    func validateVacanciesAccess() throws { try reject() }
    func vacancies(inn: String, page: Int, limit: Int) async throws -> TrudvsemPage {
        try reject(); throw FilterBenchmarkError.unexpectedNetwork
    }
}

private struct FixtureEmployers: EmployerConfigurationStoring {
    func loadOrCreate() throws -> EmployerConfiguration {
        EmployerConfiguration(version: 2, employers: OrganizationRegistry.available(on: .hh).map {
            EmployerConfigurationEntry(id: $0.hhEmployerIDs[0], name: $0.name, comment: "Synthetic filter benchmark")
        })
    }
}

private struct FixtureRow: Encodable {
    let id: String
    let organizationKey: String
    let title: String
    let description: String
    let regionCode: String
    let dateRank: Int
    let publicationDate: String?
    let fieldInstitution: Bool
    let hasMarker: Bool
}

private enum SearchPredicate {
    case all, marker, analyst, absent
    var draft: String {
        switch self {
        case .all: return ""
        case .marker: return "  КВАНТОВЫЙМАРКЕР\n"
        case .analyst: return "аналитик"
        case .absent: return "несуществующиймаркер"
        }
    }
    func accepts(_ row: FixtureRow) -> Bool {
        switch self {
        case .all: return true
        case .marker: return row.hasMarker
        case .analyst: return !row.fieldInstitution
        case .absent: return false
        }
    }
}

private struct FilterCase {
    let name: String
    var employer: String? = nil
    var region: String? = nil
    var fieldOnly = false
    var search: SearchPredicate = .all
    var clearSearch = false

    func accepts(_ row: FixtureRow) -> Bool {
        (employer == nil || employer == row.organizationKey)
            && (region == nil || region == row.regionCode)
            && (!fieldOnly || row.fieldInstitution)
            && (clearSearch || search.accepts(row))
    }
}

private struct ResourceUsage: Encodable {
    let cpuSeconds: Double
    let peakRSSBytes: Int64

    static func read() -> Self {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return Self(cpuSeconds: user + system, peakRSSBytes: Int64(usage.ru_maxrss))
    }
}

private struct Measurement: Encodable {
    let source: String
    let scenario: String
    let inputCount: Int
    let resultCount: Int
    let logicalIDsSHA256: String
    let nativeIDsSHA256: String
    let firstLogicalIDs: [String]
    let lastLogicalIDs: [String]
    let filterWallSeconds: Double
    let filterCPUSeconds: Double
    let cachedReadWallSeconds: Double
    let processPeakRSSBytes: Int64
}

private struct DatasetReport: Encodable {
    let inputCount: Int
    let fixtureSHA256: String
    let trudRawPayloadSHA256: String
    let hhLoadWallSeconds: Double
    let trudLoadWallSeconds: Double
    let maximumSynchronousFilterSeconds: Double
    let snapshotsUnchanged: Bool
    let measurements: [Measurement]
}

private struct BenchmarkReport: Encodable {
    let schemaVersion = 1
    let workload = "viewmodel-filtering"
    let fixtureVersion = 1
    let snapshotDate: String
    let locale: String
    let timeZone: String
    let networkCallCount: Int
    let processCPUSeconds: Double
    let processPeakRSSBytes: Int64
    let datasets: [DatasetReport]
}

@main
private enum FilterBenchmarks {
    private static let fixedDate = Date(timeIntervalSince1970: 1_788_400_000)
    private static let companyCode = "synthetic-filter-benchmark"
    private static let cases: [FilterCase] = [
        .init(name: "all_sorted"),
        .init(name: "employer", employer: "bank_of_russia"),
        .init(name: "region", region: "77"),
        .init(name: "unknown_region", region: "unknown"),
        .init(name: "employer_AND_region", employer: "bank_of_russia", region: "77"),
        .init(name: "description_search_case_and_trim", search: .marker),
        .init(name: "title_search", search: .analyst),
        .init(name: "search_AND_employer_AND_region", employer: "bank_of_russia", region: "77", search: .marker),
        .init(name: "field_institutions", fieldOnly: true),
        .init(name: "all_filters_AND_search", employer: "bank_of_russia", region: "77", fieldOnly: true, search: .marker),
        .init(name: "no_matches", search: .absent),
        .init(name: "clear_search_and_reset", search: .absent, clearSearch: true)
    ]

    @MainActor
    static func main() async throws {
        // AppleLocale/AppleLanguages are launch arguments, not writes to user defaults.
        guard CommandLine.arguments.count > 1,
              let count = Int(CommandLine.arguments[1]), (0...100_000).contains(count) else {
            throw FilterBenchmarkError.invalidArguments
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HHFilterBench-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let counter = NetworkCounter()
        var reports: [DatasetReport] = []
        for size in count == 0 ? [0] : [0, count] {
            reports.append(try await runDataset(count: size, root: root, counter: counter))
        }
        try require(counter.count == 0, "Filtering or persistence attempted a network operation")
        let usage = ResourceUsage.read()
        let report = BenchmarkReport(snapshotDate: "2026-09-03T01:46:40Z", locale: Locale.current.identifier,
                                     timeZone: TimeZone.current.identifier, networkCallCount: counter.count,
                                     processCPUSeconds: usage.cpuSeconds, processPeakRSSBytes: usage.peakRSSBytes,
                                     datasets: reports)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    @MainActor
    private static func runDataset(count: Int, root: URL, counter: NetworkCounter) async throws -> DatasetReport {
        let directory = root.appendingPathComponent(String(count), isDirectory: true)
        let hhURL = directory.appendingPathComponent("vacancies.json")
        let trudURL = directory.appendingPathComponent("vacancies-trudvsem.json")
        let hhStore = VacancySnapshotStore(fileURL: hhURL)
        let trudStore = TrudvsemSnapshotStore(configuredURL: trudURL)
        let organizations = OrganizationRegistry.available(on: .hh)
        var rows: [FixtureRow] = []
        var hh: [VacancySearchResult] = []
        var trud: [TrudvsemVacancy] = []
        for index in 0..<count {
            let organization = organizations[index % organizations.count]
            let field = index % 35 == 0
            let marker = index % 7 == 0
            let id = String(format: "%06d", index)
            let title = (field ? "Кассир ПУ Инское " : "Аналитик ") + String(format: "%02d", index % 41)
            let description = marker ? "Синтетическое описание квантовыймаркер" : "Синтетическое описание должности"
            let region = index % 3 == 0 ? "77" : (index % 3 == 1 ? "78" : "unknown")
            let regionName = region == "77" ? "Москва" : "Санкт-Петербург"
            let rank = index % 11 == 0 ? -1 : index % 13
            let publication = rank < 0 ? nil : String(format: "2026-09-%02dT10:00:00Z", rank + 1)
            rows.append(FixtureRow(id: id, organizationKey: organization.id, title: title, description: description,
                                   regionCode: region, dateRank: rank, publicationDate: publication,
                                   fieldInstitution: field, hasMarker: marker))
            let location: VacancyLocation = region == "unknown" ? .unknown : .subject(id: region, name: regionName, cityID: nil, cityName: nil)
            let summary = HHVacancySummary(id: id, name: title, employer: .init(name: organization.name, id: organization.hhEmployerIDs[0]),
                                          salary: nil, area: nil, alternateURL: nil, url: nil,
                                          snippet: .init(requirement: description, responsibility: nil), publishedAt: publication)
            let hhValue = VacancySearchResult(summary: summary, location: location)
            let raw: SourceJSONValue = .object([
                "id": .string(id), "job-name": .string(title), "duty": .string(description),
                "company": .object(["companycode": .string(companyCode), "inn": .string(organization.inn), "name": .string(organization.name)]),
                "region": region == "unknown" ? .null : .object(["region_code": .string(region), "name": .string(regionName)]),
                "creation-date": publication.map { .string($0) } ?? .null
            ])
            let trudValue = TrudvsemVacancy(dto: try TrudvsemVacancyDTO(raw: raw), organization: organization, observationIDs: [])
            try require(hhValue.isFieldInstitution == field && trudValue.fieldInstitution.isMember == field, "Fixture field classification")
            hh.append(hhValue)
            trud.append(trudValue)
        }
        try hhStore.save(VacancySnapshot(values: hh, issues: [], updatedAt: fixedDate))
        try trudStore.save(TrudvsemSnapshot(version: 1, vacancies: trud, metrics: [], updatedAt: fixedDate))
        let originalHH = try Data(contentsOf: hhURL)
        let originalTrud = try Data(contentsOf: trudURL)
        let client = NoNetworkClient(counter: counter)
        let hhModel = VacancySearchViewModel(apiClient: client, employerStore: FixtureEmployers(),
                                           areaStore: AreaDirectoryStore(fileURL: directory.appendingPathComponent("areas.json"), now: { fixedDate }),
                                           snapshotStore: hhStore, currentDate: { fixedDate })
        let hhLoadStart = ProcessInfo.processInfo.systemUptime
        await hhModel.loadPersistenceIfNeeded()
        let hhLoadSeconds = ProcessInfo.processInfo.systemUptime - hhLoadStart
        let trudModel = TrudvsemViewModel(client: client, store: trudStore)
        let trudLoadStart = ProcessInfo.processInfo.systemUptime
        trudModel.load()
        let trudLoadSeconds = ProcessInfo.processInfo.systemUptime - trudLoadStart
        try require(hhModel.errorMessage == nil && hhModel.snapshotWarning == nil && trudModel.errorMessage == nil, "Synthetic snapshots failed to load")
        try require(hhModel.results.count == count && trudModel.results.count == count, "Loaded snapshot counts differ")
        var measurements: [Measurement] = []
        for scenario in cases {
            // The oracle uses fixture metadata, never production filtering/date parsing.
            let expected = rows.filter { scenario.accepts($0) }.sorted {
                if $0.dateRank != $1.dateRank { return $0.dateRank > $1.dateRank }
                if $0.title != $1.title { return $0.title < $1.title }
                return $0.id < $1.id
            }.map(\.id)
            hhModel.selectedEmployerID = scenario.employer ?? "all"
            hhModel.selectedRegionID = scenario.region.map { $0 == "unknown" ? $0 : "subject:" + $0 } ?? "all"
            hhModel.fieldInstitutionsOnly = scenario.fieldOnly
            hhModel.searchDraft = scenario.search.draft
            hhModel.applySearch()
            if scenario.clearSearch { hhModel.clearSearch() }
            let hhMeasurement = try measure(source: "hh.ru", scenario: scenario.name, count: count, expected: expected,
                                            values: { hhModel.displayedResults }, nativeID: { $0.id }, logicalID: { $0.id })
            trudModel.selectedEmployerID = scenario.employer ?? "all"
            trudModel.selectedRegionID = scenario.region ?? "all"
            trudModel.fieldInstitutionsOnly = scenario.fieldOnly
            trudModel.searchDraft = scenario.search.draft
            trudModel.applySearch()
            if scenario.clearSearch { trudModel.clearSearch() }
            let trudMeasurement = try measure(source: "trudvsem.ru", scenario: scenario.name, count: count, expected: expected,
                                              values: { trudModel.displayedResults }, nativeID: { $0.id }, logicalID: { $0.dto.id })
            try require(hhMeasurement.logicalIDsSHA256 == trudMeasurement.logicalIDsSHA256, "Sources disagree on synthetic logical IDs")
            measurements.append(contentsOf: [hhMeasurement, trudMeasurement])
        }
        try require(counter.count == 0, "Unexpected network use")
        let finalHH = try Data(contentsOf: hhURL)
        let finalTrud = try Data(contentsOf: trudURL)
        try require(finalHH == originalHH, "HH filtering rewrote its snapshot")
        try require(finalTrud == originalTrud, "trudvsem filtering rewrote its snapshot")
        return DatasetReport(inputCount: count, fixtureSHA256: try digestJSON(rows),
                             trudRawPayloadSHA256: try digestJSON(trud.map { $0.dto.raw }),
                             hhLoadWallSeconds: hhLoadSeconds, trudLoadWallSeconds: trudLoadSeconds,
                             maximumSynchronousFilterSeconds: measurements.map(\.filterWallSeconds).max() ?? 0,
                             snapshotsUnchanged: true, measurements: measurements)
    }

    @MainActor
    private static func measure<Value>(source: String, scenario: String, count: Int, expected: [String],
                                       values: () -> [Value], nativeID: (Value) -> String,
                                       logicalID: (Value) -> String) throws -> Measurement {
        let before = ResourceUsage.read()
        let start = ProcessInfo.processInfo.systemUptime
        let actual = values()
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let after = ResourceUsage.read()
        let logicalIDs = actual.map(logicalID)
        let nativeIDs = actual.map(nativeID)
        try require(logicalIDs == expected, source + "/" + scenario + ": filter, search or sort differs from fixture oracle")
        let cachedStart = ProcessInfo.processInfo.systemUptime
        let cached = values()
        let cachedElapsed = ProcessInfo.processInfo.systemUptime - cachedStart
        try require(cached.map(nativeID) == nativeIDs, source + "/" + scenario + ": cached order differs")
        return Measurement(source: source, scenario: scenario, inputCount: count, resultCount: actual.count,
                           logicalIDsSHA256: digestIDs(logicalIDs), nativeIDsSHA256: digestIDs(nativeIDs),
                           firstLogicalIDs: Array(logicalIDs.prefix(10)), lastLogicalIDs: Array(logicalIDs.suffix(10)),
                           filterWallSeconds: elapsed, filterCPUSeconds: after.cpuSeconds - before.cpuSeconds,
                           cachedReadWallSeconds: cachedElapsed, processPeakRSSBytes: after.peakRSSBytes)
    }

    private static func digestIDs(_ values: [String]) -> String {
        SHA256.hash(data: Data(values.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func digestJSON<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}
