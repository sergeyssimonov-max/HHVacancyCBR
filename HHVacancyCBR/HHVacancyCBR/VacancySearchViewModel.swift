import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct VacancyFilterOption: Identifiable, Equatable {
    let id: String
    let title: String
}

private struct VacancySearchCache {
    let values: [VacancySearchResult]
    let updatedAt: Date
    let issues: [VacancyCollectionIssue]
}

@MainActor
final class VacancySearchViewModel: ObservableObject {
    static let searchCacheTTL: TimeInterval = 10 * 60
    private static let publicationDateParser = HHPublicationDateParser()

    @Published private(set) var results: [VacancySearchResult] = [] { didSet { displayedCache = nil } }
    @Published private(set) var configuredEmployers: [EmployerConfigurationEntry] = [] { didSet { displayedCache = nil } }
    @Published private(set) var expandedVacancyID: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isPersistenceLoaded = false
    @Published private(set) var isExportingBulkPDF = false
    @Published private(set) var isExportingStatisticsPDF = false
    @Published private(set) var isExportingPersonalPDF = false
    @Published private(set) var statisticsPDFExportMessage: String?
    @Published private(set) var bulkPDFExportProgress: BulkPDFExportProgress?
    @Published private(set) var errorMessage: String?
    @Published private(set) var currentEmployerName: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var updatedAtMessage: String?
    @Published private(set) var snapshotWarning: String?
    /// Employers read incompletely by the last successful search.
    @Published private(set) var collectionWarning: String?
    @Published private(set) var hasSearched = false
    @Published private(set) var isCancellingSearch = false
    @Published private(set) var isCancellingBulkPDFExport = false
    @Published var searchDraft = ""
    @Published private(set) var searchText = "" { didSet { displayedCache = nil } }
    func applySearch() { searchText = searchDraft.trimmingCharacters(in: .whitespacesAndNewlines) }
    func clearSearch() { searchDraft = ""; searchText = "" }
    @Published var fieldInstitutionsOnly = false {
        didSet {
            if fieldInstitutionsOnly && !isFieldInstitutionFilterAvailable { fieldInstitutionsOnly = false }
            displayedCache = nil
            reconcileExpanded()
        }
    }
    @Published var selectedEmployerID = "all" {
        didSet {
            if fieldInstitutionsOnly && !isFieldInstitutionFilterAvailable { fieldInstitutionsOnly = false }
            displayedCache = nil
            reconcileExpanded()
        }
    }
    @Published var selectedRegionID = "all" { didSet { displayedCache = nil; reconcileExpanded() } }

    var isFieldInstitutionFilterAvailable: Bool {
        OrganizationRegistry.supportsFieldInstitutionFilter(for: selectedEmployerID)
    }

