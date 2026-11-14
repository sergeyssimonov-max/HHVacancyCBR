import AppKit
import CoreGraphics
import Foundation

enum PDFVisualContentValidator {
    private static let rasterWidth = 160
    private static let whiteThreshold: UInt8 = 245
    private static let minimumInkPixels = 8

    static func pageHasVisibleInk(_ page: CGPDFPage) -> Bool {
        let mediaBox = page.getBoxRect(.mediaBox)
        guard mediaBox.width > 0, mediaBox.height > 0 else { return false }
        let rasterHeight = max(1, Int((CGFloat(rasterWidth) * mediaBox.height / mediaBox.width).rounded()))
        let bytesPerPixel = 4
        let bytesPerRow = rasterWidth * bytesPerPixel
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * rasterHeight)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
                width: rasterWidth,
                height: rasterHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            return false
        }

        let bounds = CGRect(x: 0, y: 0, width: rasterWidth, height: rasterHeight)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(bounds)
        context.concatenate(page.getDrawingTransform(
            .mediaBox,
            rect: bounds,
            rotate: 0,
            preserveAspectRatio: true
        ))
        context.drawPDFPage(page)

        var inkPixels = 0
        for offset in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            if pixels[offset] < whiteThreshold
                || pixels[offset + 1] < whiteThreshold
                || pixels[offset + 2] < whiteThreshold {
                inkPixels += 1
                if inkPixels >= minimumInkPixels { return true }
            }
        }
        return false
    }
}

@MainActor
final class VacanciesPDFExporter: VacanciesPDFExporting {
    nonisolated static let maximumPagesPerFile = 100

