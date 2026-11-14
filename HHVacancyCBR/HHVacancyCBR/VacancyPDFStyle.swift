import AppKit
import Foundation

enum VacancyPDFDefaults {
    static let paperSize = NSSize(width: 595.28, height: 841.89)
    static let horizontalMargin: CGFloat = 56
    static let verticalMargin: CGFloat = 48
    static func personalFileName(
        vacancyID: String,
        vacancyName: String,
        exportStartedAt: Date = Date()
    ) -> String {
        PDFFileNameBuilder.personal(
            vacancyID: vacancyID,
            title: vacancyName,
            exportStartedAt: exportStartedAt
        )
    }

    static func bulkFileName(
        part: Int,
        totalParts: Int,
        exportStartedAt: Date = Date()
    ) -> String {
        PDFFileNameBuilder.bulk(
            part: part,
            totalParts: totalParts,
            exportStartedAt: exportStartedAt
        )
    }
}

/// Shared monochrome typography for personal, bulk and statistical PDFs.
/// Fonts/colors are computed to avoid sharing non-Sendable AppKit objects.
enum VacancyPDFStyle {
    static func font(ofSize size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        // Avenir Next ships with supported macOS versions; the fallback remains available
        // if a user has disabled the document font.
        let heading = weight.rawValue >= NSFont.Weight.semibold.rawValue
        let preferred = heading ? "AvenirNext-DemiBold" : "AvenirNext-Regular"
        let fallback = heading ? "Arial-BoldMT" : "ArialMT"
        return NSFont(name: preferred, size: size)
            ?? NSFont(name: fallback, size: size)
            ?? NSFont.systemFont(ofSize: size, weight: weight)
    }
    static let bodySize: CGFloat = 9.5
    static var bodyFont: NSFont { font(ofSize: bodySize) }
    static var labelFont: NSFont { bodyFont }
    static var headingFont: NSFont { font(ofSize: 11.5, weight: .semibold) }
    static var titleFont: NSFont { font(ofSize: 17, weight: .semibold) }
    static var ink: NSColor { .black }
    static let documentKind = NSAttributedString.Key("HHDocumentKind")
    static let keepWithNext = NSAttributedString.Key("VacancyPDFKeepWithNext")

    static func publicationDate(_ value: String?, timeZone: TimeZone = .current) -> String {
        guard let date = HHPublicationDateParser().date(from: value) else { return "Не указана" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = timeZone
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss XXX"
        return formatter.string(from: date)
    }

    static func utcDate(_ value: String) -> String {
        guard let date = PDFSourceJSON.date(value) else { return value }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss 'UTC'"
        return formatter.string(from: date)
    }
}
