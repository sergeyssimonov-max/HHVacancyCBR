import AppKit
import Foundation

actor PDFExportWorker {
    private struct PreparedPart: Sendable {
        let file: URL
        let pageCount: Int
        let context: DocumentContext
    }

    private var preparedParts: [PreparedPart]?
    private var stagingDirectory: URL?
    deinit { if let stagingDirectory { try? FileManager.default.removeItem(at: stagingDirectory) } }

    struct PreparedExport: Sendable {
        let partCount: Int
        let pageCount: Int
    }

    init() {}

    /// Trudvsem uses plain source fields, so formatting can run on the worker too.
    func prepareTrudvsem(
        vacancies: [TrudvsemVacancy],
        filters: [String: String] = [:],
        progress: @escaping @MainActor @Sendable (BulkPDFExportProgress) -> Void
    ) async throws -> PreparedExport {
        discardPreparedExport()
        let observations = try verifiedObservations(for: vacancies.map(\.context))
        var snapshots: [PDFVacancySnapshot] = []
        snapshots.reserveCapacity(vacancies.count)
        for vacancy in vacancies {
            try Task.checkCancellation()
            snapshots.append(autoreleasepool {
                TrudvsemPDFFormatter.personal(vacancy, records: vacancy.context.observationIDs.compactMap { observations[$0] }, includeSourceEvidence: false)
            })
        }
        return try await prepare(vacancies: PDFVacanciesSnapshot(snapshots: snapshots), filters: filters, progress: progress)
    }

    func exportTrudvsemPersonal(vacancy: TrudvsemVacancy, destination: URL) throws {
        try Task.checkCancellation()
        try exportDocument(document: TrudvsemPDFFormatter.personal(vacancy), destination: destination)
    }

    func exportTrudvsemStatistics(vacancies: [TrudvsemVacancy], filters: [String: String], destination: URL) throws {
        try Task.checkCancellation()
        try exportDocument(document: TrudvsemPDFFormatter.statistics(vacancies, filters: filters), destination: destination)
    }

    private func verifiedObservations(for contexts: [DocumentContext]) throws -> [String: APIObservation] {
        var observations: [String: APIObservation] = [:]
        for id in Set(contexts.flatMap(\.observationIDs)) {
            try Task.checkCancellation()
            observations[id] = try? PDFSourceEvidence.shared.observation(id)
        }
        return observations
    }

    func prepare(
        vacancies: PDFVacanciesSnapshot,
        filters: [String: String] = [:],
        progress: @escaping @MainActor @Sendable (BulkPDFExportProgress) -> Void
    ) async throws -> PreparedExport {
        discardPreparedExport()
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("VacancyPDF-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        stagingDirectory = staging
        var succeeded = false
        defer { if !succeeded { discardPreparedExport() } }
        try Task.checkCancellation()
        struct Chunk {
            var pages: [VacanciesPDFExporter.Page]
            var contexts: [DocumentContext]
        }
        let started = PDFSourceJSON.timestamp(Date())
        // Cache only within this export. Publication verifies the raw materials again.
        let observations = try verifiedObservations(for: vacancies.values.map(\.context))
        struct EvidenceKey: Hashable {
            let source: String
            let observationIDs: [String]
            let hasMissingEvidence: Bool
        }
        var evidencePageCounts: [EvidenceKey: Int] = [:]
        var chunks: [Chunk] = []
        var current = Chunk(pages: [], contexts: [])
        func context(_ contexts: [DocumentContext]) -> DocumentContext {
            DocumentContext(kind: "Все вакансии", vacancyIDs: Array(Set(contexts.flatMap(\.vacancyIDs))).sorted(),
                observationIDs: contexts.flatMap(\.observationIDs), filters: filters,
                source: contexts.first?.source ?? .hh)
        }
        func header(_ c: DocumentContext, part: Int, total: Int, continuation: Bool) -> [VacanciesPDFExporter.Page] {
            let builder = VacancyPDFDocumentBuilder()
            builder.documentHeader(c)
            builder.field("Сформирован", VacancyPDFStyle.utcDate(started))
            builder.field("Часть", "\(part) из \(total)")
            if continuation { builder.field("Продолжение", "Полная карточка вакансии продолжается с предыдущей части") }
            builder.identify(c)
            return autoreleasepool { VacanciesPDFExporter.pages(for: builder.document) }
        }
        func evidencePages(_ c: DocumentContext) -> [VacanciesPDFExporter.Page] {
            let builder = VacancyPDFDocumentBuilder()
            builder.sourceEvidence(c, records: c.observationIDs.compactMap { observations[$0] })
            builder.identify(c)
            return autoreleasepool { VacanciesPDFExporter.pages(for: builder.document) }
        }
        func headerPageCount(_ c: DocumentContext) -> Int {
            let records = c.observationIDs.compactMap { observations[$0] }
            let covered = Set(records.flatMap(\.vacancyIDs))
            let missing = records.count < c.observationIDs.count || !Set(c.vacancyIDs).isSubset(of: covered)
            let key = EvidenceKey(source: c.source.rawValue, observationIDs: c.observationIDs, hasMissingEvidence: missing)
            let evidenceCount: Int
            if let cached = evidencePageCounts[key] { evidenceCount = cached }
            else {
                evidenceCount = evidencePages(c).count
                evidencePageCounts[key] = evidenceCount
            }
            return header(c, part: 999999, total: 999999, continuation: true).count + evidenceCount
        }
        let limit = VacanciesPDFExporter.maximumPagesPerFile
        for (index, vacancy) in vacancies.values.enumerated() {
            try Task.checkCancellation()
            var pages = autoreleasepool { VacanciesPDFExporter.pages(for: vacancy.attributedDocument) }[...]
            let candidateContexts = current.contexts + [vacancy.context]
            let overhead = headerPageCount(context(candidateContexts))
            if !current.pages.isEmpty && current.pages.count + pages.count + overhead > limit {
                chunks.append(current); current = Chunk(pages: [], contexts: [])
            }
            while !pages.isEmpty {
                try Task.checkCancellation()
                let contexts = current.contexts + [vacancy.context]
                let capacity = limit - headerPageCount(context(contexts)) - current.pages.count
                guard capacity > 0 else { throw PDFSourceError.invalid("Реквизиты источников превышают лимит части") }
                let count = min(capacity, pages.count)
                current.pages += pages.prefix(count); current.contexts = contexts
                pages = pages.dropFirst(count)
                if !pages.isEmpty { chunks.append(current); current = Chunk(pages: [], contexts: []) }
            }
            await progress(.init(completedVacancies: index + 1, totalVacancies: vacancies.values.count))
        }
        if !current.pages.isEmpty { chunks.append(current) }
        var parts: [PreparedPart] = []
        var previousIDs = Set<String>()
        var pageOffset = 0
        for index in chunks.indices {
            try Task.checkCancellation()
            let chunk = chunks[index]
            chunks[index] = Chunk(pages: [], contexts: [])
            await progress(.init(completedVacancies: vacancies.values.count, totalVacancies: vacancies.values.count,
                                 stage: "Формирование части \(index + 1) из \(chunks.count)"))
            let c = context(chunk.contexts)
            let continuation = !previousIDs.isDisjoint(with: c.vacancyIDs)
            let headerPages = header(c, part: index + 1, total: chunks.count, continuation: continuation)
            let combined = NSMutableAttributedString(attributedString: headerPages.last!.content)
            for page in chunk.pages { combined.append(page.content) }
            let bodyPages = autoreleasepool { VacanciesPDFExporter.pages(for: combined) }
            let pages = Array(headerPages.dropLast()) + bodyPages + evidencePages(c)
            guard pages.count <= limit else { throw PDFSourceError.invalid("Превышен лимит страниц") }
            let rendered = try autoreleasepool {
                try documentedData(pages: pages, context: c, pageOffset: pageOffset)
            }
            pageOffset += pages.count
            let file = staging.appendingPathComponent("part-\(index).pdf")
            try rendered.data.write(to: file, options: .atomic)
            parts.append(.init(file: file, pageCount: rendered.count, context: c))
            previousIDs = Set(c.vacancyIDs)
        }
        preparedParts = parts
        succeeded = true
        return PreparedExport(partCount: parts.count, pageCount: parts.reduce(0) { $0 + $1.pageCount })
    }

    func discardPreparedExport() {
        preparedParts = nil
        if let stagingDirectory { try? FileManager.default.removeItem(at: stagingDirectory) }
        stagingDirectory = nil
    }

    func exportDocument(document: PDFVacancySnapshot, destination: URL) throws {
        try Task.checkCancellation()
        let pages = VacanciesPDFExporter.pages(for: document.attributedDocument)
        let data = try documentedData(pages: pages, context: document.context).data
        try Task.checkCancellation()
        _ = try PDFNewFileWriter.write([data], names: [destination.lastPathComponent], in: destination.deletingLastPathComponent())
    }

    private func documentedData(pages: [VacanciesPDFExporter.Page], context: DocumentContext, pageOffset: Int = 0,
                                didRenderPage: (@Sendable (Int) -> Void)? = nil) throws -> (data: Data, count: Int) {
        let materials = try PDFSourceEvidence.shared.materials(for: context)
        let rendered = try VacanciesPDFExporter.pdfData(for: pages, pageOffset: pageOffset, didRenderPage: didRenderPage)
        let data = try PDFOriginalMaterials.embed(materials, in: rendered)
        try VacanciesPDFExporter.validatePDF(data: data, expectedPages: pages.count)
        return (data, pages.count)
    }

    func exportPersonal(
        vacancy: PDFVacancySnapshot,
        destination: URL,
        didRenderPage: (@Sendable (Int) -> Void)? = nil
    ) throws {
        try Task.checkCancellation()
        let pages = autoreleasepool {
            VacanciesPDFExporter.pages(for: vacancy.attributedDocument)
        }
        try Task.checkCancellation()
        let data = try documentedData(pages: pages, context: vacancy.context, didRenderPage: didRenderPage).data
        try Task.checkCancellation()
        _ = try PDFNewFileWriter.write([data], names: [destination.lastPathComponent], in: destination.deletingLastPathComponent())
    }

    func exportStatistics(report: VacancyStatisticsReport, destination: URL) throws {
        try Task.checkCancellation()
        let pages = try autoreleasepool {
            try VacanciesPDFExporter.pages(for: report.attributedDocument())
        }
        let data = try documentedData(pages: pages, context: report.documentContext).data
        try Task.checkCancellation()
        _ = try PDFNewFileWriter.write([data], names: [destination.lastPathComponent], in: destination.deletingLastPathComponent())
    }

    /// Writes the prepared parts as new files; see PDFNewFileWriter.
    func writePrepared(names: [String], directory: URL) throws -> [URL] {
        guard let parts = preparedParts else {
            throw VacanciesPDFExporter.ExportError.missingPreparedExport
        }
        defer { discardPreparedExport() }
        return try PDFNewFileWriter.writeFiles(parts.map(\.file), names: names, in: directory)
    }
}
