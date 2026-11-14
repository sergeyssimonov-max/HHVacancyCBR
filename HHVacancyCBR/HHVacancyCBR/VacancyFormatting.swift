import Foundation

@MainActor
enum VacancyDisplayFormat {
    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "dd.MM.yyyy, HH:mm"
        return formatter
    }()

    static func vacancyCount(_ count: Int) -> String {
        "Вакансий: \(count)"
    }

    static func updatedAt(_ date: Date) -> String {
        // Refresh the zone if the user changes it while the app is running.
        timestampFormatter.timeZone = .current
        return "Обновлено: \(timestampFormatter.string(from: date))"
    }
}

// One parsing policy for HH publication timestamps in lists and reports.
// Each owner keeps its own formatters; mutable Foundation objects are not shared across actors.
struct HHPublicationDateParser {
    private let standard = ISO8601DateFormatter()
    private let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    func date(from value: String?) -> Date? {
        guard let value else { return nil }
        return standard.date(from: value) ?? fractional.date(from: value)
    }
}