    fileprivate final class PageLayout: @unchecked Sendable {
        let source: NSAttributedString
        let storage: NSTextStorage
        let manager: NSLayoutManager
        let container: NSTextContainer

        init(_ text: NSAttributedString) {
            source = NSAttributedString(attributedString: text)
            let drawingText = NSMutableAttributedString(attributedString: source)
            drawingText.removeAttribute(.link, range: NSRange(location: 0, length: drawingText.length))
            storage = NSTextStorage(attributedString: drawingText)
            manager = NSLayoutManager()
            container = NSTextContainer(size: NSSize(
                width: VacancyPDFDefaults.paperSize.width - VacancyPDFDefaults.horizontalMargin * 2,
                height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            manager.ensureLayout(for: container)
        }
    }

    struct Page: @unchecked Sendable {
        fileprivate let layout: PageLayout
        fileprivate let range: NSRange
        fileprivate let top: CGFloat
        var content: NSAttributedString { layout.source.attributedSubstring(from: range) }

        fileprivate init(layout: PageLayout, range: NSRange, top: CGFloat) {
            self.layout = layout
            self.range = range
            self.top = top
        }

        init(content: NSAttributedString) {
            layout = PageLayout(content)
            range = NSRange(location: 0, length: content.length)
            top = 0
        }
    }

    enum ExportError: LocalizedError {
        case cannotCreatePDF
        case invalidPDF(String)
        case missingPreparedExport
        case noAvailableFileName

        var errorDescription: String? {
            switch self {
            case .cannotCreatePDF: return "Не удалось сформировать PDF-документ."
            case .invalidPDF(let name): return "Не удалось проверить PDF «\(name)»."
            case .missingPreparedExport: return "Не удалось подготовить PDF-документ."
            case .noAvailableFileName: return "Не удалось подобрать свободное имя PDF. Выберите другой каталог."
            }
        }
    }

    private let worker = PDFExportWorker()
    private let chooseDirectory: () -> URL?
    private let now: () -> Date
    init(
        chooseDirectory: (() -> URL?)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.chooseDirectory = chooseDirectory ?? { VacanciesPDFExporter.chooseExportDirectory() }
        self.now = now
    }

    func export(vacancies: [VacancySearchResult], progress: @escaping @MainActor @Sendable (BulkPDFExportProgress) -> Void) async throws -> BulkPDFExportOutcome {
        try await export(vacancies: vacancies, filters: [:], progress: progress)
    }

    func export(
        vacancies: [VacancySearchResult],
        filters: [String: String],
        progress: @escaping @MainActor @Sendable (BulkPDFExportProgress) -> Void
    ) async throws -> BulkPDFExportOutcome {
        let exportStartedAt = now()
        do {
            let prepared = try await worker.prepare(
                vacancies: try await PDFVacanciesSnapshot.make(values: vacancies),
                filters: filters, progress: progress
            )
            guard let directory = chooseDirectory() else {
                await worker.discardPreparedExport()
                return .cancelled
            }

            let names = (0..<prepared.partCount).map {
                Self.fileName(part: $0 + 1, totalParts: prepared.partCount, exportStartedAt: exportStartedAt)
            }
            progress(.init(completedVacancies: vacancies.count, totalVacancies: vacancies.count, stage: "Сохранение файлов"))
            let destinations = try await worker.writePrepared(names: names, directory: directory)
            return .exported(fileCount: destinations.count, pageCount: prepared.pageCount)
        } catch {
            await worker.discardPreparedExport()
            throw error
        }
    }

    static func configureDirectoryPanel(_ panel: NSOpenPanel) {
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Экспортировать"
    }

    static func chooseExportDirectory() -> URL? {
        let panel = NSOpenPanel()
        configureDirectoryPanel(panel)
        return panel.runModal() == .OK ? panel.url : nil
    }

    nonisolated static func fileName(
        part: Int,
        totalParts: Int,
        exportStartedAt: Date = Date()
    ) -> String {
        VacancyPDFDefaults.bulkFileName(
            part: part,
            totalParts: totalParts,
            exportStartedAt: exportStartedAt
        )
    }

    nonisolated static func validatePDF(at url: URL, expectedPages: Int) throws {
        guard let document = CGPDFDocument(url as CFURL) else {
            throw ExportError.invalidPDF(url.lastPathComponent)
        }
        try validatePDF(document, expectedPages: expectedPages, name: url.lastPathComponent)
    }

    nonisolated static func validatePDF(data: Data, expectedPages: Int) throws {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else {
            throw ExportError.invalidPDF("PDF")
        }
        try validatePDF(document, expectedPages: expectedPages, name: "PDF")
    }

    private nonisolated static func validatePDF(
        _ document: CGPDFDocument,
        expectedPages: Int,
        name: String
    ) throws {
        guard expectedPages > 0,
              document.numberOfPages == expectedPages,
              expectedPages > maximumPagesPerFile || document.numberOfPages <= maximumPagesPerFile,
              (1...document.numberOfPages).allSatisfy({ pageNumber in
                  guard let page = document.page(at: pageNumber) else { return false }
                  return PDFVisualContentValidator.pageHasVisibleInk(page)
              }) else {
            throw ExportError.invalidPDF(name)
        }
    }

    /// Lays the whole document out once, in a single container of unbounded height, and
    /// cuts pages at line boundaries by vertical position: linear in the document length.
    /// Short paragraphs that cross a page boundary move to the next page;
    /// a whitespace-only tail joins the previous page instead of becoming a blank page.
    nonisolated static func pages(for attributedText: NSAttributedString) -> [Page] {
        let layout = PageLayout(attributedText)
        let pageHeight = VacancyPDFDefaults.paperSize.height - VacancyPDFDefaults.verticalMargin * 2
        let lines: [(start: Int, minY: CGFloat, maxY: CGFloat)] = autoreleasepool {
            let layoutManager = layout.manager
            let container = layout.container
            var result: [(start: Int, minY: CGFloat, maxY: CGFloat)] = []
            layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) {
                rect, _, _, glyphRange, _ in
                let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                result.append((characters.location, rect.minY, rect.maxY))
            }
            return result
        }
        guard !lines.isEmpty else { return [Page(layout: layout, range: NSRange(location: 0, length: attributedText.length), top: 0)] }

        let source = attributedText.string as NSString
        var pageStarts = [0]
        var index = 1
        while index < lines.count {
            let first = pageStarts[pageStarts.count - 1]
            let firstTop: CGFloat = first == 0 ? 0 : lines[first].minY
            guard lines[index].maxY - firstTop > pageHeight else {
                index += 1
                continue
            }
            var next = index
            let paragraph = source.paragraphRange(for: NSRange(location: lines[index].start, length: 0))
            if paragraph.location > lines[first].start {
                var paragraphFirst = next
                while paragraphFirst > first + 1, lines[paragraphFirst].start > paragraph.location { paragraphFirst -= 1 }
                // Line starts are sorted; avoid scanning the entire document at every page break.
                var lower = index, upper = lines.count
                let paragraphEnd = NSMaxRange(paragraph)
                while lower < upper {
                    let middle = lower + (upper - lower) / 2
                    if lines[middle].start < paragraphEnd { lower = middle + 1 }
                    else { upper = middle }
                }
                let paragraphLast = max(index, lower - 1)
                // Oversized source paragraphs must use the remaining page space and continue.
                if lines[paragraphLast].maxY - lines[paragraphFirst].minY <= pageHeight / 3 { next = paragraphFirst }
            }
            var candidate = next
            while candidate > first {
                let previousParagraph = source.paragraphRange(for: NSRange(location: lines[candidate].start - 1, length: 0))
                guard attributedText.attribute(VacancyPDFStyle.keepWithNext, at: previousParagraph.location, effectiveRange: nil) as? Bool == true else { break }
                var previous = candidate - 1
                while previous > first, lines[previous - 1].start >= previousParagraph.location { previous -= 1 }
                guard previous > first, lines[index].maxY - lines[previous].minY <= pageHeight else { break }
                candidate = previous
            }
            pageStarts.append(candidate)
            index = candidate + 1
        }

        var pages: [Page] = []
        for (position, lineIndex) in pageStarts.enumerated() {
            let start = lines[lineIndex].start
            let end = position + 1 < pageStarts.count ? lines[pageStarts[position + 1]].start : attributedText.length
            guard end > start else { continue }
            let range = NSRange(location: start, length: end - start)
            if let previous = pages.last,
               source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages[pages.count - 1] = Page(layout: layout,
                    range: NSRange(location: previous.range.location, length: end - previous.range.location), top: previous.top)
            } else {
                pages.append(Page(layout: layout, range: range, top: lineIndex == 0 ? 0 : lines[lineIndex].minY))
            }
        }
        return pages.isEmpty ? [Page(layout: layout, range: NSRange(location: 0, length: attributedText.length), top: 0)] : pages
    }

