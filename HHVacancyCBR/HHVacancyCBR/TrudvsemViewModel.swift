import AppKit
import Combine
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

enum VacancySort: String, CaseIterable { case newest = "Сначала новые", title = "По названию" }

@MainActor
final class TrudvsemViewModel: ObservableObject {
    @Published private(set) var results: [TrudvsemVacancy] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isCancellingSearch = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var updatedAt: Date?
    @Published private(set) var metrics: [TrudvsemCollection.Metrics] = []
    @Published private(set) var collectionIssues: [String] = []
    @Published var selectedEmployerID = "all"
    @Published var selectedRegionID = "all"
    @Published var fieldInstitutionsOnly = false
    @Published var sort: VacancySort = .newest
    @Published var expandedID: String?
    @Published private(set) var isExporting = false
    @Published private(set) var exportProgress: BulkPDFExportProgress?
    private let client: any TrudvsemAPI
    private let store: TrudvsemSnapshotStore
    private let employerStore: TrudvsemEmployerConfigurationStore
    private var loaded = false
    private var searchTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    init(client: any TrudvsemAPI = TrudvsemAPIClient(), store: TrudvsemSnapshotStore = .init()) { self.client = client; self.store = store
        employerStore = TrudvsemEmployerConfigurationStore(configuredURL: store.configuredURL?.deletingLastPathComponent().appendingPathComponent("employers-trudvsem.json"))
    }
    deinit { searchTask?.cancel(); exportTask?.cancel() }
    var displayedResults: [TrudvsemVacancy] {
        results.filter { (selectedEmployerID == "all" || $0.organizationKey == selectedEmployerID)
            && (selectedRegionID == "all" || $0.regionID == selectedRegionID)
            && (!fieldInstitutionsOnly || $0.fieldInstitution.isMember) }.sorted {
                if sort == .newest, $0.createdDate != $1.createdDate { return ($0.createdDate ?? .distantPast) > ($1.createdDate ?? .distantPast) }
                if $0.title == $1.title { return $0.id < $1.id }; return $0.title < $1.title
            }
    }
    var regions: [VacancyFilterOption] {
        let groups = Dictionary(grouping: results, by: \.regionID)
        return [.init(id: "all", title: "Все регионы")] + groups.keys.sorted().map { .init(id: $0, title: groups[$0]!.first!.region) }
    }
    var filters: [String: String] { ["Организация": OrganizationRegistry.all.first { $0.id == selectedEmployerID }?.name ?? "Все организации",
        "Регион": regions.first { $0.id == selectedRegionID }?.title ?? selectedRegionID,
        "Категория": fieldInstitutionsOnly ? "Полевые учреждения" : "Все вакансии", "Сортировка": sort.rawValue] }
    func load() {
        guard !loaded else { return }; loaded = true
        do { _ = try employerStore.loadOrCreate(); if let snapshot = try store.load() { results = snapshot.vacancies; updatedAt = snapshot.updatedAt; metrics = snapshot.metrics; statusMessage = "Показана сохранённая полная выборка." } }
        catch { errorMessage = "Не удалось прочитать снимок: \(error.localizedDescription)" }
    }
    func startRefresh() {
        guard searchTask == nil else { return }
        searchTask = Task { [weak self] in
            await self?.refresh()
            self?.searchTask = nil; self?.isCancellingSearch = false
        }
    }
    func cancelSearch() { isCancellingSearch = true; searchTask?.cancel() }
    func refresh() async {
        guard !isLoading else { return }
        isLoading = true; errorMessage = nil
        defer { isLoading = false }
        do {
            statusMessage = "Ожидание очереди обновления…"
            try await VacancyRefreshScheduler.acquire()
            defer { VacancyRefreshScheduler.release() }
            _ = try employerStore.loadOrCreate()
            let collection = try await TrudvsemCollectionService(client: client).collect { [weak self] in self?.statusMessage = $0 }
            try Task.checkCancellation()
            metrics = collection.metrics; collectionIssues = collection.issues
            guard collection.isComplete else { throw TrudvsemError.incomplete(collection.issues.joined(separator: "\n")) }
            let snapshot = TrudvsemSnapshot(version: 1, vacancies: collection.vacancies, metrics: collection.metrics, updatedAt: Date())
            try Task.checkCancellation()
            try employerStore.recordVerifiedCodes(snapshot.vacancies)
            // Atomic commit has no suspension point between persistence and publication.
            try store.save(snapshot)
            results = snapshot.vacancies; updatedAt = snapshot.updatedAt
            statusMessage = results.isEmpty ? "Открытых вакансий нет." : "Готово: \(results.count) уникальных вакансий."
        } catch is CancellationError { statusMessage = "Обновление отменено; сохранённая выборка не изменена." }
        catch { errorMessage = error.localizedDescription; statusMessage = "Обновление не завершено." }
    }
    func cancelExport() { exportTask?.cancel() }
    enum ExportMode { case personal(TrudvsemVacancy), statistics, all }
    func export(_ mode: ExportMode) {
        guard !isExporting else { return }
        let values = displayedResults, filters = filters
        guard !values.isEmpty else { return }
        isExporting = true
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isExporting = false; self.exportTask = nil; self.exportProgress = nil }
            do {
                let worker = PDFExportWorker()
                switch mode {
                case .all:
                    var snapshots: [PDFVacancySnapshot] = []
                    for value in values {
                        try Task.checkCancellation()
                        snapshots.append(TrudvsemPDFFormatter.personal(value)); await Task.yield()
                    }
                    let prepared = try await worker.prepare(vacancies: PDFVacanciesSnapshot(snapshots: snapshots), filters: filters) { [weak self] in self?.exportProgress = $0 }
                    try Task.checkCancellation()
                    guard let directory = VacanciesPDFExporter.chooseExportDirectory() else { return }
                    let names = (1...prepared.partCount).map { PDFFileNameBuilder.bulk(part: $0, totalParts: prepared.partCount, exportStartedAt: Date(), source: .trudvsem) }
                    exportProgress = .init(completedVacancies: values.count, totalVacancies: values.count, stage: "Сохранение файлов")
                    let urls = try await worker.writePrepared(names: names, directory: directory)
                    statusMessage = "Экспортировано вакансий: \(values.count), PDF: \(urls.count), страниц: \(prepared.pageCount)."
                case .statistics, .personal:
                    let document: PDFVacancySnapshot
                    let title: String
                    if case .personal(let vacancy) = mode { document = TrudvsemPDFFormatter.personal(vacancy); title = vacancy.title }
                    else { document = TrudvsemPDFFormatter.statistics(values, filters: filters); title = "статистика" }
                    let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.canCreateDirectories = true
                    panel.nameFieldStringValue = PDFFileNameBuilder.personal(vacancyID: "", title: "trudvsem_ru_" + title, exportStartedAt: Date())
                    guard panel.runModal() == .OK, let url = panel.url else { return }
                    try await worker.exportDocument(document: document, destination: url)
                    statusMessage = "PDF сохранён."
                }
            } catch is CancellationError { statusMessage = "Экспорт отменён." }
            catch { errorMessage = "Не удалось сохранить PDF: \(error.localizedDescription)" }
        }
    }
}
