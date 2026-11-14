import AppKit
import Foundation

struct BulkPDFExportProgress: Equatable {
    let completedVacancies: Int
    let totalVacancies: Int
    var stage = "Подготовка вакансий"
}

/// A vacancy frozen for background rendering, with its HTML description already
/// imported on the main actor. The attributed string is not mutated after creation.
struct PDFVacancySnapshot: @unchecked Sendable {
    let context: DocumentContext
    let attributedDocument: NSAttributedString

    @MainActor
    init(value: VacancySearchResult, includeSourceEvidence: Bool = true) {
        context = DocumentContext.vacancy(value)
        attributedDocument = VacancyPDFFormatter.attributedDocument(for: value,
            importedDescription: VacancyPDFFormatter.importedDescription(for: value), context: context,
            includeSourceEvidence: includeSourceEvidence)
    }
    init(context: DocumentContext, document: NSAttributedString) {
        self.context = context; attributedDocument = document.copy() as! NSAttributedString
    }
}

struct PDFVacanciesSnapshot: @unchecked Sendable {
    let values: [PDFVacancySnapshot]

    @MainActor
    init(values: [VacancySearchResult]) {
        var snapshots: [PDFVacancySnapshot] = []
        snapshots.reserveCapacity(values.count)
        for value in values { snapshots.append(PDFVacancySnapshot(value: value, includeSourceEvidence: false)) }
        self.values = snapshots
    }

    init(snapshots: [PDFVacancySnapshot]) {
        values = snapshots
    }

    /// Imports descriptions one by one, letting the UI run between vacancies.
    @MainActor
    static func make(values: [VacancySearchResult]) async throws -> PDFVacanciesSnapshot {
        var snapshots: [PDFVacancySnapshot] = []
        snapshots.reserveCapacity(values.count)
        for value in values {
            try Task.checkCancellation()
            snapshots.append(PDFVacancySnapshot(value: value, includeSourceEvidence: false))
            await Task.yield()
        }
        return PDFVacanciesSnapshot(snapshots: snapshots)
    }
}

enum BulkPDFExportOutcome: Equatable {
    case cancelled
    case exported(fileCount: Int, pageCount: Int)
}

@MainActor
protocol VacanciesPDFExporting {
    func export(vacancies: [VacancySearchResult], progress: @escaping @MainActor @Sendable (BulkPDFExportProgress) -> Void) async throws -> BulkPDFExportOutcome
    func export(vacancies: [VacancySearchResult], filters: [String: String], progress: @escaping @MainActor @Sendable (BulkPDFExportProgress) -> Void) async throws -> BulkPDFExportOutcome
}
extension VacanciesPDFExporting {
    func export(vacancies: [VacancySearchResult], filters: [String: String], progress: @escaping @MainActor @Sendable (BulkPDFExportProgress) -> Void) async throws -> BulkPDFExportOutcome {
        try await export(vacancies: vacancies, progress: progress)
    }
}
