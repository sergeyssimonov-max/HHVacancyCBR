import Foundation

enum VacancyLocationKind: String, Codable, Equatable, Sendable {
    case subject
    case remote
    case unknown
}

struct VacancyLocation: Codable, Equatable, Sendable {
    let kind: VacancyLocationKind
    let subjectID: String?
    let subjectName: String?
    let cityID: String?
    let cityName: String?

    static let remote = VacancyLocation(
        kind: .remote,
        subjectID: nil,
        subjectName: nil,
        cityID: nil,
        cityName: nil
    )
    static let unknown = VacancyLocation(
        kind: .unknown,
        subjectID: nil,
        subjectName: nil,
        cityID: nil,
        cityName: nil
    )

    static func subject(id: String, name: String, cityID: String?, cityName: String?) -> VacancyLocation {
        VacancyLocation(
            kind: .subject,
            subjectID: id,
            subjectName: name,
            cityID: cityID,
            cityName: cityName
        )
    }

    var displayName: String {
        switch kind {
        case .remote:
            return "Удалённо"
        case .unknown:
            return "Регион не определён"
        case .subject:
            if let cityName = cityName?.nilIfBlank, cityName != subjectName {
                return "\(cityName), \(subjectName ?? "Регион не определён")"
            }
            return subjectName?.nilIfBlank ?? "Регион не определён"
        }
    }

    var filterID: String {
        switch kind {
        case .remote: return "remote"
        case .unknown: return "unknown"
        case .subject: return "subject:\(subjectID ?? "unknown")"
        }
    }
}
