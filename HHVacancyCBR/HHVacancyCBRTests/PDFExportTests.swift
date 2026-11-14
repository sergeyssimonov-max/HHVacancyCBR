import AppKit
import Foundation
import PDFKit
import XCTest
import SwiftUI
@testable import HHVacancyCBR

extension HHVacancyCBRTests {

    func testApplicationIdentityAndPDFNamesAreIndependent() throws {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "local.sergey.HHVacancyCBR")
        XCTAssertEqual(ApplicationSupportLocation.directoryName, "HHVacancyCBR")
        XCTAssertTrue(VacancyPDFDefaults.personalFileName(vacancyID: "1", vacancyName: "Аналитик").hasPrefix("цбвакансии_"))
        XCTAssertTrue(VacancyPDFDefaults.bulkFileName(part: 1, totalParts: 1).hasPrefix("цбвакансии_"))
    }

    @MainActor
    func testBulkPDFCollisionCreatesSuffixAndPreservesExistingFile() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_788_400_000)
        let name = VacanciesPDFExporter.fileName(part: 1, totalParts: 1, exportStartedAt: date)
        let original = directory.appendingPathComponent(name)
        let originalData = Data("existing user file".utf8)
        try originalData.write(to: original)
        let exporter = VacanciesPDFExporter(chooseDirectory: { directory }, now: { date })
        let outcome = try await exporter.export(vacancies: [makePDFVacancy(id: "suffix")]) { _ in }
        guard case .exported(let count, let pages) = outcome else { return XCTFail("Expected exported PDF") }
        XCTAssertEqual(count, 1)
        XCTAssertGreaterThan(pages, 0)
        XCTAssertLessThanOrEqual(pages, 100)
        XCTAssertEqual(try Data(contentsOf: original), originalData)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pdf" && $0.lastPathComponent != name }
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(try XCTUnwrap(files.first).lastPathComponent.hasSuffix("_2.pdf"))
        XCTAssertNotNil(PDFDocument(url: try XCTUnwrap(files.first)))
        // No hidden staging, backup or recovery directories are left next to the PDFs.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    func testPDFWriterUsesFreeSuffixesForOccupiedAndDuplicateNamesWithinUTF8Limit() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("keep".utf8).write(to: directory.appendingPathComponent("report.pdf"))
        try Data("keep too".utf8).write(to: directory.appendingPathComponent("report_2.pdf"))
        let written = try PDFNewFileWriter.write(
            [Data("a".utf8), Data("b".utf8)], names: ["report.pdf", "report.pdf"], in: directory
        )
        XCTAssertEqual(written.map(\.lastPathComponent), ["report_3.pdf", "report_4.pdf"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("report.pdf")), Data("keep".utf8))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("report_2.pdf")), Data("keep too".utf8))
        XCTAssertEqual(try Data(contentsOf: written[1]), Data("b".utf8))

        let longName = PDFFileNameBuilder.fileName(base: String(repeating: "ёж🙂/", count: 300), fallback: "vacancy")
        let long = try PDFNewFileWriter.write([Data("1".utf8), Data("2".utf8)], names: [longName, longName], in: directory)
        let names = long.map(\.lastPathComponent)
        XCTAssertEqual(Set(names).count, 2)
        XCTAssertTrue(names.allSatisfy { $0.utf8.count <= 240 && !$0.contains("/") })
        XCTAssertTrue(names[1].hasSuffix("_2.pdf"))

        XCTAssertThrowsError(try PDFNewFileWriter.write(
            [Data()], names: ["report.pdf"], in: directory, maximumCandidates: 2
        )) { error in
            guard case VacanciesPDFExporter.ExportError.noAvailableFileName = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testPDFWriterRemovesItsFilesOnFailureOrCancellationAndKeepsExistingOnes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent("part-2.pdf")
        try Data("user file".utf8).write(to: existing)

        XCTAssertThrowsError(try PDFNewFileWriter.write(
            [Data("1".utf8), Data("2".utf8)], names: ["part-1.pdf", "part-2.pdf"], in: directory,
            beforeEachFile: { index in if index == 1 { throw CocoaError(.fileWriteUnknown) } }
        ))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["part-2.pdf"])

        let cancelled = Task {
            // Cancelled while the second file is written: the check before the third file stops the
            // batch and both files already written by this call are removed.
            try PDFNewFileWriter.write(
                [Data("1".utf8), Data("3".utf8), Data("4".utf8)], names: ["part-1.pdf", "part-3.pdf", "part-4.pdf"],
                in: directory,
                beforeEachFile: { index in if index == 1 { withUnsafeCurrentTask { $0?.cancel() } } }
            )
        }
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["part-2.pdf"])
        XCTAssertEqual(try Data(contentsOf: existing), Data("user file".utf8))
    }

    func testPDFWriterCancellationDuringLastFileRollsBackEntireBatch() async throws {
        for count in [1, 3] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let existing = directory.appendingPathComponent("existing.pdf")
            try Data("keep".utf8).write(to: existing)
            let task = Task {
                try PDFNewFileWriter.write(
                    Array(repeating: Data("PDF".utf8), count: count),
                    names: (0..<count).map { "part-\($0).pdf" }, in: directory,
                    beforeEachFile: { index in
                        if index == count - 1 { withUnsafeCurrentTask { $0?.cancel() } }
                    }
                )
            }
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.pdf"])
            XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
        }
    }

    func testPDFWriterRollbackPreservesReplacementFileAndSymlink() throws {
        for useSymlink in [false, true] {
            let directory = temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let replacement = directory.appendingPathComponent("part-0.pdf")
            let userFile = directory.appendingPathComponent("user.pdf")
            let userData = Data("user document".utf8)
            try userData.write(to: userFile)
            XCTAssertThrowsError(try PDFNewFileWriter.write(
                Array(repeating: Data("PDF".utf8), count: 3),
                names: ["part-0.pdf", "part-1.pdf", "part-2.pdf"], in: directory,
                beforeEachFile: { index in
                    guard index == 2 else { return }
                    try FileManager.default.removeItem(at: replacement)
                    if useSymlink {
                        try FileManager.default.createSymbolicLink(at: replacement, withDestinationURL: userFile)
                    } else {
                        try userData.write(to: replacement)
                    }
                    throw CocoaError(.fileWriteUnknown)
                }
            ))
            XCTAssertEqual(try Data(contentsOf: replacement), userData)
            XCTAssertEqual(try Data(contentsOf: userFile), userData)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("part-1.pdf").path))
            if useSymlink {
                XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: replacement.path), userFile.path)
            }
        }
    }




    @MainActor
    func testBulkPDFExportProducesBoundedValidPartsAndMainActorProgress() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixedDate = Date(timeIntervalSince1970: 1_788_400_000)
        let vacancies = (0..<101).map { makePDFVacancy(id: String($0)) }
        var progressValues: [BulkPDFExportProgress] = []
        var progressWasOnMainThread = true
        let exporter = VacanciesPDFExporter(
            chooseDirectory: { directory },
            now: { fixedDate }
        )

        let outcome = try await exporter.export(vacancies: vacancies) { progress in
            progressWasOnMainThread = progressWasOnMainThread && Thread.isMainThread
            progressValues.append(progress)
        }

        if case .exported(let files, let pages) = outcome { XCTAssertGreaterThanOrEqual(files, 2); XCTAssertGreaterThanOrEqual(pages, files); XCTAssertLessThanOrEqual(pages, files * 100) } else { XCTFail("Expected files") }
        XCTAssertEqual(progressValues.first, .init(completedVacancies: 1, totalVacancies: 101))
        XCTAssertEqual(progressValues.last?.completedVacancies, 101)
        XCTAssertEqual(progressValues.last?.stage, "Сохранение файлов")
        XCTAssertTrue(progressValues.allSatisfy { $0.totalVacancies == 101 })
        XCTAssertTrue(zip(progressValues, progressValues.dropFirst()).allSatisfy {
            $0.completedVacancies <= $1.completedVacancies
        })
        XCTAssertGreaterThanOrEqual(progressValues.filter { $0.completedVacancies == 101 }.count, 1)
        XCTAssertTrue(progressWasOnMainThread)

        let pdfs = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "pdf" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertGreaterThanOrEqual(pdfs.count, 2)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, pdfs.count, "Only the PDFs are written")
        for url in pdfs {
            let count = try XCTUnwrap(PDFDocument(url: url)).pageCount
            XCTAssertLessThanOrEqual(count, 100)
            try VacanciesPDFExporter.validatePDF(at: url, expectedPages: count)
        }
        let documents = try pdfs.map { try XCTUnwrap(PDFDocument(url: $0)) }
        let text = try documents.map(extractedStatisticsText).joined(separator: "\n")
        var previous = text.startIndex
        for vacancy in vacancies {
            let titleLine = vacancy.name + "\n"
            XCTAssertEqual(text.components(separatedBy: titleLine).count - 1, 1)
            let range = try XCTUnwrap(text.range(of: titleLine))
            XCTAssertGreaterThanOrEqual(range.lowerBound, previous)
            previous = range.upperBound
        }
        for document in documents {
            XCTAssertNotNil(document.documentAttributes?[PDFDocumentAttribute.creationDateAttribute] as? Date)
            XCTAssertNotNil(document.documentAttributes?[PDFDocumentAttribute.producerAttribute] as? String)
        }
    }

    @MainActor
    func testCancelledBulkPDFSelectionReleasesPreparationAndAllowsNextExport() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var selectedDirectory: URL?
        let exporter = VacanciesPDFExporter(
            chooseDirectory: { selectedDirectory },
            now: { Date(timeIntervalSince1970: 1_788_400_000) }
        )
        let vacancy = makePDFVacancy(id: "cancel-retry")

        let cancelled = try await exporter.export(vacancies: [vacancy]) { _ in }
        XCTAssertEqual(cancelled, .cancelled)

        selectedDirectory = directory
        let completed = try await exporter.export(vacancies: [vacancy]) { _ in }
        guard case .exported(let count, let pages) = completed else { return XCTFail("Expected exported PDF after cancellation") }
        XCTAssertEqual(count, 1)
        XCTAssertGreaterThan(pages, 0)
        XCTAssertLessThanOrEqual(pages, 100)
    }

    func testPDFListContinuationRetainsIndentAndLinkAcrossPages() throws {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = 4
        style.headIndent = 18
        let url = URL(string: "https://example.com/list")!
        let source = (0..<120).map { String(format: "line%03d", $0) }.joined(separator: "\u{2028}")
        let text = NSAttributedString(string: source, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .paragraphStyle: style, .link: url
        ])
        let pages = VacanciesPDFExporter.pages(for: text)
        XCTAssertGreaterThan(pages.count, 1)
        let pdf = try XCTUnwrap(PDFDocument(data: VacanciesPDFExporter.pdfData(for: pages)))
        for index in 1..<pages.count {
            let firstLine = try XCTUnwrap(pages[index].content.string.components(separatedBy: "\u{2028}").first)
            let page = try XCTUnwrap(pdf.page(at: index))
            let pageString = try XCTUnwrap(page.string) as NSString
            let range = pageString.range(of: firstLine)
            XCTAssertNotEqual(range.location, NSNotFound)
            let selection = try XCTUnwrap(page.selection(for: range))
            XCTAssertEqual(selection.bounds(for: page).minX, VacancyPDFDefaults.horizontalMargin + 18, accuracy: 2)
            XCTAssertTrue(page.annotations.contains { $0.url == url })
        }
    }

    @MainActor
    func testPersonalPDFWorkerCreatesAtomicValidDocument() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("personal.pdf")
        let worker = PDFExportWorker()

        try await worker.exportPersonal(
            vacancy: PDFVacancySnapshot(value: makePDFVacancy(id: "personal")),
            destination: destination
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        try VacanciesPDFExporter.validatePDF(at: destination, expectedPages: 2)
        let text = try XCTUnwrap(PDFDocument(url: destination)?.string)
        XCTAssertFalse(text.contains("Идентификатор документа"))
    }

    func testPersonalPDFCancellationOnLastPageNeverPublishesAndAllowsRetry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let vacancy = makePDFVacancy(id: "last-page-cancel")
        let worker = PDFExportWorker()
        let originalURL = directory.appendingPathComponent("original.pdf")
        try await worker.exportPersonal(vacancy: .init(value: makePDFVacancy(id: "original")), destination: originalURL)
        let original = try Data(contentsOf: originalURL)
        for existing in [false, true] {
            let destination = directory.appendingPathComponent(existing ? "existing.pdf" : "new.pdf")
            if existing { try original.write(to: destination, options: .atomic) }
            let task = Task {
                try await worker.exportPersonal(vacancy: .init(value: vacancy), destination: destination) { _ in
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
            do {
                try await task.value
                XCTFail("Cancellation on the final page must prevent publication")
            } catch is CancellationError {
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            if existing {
                XCTAssertEqual(try Data(contentsOf: destination), original)
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            }
            try await worker.exportPersonal(vacancy: .init(value: vacancy), destination: destination)
            let pdf = try XCTUnwrap(PDFDocument(url: existing ? directory.appendingPathComponent("existing_2.pdf") : destination))
            XCTAssertEqual(pdf.pageCount, 2)
            XCTAssertTrue(pdf.string?.contains("last-page-cancel") == true)
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       Set(["original.pdf", "existing.pdf", "existing_2.pdf", "new.pdf"]))
    }




    @MainActor
    func testLargePDFPreparationAllowsFilterChangesAndInteractiveHHDetails() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let (model, client, _) = makeStatisticsExportModel(directory: directory)
        await model.search()
        let initialSearchRequests = await client.searchRequestCount
        let worker = PDFExportWorker()
        let snapshot = PDFVacanciesSnapshot(values: (0..<100).map { makePDFVacancy(id: "joint-\($0)") })
        var completed = 0
        let preparation = Task {
            try await worker.prepare(vacancies: snapshot) { completed = $0.completedVacancies }
        }
        var interactionsDuringPDF = 0
        for index in 0..<20 {
            if completed < 100 { interactionsDuringPDF += 1 }
            model.selectedEmployerID = index.isMultiple(of: 2) ? "bank_of_russia" : "all"
            model.selectedRegionID = index.isMultiple(of: 2) ? "subject:1" : "all"
            XCTAssertEqual(model.displayedResults.count, index.isMultiple(of: 2) ? 1 : 5)
            await model.loadVacancyDetails(id: index.isMultiple(of: 2) ? "filter-moscow" : "filter-ekb")
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let prepared = try await preparation.value
        XCTAssertGreaterThan(interactionsDuringPDF, 1)
        XCTAssertGreaterThanOrEqual(prepared.pageCount, prepared.partCount)
        XCTAssertLessThanOrEqual(prepared.pageCount, prepared.partCount * 100)
        XCTAssertEqual(completed, 100)
        let details = await client.requestedDetailIDs
        let searches = await client.searchRequestCount
        XCTAssertEqual(details, ["filter-moscow", "filter-ekb"])
        XCTAssertEqual(searches, initialSearchRequests)
        await worker.discardPreparedExport()
        await model.refreshVacancies()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.displayedResults.count, 5)
    }

    @MainActor
    func testRepeatedBulkPDFEnrichmentReusesSessionDetailsWithoutChangingSnapshot() async {
        let client = PDFEnrichmentClient()
        let exporter = PDFEnrichmentExporter()
        let model = await enrichmentModel(client: client, exporter: exporter)
        await model.exportVacanciesPDF()
        let firstCount = await client.requests
        XCTAssertEqual(firstCount, 3)
        await client.setError(HHAPIError.rateLimited(retryAfterSeconds: 60))
        await model.exportVacanciesPDF()
        let repeatedCount = await client.requests
        XCTAssertEqual(repeatedCount, firstCount)
        XCTAssertEqual(exporter.snapshots.count, 2)
        XCTAssertEqual(exporter.snapshots[0].map(\.id), exporter.snapshots[1].map(\.id))
        XCTAssertEqual(exporter.snapshots[0].map(\.details), exporter.snapshots[1].map(\.details))
        XCTAssertTrue(exporter.snapshots[1].allSatisfy { $0.isDetailLoaded && $0.exportDataNotice == nil })
    }

    @MainActor
    func testFailedBulkPDFEnrichmentIsNotCachedAndCanRecover() async {
        let client = PDFEnrichmentClient(error: URLError(.timedOut))
        let exporter = PDFEnrichmentExporter()
        let model = await enrichmentModel(client: client, exporter: exporter)
        await model.exportVacanciesPDF()
        await client.setError(nil)
        await model.exportVacanciesPDF()
        let count = await client.requests
        XCTAssertEqual(count, 4)
        XCTAssertEqual(exporter.snapshots.count, 1)
        XCTAssertTrue(exporter.snapshots[0].allSatisfy { $0.isDetailLoaded && $0.exportDataNotice == nil })
    }

    @MainActor
    func testBulkPDFEnrichmentStopsOnAccessRestrictionsAndAllowsRetry() async {
        let errors: [HHAPIError] = [.unauthorized, .forbidden(requestID: "test"),
            .rateLimited(retryAfterSeconds: 60), .captchaRequired(requestID: "test"),
            .missingApplicationToken, .placeholderApplicationToken]
        for error in errors {
            let client = PDFEnrichmentClient(error: error)
            let exporter = PDFEnrichmentExporter()
            let model = await enrichmentModel(client: client, exporter: exporter)
            await model.exportVacanciesPDF()
            let stoppedCount = await client.requests
            XCTAssertEqual(stoppedCount, 1, "\(error)")
            XCTAssertEqual(exporter.snapshots.count, 0, "Restricted export must not be presented as complete")
            XCTAssertFalse(model.isExportingBulkPDF)
            XCTAssertNil(model.bulkPDFExportProgress)
            XCTAssertTrue(model.canExportBulkPDF)
            XCTAssertTrue(model.statusMessage?.contains(error.localizedDescription) == true)
            await client.setError(nil)
            await model.exportVacanciesPDF()
            let retryCount = await client.requests
            XCTAssertEqual(retryCount, 4)
            XCTAssertEqual(exporter.snapshots.count, 1)
            XCTAssertEqual(exporter.snapshots.first?.count, 3)
        }
    }

    @MainActor
    func testBulkPDFEnrichmentPropagatesCancellationWithoutPublishing() async {
        let client = PDFEnrichmentClient(error: CancellationError())
        let exporter = PDFEnrichmentExporter()
        let model = await enrichmentModel(client: client, exporter: exporter)
        await model.exportVacanciesPDF()
        let count = await client.requests
        XCTAssertEqual(count, 1)
        XCTAssertTrue(exporter.snapshots.isEmpty)
        XCTAssertFalse(model.isExportingBulkPDF)
        XCTAssertNil(model.bulkPDFExportProgress)
        XCTAssertEqual(model.statusMessage, "Сохранение вакансий в PDF отменено.")
    }

    @MainActor
    func testBulkPDFEnrichmentTaskCancellationStopsInFlightAndAllowsNextExport() async throws {
        let client = PDFEnrichmentClient(delay: 300_000_000)
        let exporter = PDFEnrichmentExporter()
        let model = await enrichmentModel(client: client, exporter: exporter)
        let task = Task { await model.exportVacanciesPDF() }
        for _ in 0..<1000 {
            if await client.requests == 1 { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        await task.value
        let count = await client.requests
        XCTAssertEqual(count, 1)
        XCTAssertTrue(exporter.snapshots.isEmpty)
        XCTAssertTrue(model.canExportBulkPDF)
        await client.setDelay(0)
        await model.exportVacanciesPDF()
        XCTAssertEqual(exporter.snapshots.count, 1)
    }

    @MainActor
    func testBulkPDFFailsClosedWhenFullDescriptionIsUnavailable() async {
        for error in [HHAPIError.requestFailed(statusCode: 404, message: nil) as Error, URLError(.timedOut)] {
            let client = PDFEnrichmentClient(error: error)
            let exporter = PDFEnrichmentExporter()
            let model = await enrichmentModel(client: client, exporter: exporter)
            await model.exportVacanciesPDF()
            let count = await client.requests
            XCTAssertEqual(count, 1)
            XCTAssertTrue(exporter.snapshots.isEmpty)
            XCTAssertNotNil(model.statusMessage)
        }
    }

    @MainActor
    func testThreeTrudPDFModesAttachExactSourcesAndRejectMissingEvidence() async throws {
        let values = [try TrudFixture.documented("one"), try TrudFixture.documented("two")]
        let dir = temporaryDirectory(), worker = PDFExportWorker()
        let documents = [TrudvsemPDFFormatter.personal(values[0]), TrudvsemPDFFormatter.statistics(values, filters: ["Регион": "Москва"])]
        for (index, document) in documents.enumerated() {
            let url = dir.appendingPathComponent("mode\(index).pdf")
            try await worker.exportDocument(document: document, destination: url)
            let data = try Data(contentsOf: url), pdf = try XCTUnwrap(PDFDocument(data: data))
            XCTAssertGreaterThan(pdf.pageCount, 0)
            XCTAssertTrue(pdf.string?.contains("trudvsem.ru") == true)
            XCTAssertFalse(pdf.string?.contains("HeadHunter") == true)
            for material in try PDFSourceEvidence.shared.materials(for: document.context) { XCTAssertNotNil(data.range(of: material.data)) }
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("/EmbeddedFiles"))
        }
        let prepared = try await worker.prepareTrudvsem(vacancies: values, filters: ["Регион": "Москва"]) { _ in }
        let urls = try await worker.writePrepared(names: (0..<prepared.partCount).map { "bulk\($0).pdf" }, directory: dir)
        XCTAssertEqual(urls.count, prepared.partCount)
        for url in urls {
            let pdf = try XCTUnwrap(PDFDocument(url: url)); XCTAssertLessThanOrEqual(pdf.pageCount, 100)
            XCTAssertTrue(pdf.string?.contains("Москва") == true)
        }
        let missing = PDFVacancySnapshot(context: .init(kind: "Missing", vacancyIDs: ["missing"], source: .trudvsem), document: NSAttributedString(string: "Missing evidence"))
        try await worker.exportDocument(document: missing, destination: dir.appendingPathComponent("missing.pdf"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("missing.pdf").path))
    }
}