    private let apiClient: any HHVacancyAPIClient
    private let employerStore: any EmployerConfigurationStoring
    private let areaStore: AreaDirectoryStore
    private let snapshotStore: (any VacancySnapshotStoring)?
    private let bulkPDFExporter: any VacanciesPDFExporting
    private let statisticsPDFDestination: @MainActor (String) -> URL?
    private let currentDate: @Sendable () -> Date
    private var displayedCache: [VacancySearchResult]?
    private var snapshotSaveTask: Task<Void, Never>?
    private var detailsCache: [String: HHVacancyDetails] = [:]
    private var cache: VacancySearchCache?
    private var detailTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var bulkExportTask: Task<Void, Never>?
    private var resultsRevision = 0
    private var searchGeneration = 0
    private final class DetailFlight: @unchecked Sendable {
        let token = UUID()
        private let lock = NSLock()
        private var task: Task<Void, Never>?
        private var waiters: [UUID: CheckedContinuation<HHVacancyDetails, Error>] = [:]
        func addIfActive(_ id: UUID, _ continuation: CheckedContinuation<HHVacancyDetails, Error>) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !waiters.isEmpty else { return false }
            waiters[id] = continuation
            return true
        }
        func add(_ id: UUID, _ continuation: CheckedContinuation<HHVacancyDetails, Error>) {
            lock.lock(); waiters[id] = continuation; lock.unlock()
        }
        func setTask(_ value: Task<Void, Never>) {
            lock.lock(); task = value; let empty = waiters.isEmpty; lock.unlock()
            if empty { value.cancel() }
        }
        func cancel(_ id: UUID) {
            lock.lock()
            let waiter = waiters.removeValue(forKey: id)
            let cancelledTask = waiters.isEmpty ? task : nil
            lock.unlock()
            cancelledTask?.cancel()
            waiter?.resume(throwing: CancellationError())
        }
        func finish(_ result: Result<HHVacancyDetails, Error>) {
            lock.lock(); let pending = waiters; waiters = [:]; task = nil; lock.unlock()
            for waiter in pending.values { waiter.resume(with: result) }
        }
        func cancelAll() {
            lock.lock(); let cancelledTask = task; lock.unlock()
            cancelledTask?.cancel()
            finish(.failure(CancellationError()))
        }
    }
    private final class DetailSubscription: @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private var flight: DetailFlight?
        private var cancelled = false
        func attach(_ value: DetailFlight) {
            lock.lock(); flight = value; let shouldCancel = cancelled; lock.unlock()
            if shouldCancel { value.cancel(id) }
        }
        func cancel() {
            lock.lock(); cancelled = true; let current = flight; lock.unlock()
            current?.cancel(id)
        }
    }
    private var detailFlights: [String: DetailFlight] = [:]

    init(
        apiClient: any HHVacancyAPIClient = HHAPIClient(),
        employerStore: any EmployerConfigurationStoring,
        areaStore: AreaDirectoryStore = AreaDirectoryStore(),
        snapshotStore: (any VacancySnapshotStoring)? = nil,
        bulkPDFExporter: (any VacanciesPDFExporting)? = nil,
        statisticsPDFDestination: (@MainActor (String) -> URL?)? = nil,
        currentDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.apiClient = apiClient
        self.employerStore = employerStore
        self.areaStore = areaStore
        self.snapshotStore = snapshotStore
        self.bulkPDFExporter = bulkPDFExporter ?? VacanciesPDFExporter()
        self.statisticsPDFDestination = statisticsPDFDestination ?? Self.chooseStatisticsPDFDestination
        self.currentDate = currentDate
    }

    deinit {
        detailTask?.cancel(); searchTask?.cancel(); bulkExportTask?.cancel()
        for flight in detailFlights.values {
            flight.cancelAll()
        }
    }

    var canSearch: Bool { isPersistenceLoaded && !isLoading && searchTask == nil }
    var canCancelSearch: Bool { searchTask != nil && !isCancellingSearch }
    var canCancelBulkPDFExport: Bool { bulkExportTask != nil && !isCancellingBulkPDFExport }
    var canExportBulkPDF: Bool { !displayedResults.isEmpty && !isExportingBulkPDF && !isExportingStatisticsPDF && !isExportingPersonalPDF }
    var canExportStatisticsPDF: Bool {
        !isLoading && !isExportingBulkPDF && !isExportingStatisticsPDF && !isExportingPersonalPDF
            && !displayedResults.isEmpty
    }
    var displayedVacancyCountMessage: String { VacancyDisplayFormat.vacancyCount(displayedResults.count) }

    var emptyResultsMessage: String {
        if selectedEmployerID != "all",
           !results.contains(where: { organizationKey(forHH: $0.employerID ?? "") == selectedEmployerID }),
           let employer = configuredEmployers.first(where: { $0.id == selectedEmployerID }) {
            return "Работодатель «\(employer.name)» включён в поиск. В сохранённой выборке hh.ru его вакансий нет. Нажмите «Обновить», чтобы повторить поиск."
        }
        return "Для выбранных работодателей и фильтров в текущей выборке вакансий нет."
    }

    private func organizationKey(forHH id: String) -> String {
        let canonical = OrganizationRegistry.key(forHH: id)
        if !canonical.hasPrefix("hh_account_") { return canonical }
        if let key = configuredEmployers.first(where: { $0.id == id })?.organizationKey,
           OrganizationRegistry.all.contains(where: { $0.id == key }) { return key }
        return canonical
    }

    var employerFilterOptions: [VacancyFilterOption] {
        var titlesByID: [String: String] = [:]
        for result in unfilteredResults {
            guard let id = result.employerID else { continue }
            let key = organizationKey(forHH: id)
            guard titlesByID[key] == nil else { continue }
            titlesByID[key] = result.employerName
        }
        // A configured employer remains selectable even when HH returns no vacancies.
        do {
            for employer in configuredEmployers where titlesByID[organizationKey(forHH: employer.id)] == nil {
                titlesByID[organizationKey(forHH: employer.id)] = employer.name
            }
        }
        for org in OrganizationRegistry.available(on: .hh) { titlesByID[org.id] = org.name }
        for org in OrganizationRegistry.all where org.hhEmployerIDs.isEmpty { titlesByID.removeValue(forKey: org.id) }
        let values = titlesByID.map { VacancyFilterOption(id: $0.key, title: $0.value) }
        return [.init(id: "all", title: "Все работодатели")] + values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var regionFilterOptions: [VacancyFilterOption] {
        var titlesByID: [String: String] = [:]
        for result in unfilteredResults {
            let id = result.location.filterID
            guard titlesByID[id] == nil else { continue }
            titlesByID[id] = result.location.kind == .subject
                ? (result.location.subjectName ?? result.areaName)
                : result.areaName
        }
        let values = titlesByID.map { VacancyFilterOption(id: $0.key, title: $0.value) }
        return [.init(id: "all", title: "Все регионы")] + values.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    var displayedResults: [VacancySearchResult] {
        if let displayedCache { return displayedCache }
        let filtered = unfilteredResults.filter {
            (searchText.isEmpty || ($0.name + " " + ($0.summary.snippet?.plainText ?? "") + " " + ($0.plainTextDescription ?? "")).localizedCaseInsensitiveContains(searchText))
                && (!fieldInstitutionsOnly || $0.isFieldInstitution)
                && (selectedEmployerID == "all" || organizationKey(forHH: $0.employerID ?? "") == selectedEmployerID)
                && (selectedRegionID == "all" || $0.location.filterID == selectedRegionID)
        }
        let value = orderedNewestFirst(filtered)
        displayedCache = value
        return value
    }

    private var unfilteredResults: [VacancySearchResult] { results }

    func loadPersistenceIfNeeded() async {
        guard !isPersistenceLoaded else { return }
        do { configuredEmployers = try employerStore.loadOrCreate().employers.filter(OrganizationRegistry.supportsHH) }
        catch { errorMessage = "Не удалось прочитать список работодателей: \(error.localizedDescription)" }
        do {
            let store = snapshotStore
            if let snapshot = try await Task.detached(operation: { try store?.load() }).value {
                results = orderedNewestFirst(snapshot.results)
                cache = VacancySearchCache(values: results, updatedAt: snapshot.updatedAt, issues: snapshot.issues)
                updatedAtMessage = timeMessage(snapshot.updatedAt)
                collectionWarning = Self.makeCollectionWarning(for: snapshot.issues)
                hasSearched = true
                statusMessage = snapshot.issues.isEmpty
                    ? "Показана сохранённая полная выборка."
                    : "Показана сохранённая неполная выборка."
            }
        } catch {
            snapshotWarning = "Не удалось загрузить снимок вакансий: \(error.localizedDescription)"
        }
        isPersistenceLoaded = true
    }

    func search() async { await performSearch(useCache: true) }
    func refreshVacancies() async { await performSearch(useCache: false) }

    /// Starts a refresh owned by the model, so the UI can cancel it.
    func startRefresh() {
        guard canSearch else { return }
        searchTask = Task { [weak self] in
            await self?.refreshVacancies()
            self?.searchTask = nil
            self?.isCancellingSearch = false
        }
    }

    func cancelSearch() {
        guard canCancelSearch else { return }
        isCancellingSearch = true
        searchTask?.cancel()
    }

    func startBulkPDFExport() {
        guard bulkExportTask == nil, canExportBulkPDF else { return }
        bulkExportTask = Task { [weak self] in
            await self?.exportVacanciesPDF()
            self?.bulkExportTask = nil
            self?.isCancellingBulkPDFExport = false
        }
    }

    func cancelBulkPDFExport() {
        guard canCancelBulkPDFExport else { return }
        isCancellingBulkPDFExport = true
        bulkExportTask?.cancel()
    }

    private func performSearch(useCache: Bool) async {
        await loadPersistenceIfNeeded()
        guard !isLoading else { return }
        searchGeneration += 1
        let now = currentDate()
        if useCache, let cache, cache.issues.isEmpty, now.timeIntervalSince(cache.updatedAt) >= 0,
           now.timeIntervalSince(cache.updatedAt) < Self.searchCacheTTL {
            resultsRevision += 1
            results = cache.values
            hasSearched = true
            updatedAtMessage = timeMessage(cache.updatedAt)
            collectionWarning = nil
            statusMessage = "Показана сохранённая полная выборка."
            return
        }
        do { try apiClient.validateVacanciesAccess() }
        catch { hasSearched = true; errorMessage = error.localizedDescription; statusMessage = "Поиск не завершён."; return }

        isLoading = true
        hasSearched = true
        errorMessage = nil
        defer { isLoading = false; currentEmployerName = nil }
        do {
            statusMessage = "Ожидание очереди обновления…"
            try await VacancyRefreshScheduler.acquire()
            defer { VacancyRefreshScheduler.release() }
            let employers = try employerStore.loadOrCreate().employers.filter(OrganizationRegistry.supportsHH)
            configuredEmployers = employers
            statusMessage = "Загружается справочник регионов."
            let areaSnapshot = try await areaStore.load(using: apiClient)
            if let warning = areaSnapshot.warning { statusMessage = warning }
            let collector = VacancyCollectionService(client: apiClient, now: currentDate)
            let collection = try await collector.collect(employers: employers, areas: areaSnapshot.index) { [weak self] progress in
                self?.currentEmployerName = progress.employerName
            }
            try Task.checkCancellation()
            let priorEvidence = Dictionary(results.map { ($0.id, $0.fieldInstitution) }, uniquingKeysWith: { first, _ in first })
            let values = orderedNewestFirst(collection.vacancies.map { summary -> VacancySearchResult in
                var summary = summary
                summary.fieldInstitutionEvidence = priorEvidence[summary.id] ?? nil
                return VacancySearchResult(summary: summary, location: areaSnapshot.index.location(for: summary))
            })
            if !collection.isComplete {
                let retained = cache?.issues.isEmpty == true
                collectionWarning = Self.makeCollectionWarning(for: collection.issues)?
                    .replacingOccurrences(of: "Показаны полученные вакансии", with: retained ? "Сохранена предыдущая полная выборка" : "Новая выборка не опубликована")
                statusMessage = retained ? "Обновление неполное; сохранена предыдущая полная выборка." : "Обновление неполное; новая выборка не опубликована."
                return
            }
            resultsRevision += 1
            results = values
            let updatedAt = currentDate()
            cache = VacancySearchCache(values: values, updatedAt: updatedAt, issues: collection.issues)
            updatedAtMessage = timeMessage(updatedAt)
            collectionWarning = Self.makeCollectionWarning(for: collection.issues)
            if collection.isComplete {
                statusMessage = values.isEmpty ? "У выбранных работодателей нет открытых вакансий." : "Готово: \(values.count) уникальных вакансий."
            } else {
                statusMessage = "Готово с пропусками: \(values.count) уникальных вакансий, неполностью загружено работодателей: \(collection.issues.count)."
            }
            normalizeFilters()
            if let snapshotStore {
                let snapshot = VacancySnapshot(values: values, issues: collection.issues, updatedAt: updatedAt)
                do {
                    try await Task.detached { try snapshotStore.save(snapshot) }.value
                    snapshotWarning = nil
                } catch {
                    snapshotWarning = "Не удалось сохранить снимок вакансий: \(error.localizedDescription)"
                }
            }
        } catch is CancellationError {
            // A cancelled first search returns to the initial screen, not to "no vacancies found".
            if cache == nil { hasSearched = false }
            statusMessage = "Поиск отменён."
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Поиск не завершён; сохранены ранее загруженные вакансии."
        }
    }

    static func makeCollectionWarning(for issues: [VacancyCollectionIssue]) -> String? {
        guard !issues.isEmpty else { return nil }
        let shown = issues.prefix(3).map(\.message).joined(separator: ". ")
        let rest = issues.count > 3 ? ". Еще работодателей с пропусками: \(issues.count - 3)" : ""
        let restriction = issues.contains { issue in
            issue.failures.contains { $0.hasPrefix("Сбор остановлен ограничением hh.ru") }
        } ? "Сбор остановлен ограничением hh.ru. " : ""
        return "Выгрузка неполная. \(restriction)\(shown)\(rest). Показаны полученные вакансии, повторите обновление позже."
    }

    func toggleExplanation(for id: String) {
        if expandedVacancyID == id { expandedVacancyID = nil; detailTask?.cancel(); return }
        expandedVacancyID = id
        detailTask?.cancel()
        detailTask = Task { [weak self] in await self?.loadVacancyDetails(id: id) }
    }

    func loadVacancyDetails(id: String) async {
        guard let index = results.firstIndex(where: { $0.id == id }) else {
            return
        }
        let revision = resultsRevision
        if let cached = detailsCache[id] { apply(details: cached, at: index); return }
        let current = results[index]
        if current.isDetailLoaded { return }
        results[index] = current.updatingDetailState(isLoading: true, errorMessage: nil)
        do {
            let details = try await sharedDetails(id: id)
            try Task.checkCancellation()
            guard revision == resultsRevision else { return }
            detailsCache[id] = details
            guard let newIndex = results.firstIndex(where: { $0.id == id }) else { return }
            apply(details: details, at: newIndex)
        } catch is CancellationError {
            guard revision == resultsRevision else { return }
            if let newIndex = results.firstIndex(where: { $0.id == id }) {
                results[newIndex] = results[newIndex].updatingDetailState(isLoading: false, errorMessage: nil)
            }
        } catch {
            guard revision == resultsRevision else { return }
            if let newIndex = results.firstIndex(where: { $0.id == id }) {
                results[newIndex] = results[newIndex].updatingDetailState(isLoading: false, errorMessage: "Не удалось загрузить описание: \(error.localizedDescription)")
            }
        }
    }

    /// Every consumer joins one detail request. Cancelling a subscriber is immediate;
    /// the network task is cancelled only when its last subscriber leaves.
    private func sharedDetails(id: String, refresh: Bool = false) async throws -> HHVacancyDetails {
        try Task.checkCancellation()
        if !refresh, let cached = detailsCache[id] { return cached }
        let subscriber = DetailSubscription()
        // A refresh starts a new generation; its card must not join an older response.
        let key = "\(resultsRevision):\(id)"
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HHVacancyDetails, Error>) in
                joinDetails(id: id, key: key, subscriber: subscriber, continuation: continuation)
            }
        } onCancel: {
            subscriber.cancel()
        }
    }

    private func joinDetails(id: String, key: String, subscriber: DetailSubscription,
                             continuation: CheckedContinuation<HHVacancyDetails, Error>) {
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        if let flight = detailFlights[key], flight.addIfActive(subscriber.id, continuation) {
            subscriber.attach(flight)
            return
        }
        let flight = DetailFlight()
        flight.add(subscriber.id, continuation)
        subscriber.attach(flight)
        let token = flight.token
        let client = apiClient
        let task = Task { [weak self] in
            let result: Result<HHVacancyDetails, Error>
            do {
                try Task.checkCancellation()
                let details = try await client.vacancyDetails(id: id)
                try Task.checkCancellation()
                result = .success(details)
            } catch { result = .failure(error) }
            self?.finishDetails(key: key, token: token, result: result)
        }
        flight.setTask(task)
        detailFlights[key] = flight
    }

    private func finishDetails(key: String, token: UUID, result: Result<HHVacancyDetails, Error>) {
        guard let flight = detailFlights[key], flight.token == token else { return }
        detailFlights[key] = nil
        flight.finish(result)
    }

    private func apply(details: HHVacancyDetails, at index: Int) {
        let old = results[index]
        let value = VacancySearchResult(
            id: old.id,
            summary: old.summary,
            details: details,
            location: old.location,
            isDetailLoaded: true,
            persistedSalaryText: old.persistedSalaryText,
            isArchived: details.archived ?? old.isArchived,
            archiveCheckedAt: details.archived == nil ? old.archiveCheckedAt : currentDate()
        )
        results[index] = value
        if let previous = cache {
            cache = VacancySearchCache(values: results, updatedAt: previous.updatedAt, issues: previous.issues)
            let snapshot = VacancySnapshot(values: results, issues: previous.issues, updatedAt: previous.updatedAt)
            snapshotSaveTask?.cancel()
            let store = snapshotStore
            snapshotSaveTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    try await Task.detached { try store?.save(snapshot) }.value
                } catch is CancellationError {} catch {
                    self?.snapshotWarning = "Не удалось сохранить описание: \(error.localizedDescription)"
                }
            }
        }
        statusMessage = "Описание вакансии загружено."
    }

    func openVacancyURL(id: String) {
        guard let raw = result(id)?.alternateURL, let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
    }

    @discardableResult
    func copyVacancyURL(id: String) -> Bool {
        guard let raw = result(id)?.alternateURL else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(raw, forType: .string)
    }

    @discardableResult
    func exportVacancyPDF(id: String) async -> Bool {
        guard !isExportingPersonalPDF, !isExportingBulkPDF, !isExportingStatisticsPDF, let source = result(id) else { return false }
        isExportingPersonalPDF = true
        defer { isExportingPersonalPDF = false }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.canCreateDirectories = true
        panel.nameFieldStringValue = VacancyPDFDefaults.personalFileName(vacancyID: source.id, vacancyName: source.name)
        guard panel.runModal() == .OK, let destination = panel.url else { return false }
        do {
            let prepared = try await preparedForPDF(source)
            let worker = PDFExportWorker()
            try await worker.exportPersonal(
                vacancy: PDFVacancySnapshot(value: prepared),
                destination: destination
            )
            statusMessage = "Вакансия сохранена в PDF."
            return true
        } catch { statusMessage = "Не удалось сохранить PDF: \(error.localizedDescription)"; return false }
    }

    func exportVacanciesPDF() async {
        guard canExportBulkPDF else { return }
        isExportingBulkPDF = true
        defer { isExportingBulkPDF = false; bulkPDFExportProgress = nil }
        // Freeze local rows and membership before enrichment can suspend this actor.
        let snapshot = displayedResults
        let filters = statisticsReportSnapshot().documentContext.filters.merging(["Сортировка": "Сначала новые"]) { _, new in new }
        do {
            var values: [VacancySearchResult] = []
            for (index, source) in snapshot.enumerated() {
                try Task.checkCancellation()
                values.append(try await preparedForPDF(source))
                bulkPDFExportProgress = .init(completedVacancies: index + 1, totalVacancies: snapshot.count)
            }
            try Task.checkCancellation()
            let outcome = try await bulkPDFExporter.export(vacancies: values, filters: filters) { [weak self] in self?.bulkPDFExportProgress = $0 }
            switch outcome {
            case .cancelled: break
            case .exported(let files, let pages): statusMessage = "Сохранено PDF: \(files), страниц: \(pages)."
            }
        } catch is CancellationError {
            statusMessage = "Сохранение вакансий в PDF отменено."
        } catch {
            statusMessage = "Не удалось сохранить вакансии в PDF: \(error.localizedDescription)"
        }
    }

    func statisticsReportSnapshot() -> VacancyStatisticsReport {
        let employer = employerFilterOptions.first { $0.id == selectedEmployerID }?.title ?? selectedEmployerID
        let region = regionFilterOptions.first { $0.id == selectedRegionID }?.title ?? selectedRegionID
        var note = "Категория: \(fieldInstitutionsOnly ? "Полевые учреждения" : "Все вакансии"). "
        if let cache, !cache.issues.isEmpty { note += "Выгрузка общего списка неполная, работодателей с пропусками: \(cache.issues.count)." }
        if errorMessage != nil { note += " Последнее обновление не завершено" }
        var report = VacancyStatisticsReport(
            entries: displayedResults.map(VacancyStatisticsReport.Entry.init),
            modeName: "hh.ru",
            employerID: selectedEmployerID,
            employerName: employer,
            regionID: selectedRegionID,
            regionName: region,
            createdAt: currentDate(),
            timeZoneIdentifier: TimeZone.current.identifier,
            sourceNote: note
        )
        report.categoryName = fieldInstitutionsOnly ? "Полевые учреждения" : "Все вакансии"
        return report
    }

    func exportStatisticsPDF() async {
        guard canExportStatisticsPDF else { return }
        isExportingStatisticsPDF = true
        statisticsPDFExportMessage = nil
        defer { isExportingStatisticsPDF = false }
        // Capture the rows and filter labels together, before the save panel suspends UI work.
        let report = statisticsReportSnapshot()
        guard let destination = statisticsPDFDestination(report.fileName) else { return }
        do {
            let worker = PDFExportWorker()
            try await worker.exportStatistics(report: report, destination: destination)
            statisticsPDFExportMessage = "Статистический отчёт сохранён: \(report.entries.count) вакансий."
        } catch is CancellationError {
            statisticsPDFExportMessage = "Сохранение отчёта отменено."
        } catch {
            statisticsPDFExportMessage = "Не удалось сохранить отчёт: \(error.localizedDescription)"
        }
    }

    private static func chooseStatisticsPDFDestination(_ fileName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = fileName
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func preparedForPDF(_ source: VacancySearchResult) async throws -> VacancySearchResult {
        try Task.checkCancellation()
        if source.isDetailLoaded, source.details.observationID != nil { return source }
        do {
            let details: HHVacancyDetails
            if let cached = detailsCache[source.id] {
                details = cached
            } else {
                details = try await sharedDetails(id: source.id)
            }
            try Task.checkCancellation()
            detailsCache[source.id] = details
            return VacancySearchResult(
                id: source.id,
                summary: source.summary,
                details: details,
                location: source.location,
                isDetailLoaded: true,
                persistedSalaryText: source.persistedSalaryText,
                isArchived: details.archived ?? source.isArchived,
                archiveCheckedAt: source.archiveCheckedAt
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch { throw error }
    }

    private func result(_ id: String) -> VacancySearchResult? { unfilteredResults.first { $0.id == id } }
    private func reconcileExpanded() {
        if let id = expandedVacancyID, !displayedResults.contains(where: { $0.id == id }) {
            expandedVacancyID = nil
            detailTask?.cancel()
        }
    }
    private func normalizeFilters() {
        if !employerFilterOptions.contains(where: { $0.id == selectedEmployerID }) { selectedEmployerID = "all" }
        if !regionFilterOptions.contains(where: { $0.id == selectedRegionID }) { selectedRegionID = "all" }
    }
    private func orderedNewestFirst(_ values: [VacancySearchResult]) -> [VacancySearchResult] {
        let datedValues = values.map { value in
            (value: value, date: Self.publicationDateParser.date(from: value.publishedAt))
        }
        return datedValues.sorted { left, right in
            if left.date != right.date { return (left.date ?? .distantPast) > (right.date ?? .distantPast) }
            let comparison = left.value.name.localizedCaseInsensitiveCompare(right.value.name)
            if comparison == .orderedSame { return left.value.id < right.value.id }
            return comparison == .orderedAscending
        }.map(\.value)
    }
    private func timeMessage(_ date: Date) -> String {
        VacancyDisplayFormat.updatedAt(date)
    }
}
