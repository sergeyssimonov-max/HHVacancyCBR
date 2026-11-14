import CryptoKit
import Foundation

enum PDFFileNameBuilder {
    static let maximumUTF8Length = 240

    static func statisticsReport(_ report: VacancyStatisticsReport) -> String {
        // Keep both filter labels readable, even when one is exceptionally long.
        let labels = [report.modeName, report.employerName, report.regionName].map {
            prefixFittingUTF8Budget(sanitize($0, fallback: "all"), budget: 48)
        }.joined(separator: "_")
        let configuration = [report.modeName, report.employerID, report.regionID].joined(separator: "\n")
        let digest = SHA256.hash(data: Data(configuration.utf8)).prefix(4)
            .map { String(format: "%02x", $0) }.joined()
        return fileName(
            base: "цбвакансии_\(timestamp(report.createdAt))_статистика_\(labels)",
            semanticSuffix: digest,
            fallback: "статистика_вакансий"
        )
    }

    static func personal(vacancyID: String, title: String, exportStartedAt: Date) -> String {
        let safeTitle = sanitize(title, fallback: "без названия")
        return fileName(
            base: "цбвакансии_\(timestamp(exportStartedAt))_\(safeTitle)",
            fallback: "вакансия"
        )
    }

    static func bulk(part: Int, totalParts: Int, exportStartedAt: Date, source: VacancySource = .hh) -> String {
        let stem = "цбвакансии_\(timestamp(exportStartedAt))_\(source.rawValue)_все_вакансии"
        guard totalParts > 1 else { return fileName(base: stem, fallback: "все_вакансии") }
        return fileName(
            base: stem,
            semanticSuffix: "том_\(String(format: "%03d", part))_из_\(String(format: "%03d", totalParts))",
            fallback: "все_вакансии"
        )
    }

    static func sanitize(_ value: String, fallback: String) -> String {
        var result = value.precomposedStringWithCanonicalMapping
        while result.lowercased().hasSuffix(".pdf") {
            result.removeLast(4)
        }
        result = snakeCaseScalars(result)
        if !result.isEmpty { return result }
        let safeFallback = snakeCaseScalars(fallback.precomposedStringWithCanonicalMapping)
        return safeFallback.isEmpty ? "vacancy" : safeFallback
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateFormat = "yyyy_MM_dd_HH_mm"
        return formatter.string(from: date)
    }

    static func fileName(
        base: String,
        semanticSuffix: String? = nil,
        fallback: String
    ) -> String {
        let safeBase = sanitize(base, fallback: fallback)
        let suffix = semanticSuffix.map { "_" + sanitize($0, fallback: "suffix") } ?? ""
        let budget = maximumUTF8Length - suffix.utf8.count - ".pdf".utf8.count
        precondition(budget > 0, "PDF filename suffix exceeds the supported byte budget")

        let fittedBase = prefixFittingUTF8Budget(safeBase, budget: budget)
        let fittedFallback = prefixFittingUTF8Budget(
            sanitize(fallback, fallback: "vacancy"),
            budget: budget
        )
        let finalBase = fittedBase.isEmpty ? fittedFallback : fittedBase
        precondition(!finalBase.isEmpty, "PDF filename base must not be empty")
        let result = finalBase + suffix + ".pdf"
        precondition(result.utf8.count <= maximumUTF8Length)
        return result
    }

    private static func prefixFittingUTF8Budget(_ value: String, budget: Int) -> String {
        var result = ""
        var usedBytes = 0
        for character in value {
            let text = String(character)
            // File URLs may expose decomposed Unicode on macOS. Reserve enough
            // bytes for either representation, including accented Cyrillic.
            let cost = max(text.utf8.count, text.decomposedStringWithCanonicalMapping.utf8.count)
            guard usedBytes + cost <= budget else { break }
            result.append(character)
            usedBytes += cost
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    private static func snakeCaseScalars(_ value: String) -> String {
        let allowed = CharacterSet.letters.union(.decimalDigits)
        var output = ""
        var needsSeparator = false
        for scalar in value.lowercased(with: Locale(identifier: "en_US_POSIX")).unicodeScalars {
            if allowed.contains(scalar) {
                if needsSeparator && !output.isEmpty { output.append("_") }
                output.unicodeScalars.append(scalar)
                needsSeparator = false
            } else if !output.isEmpty {
                needsSeparator = true
            }
        }
        return output
    }
}