    nonisolated static func pdfData(
        for pages: [Page],
        pageOffset: Int = 0,
        didRenderPage: (@Sendable (Int) -> Void)? = nil
    ) throws -> Data {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: VacancyPDFDefaults.paperSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportError.cannotCreatePDF
        }
        for (index, page) in pages.enumerated() {
            try Task.checkCancellation()
            autoreleasepool {
                context.beginPDFPage(nil)
                context.saveGState()
                context.setFillColor(NSColor.white.cgColor)
                context.fill(mediaBox)
                context.translateBy(x: 0, y: VacancyPDFDefaults.paperSize.height)
                context.scaleBy(x: 1, y: -1)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
                let manager = page.layout.manager
                let container = page.layout.container
                let glyphs = manager.glyphRange(forCharacterRange: page.range, actualCharacterRange: nil)
                let x = VacancyPDFDefaults.horizontalMargin
                let y = VacancyPDFDefaults.verticalMargin - page.top
                let contentRect = NSRect(x: x, y: VacancyPDFDefaults.verticalMargin,
                    width: VacancyPDFDefaults.paperSize.width - x * 2,
                    height: VacancyPDFDefaults.paperSize.height - VacancyPDFDefaults.verticalMargin * 2)
                context.saveGState()
                context.clip(to: contentRect)
                manager.drawBackground(forGlyphRange: glyphs, at: NSPoint(x: x, y: y))
                manager.drawGlyphs(forGlyphRange: glyphs, at: NSPoint(x: x, y: y))
                context.restoreGState()
                page.layout.source.enumerateAttribute(.link, in: page.range) { value, range, _ in
                    guard let value, let url = (value as? URL) ?? URL(string: String(describing: value)) else { return }
                    let linkGlyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                    manager.enumerateEnclosingRects(forGlyphRange: linkGlyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                        let visible = rect.offsetBy(dx: x, dy: y).intersection(contentRect)
                        guard !visible.isNull, !visible.isEmpty else { return }
                        context.setURL(url as CFURL, for: CGRect(x: visible.minX,
                            y: VacancyPDFDefaults.paperSize.height - visible.maxY,
                            width: visible.width, height: visible.height))
                    }
                }
                let footerY = VacancyPDFDefaults.paperSize.height - 30
                let rule = NSBezierPath()
                rule.move(to: NSPoint(x: VacancyPDFDefaults.horizontalMargin, y: footerY - 8))
                rule.line(to: NSPoint(x: VacancyPDFDefaults.paperSize.width - VacancyPDFDefaults.horizontalMargin, y: footerY - 8))
                VacancyPDFStyle.ink.setStroke()
                rule.lineWidth = 0.25
                rule.stroke()
                let footerAttributes: [NSAttributedString.Key: Any] = [
                    .font: VacancyPDFStyle.font(ofSize: 7), .foregroundColor: VacancyPDFStyle.ink
                ]
                let pageLabel = "\(pageOffset + index + 1)" as NSString
                pageLabel.draw(at: NSPoint(x: VacancyPDFDefaults.paperSize.width - VacancyPDFDefaults.horizontalMargin - pageLabel.size(withAttributes: footerAttributes).width, y: footerY), withAttributes: footerAttributes)
                NSGraphicsContext.restoreGraphicsState()
                context.restoreGState()
                context.endPDFPage()
            }
            didRenderPage?(index)
        }
        context.closePDF()
        return data as Data
    }
}
