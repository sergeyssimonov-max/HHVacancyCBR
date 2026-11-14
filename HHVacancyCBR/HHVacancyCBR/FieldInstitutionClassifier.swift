import Foundation

/// Evidence is independent of UI and professional specialization.
struct FieldInstitutionClassification: Codable, Equatable, Sendable {
    let isMember: Bool
    let reason: String?
    static let unidentified = Self(isMember: false, reason: nil)
}

struct FieldInstitutionRegistryEntry: Sendable {
    let aliases: [String]
    let employerIDs: [String]
    let source: String
}

enum FieldInstitutionClassifier {
    // Only documented IDs belong here. No independent HH accounts have been verified yet.
    static let source = "https://www.cbr.ru/psystem/field_offices/adresa-obsluzhivaniya-platezhnykh-kart/"
    static let registry: [FieldInstitutionRegistryEntry] = [
        .init(aliases: ["Инское", "Набережное", "Заводское", "Крылатское", "Матвеевское", "Черноморское",
                        "10513", "25631", "43197", "64106", "83524", "83604", "03148", "43192", "Нахимовское", "Восточное", "Островное", "Московское"],
              employerIDs: [], source: source)
    ]

    static func classify(summary: HHVacancySummary, details: HHVacancyDetails? = nil,
                         registry: [FieldInstitutionRegistryEntry] = registry) -> FieldInstitutionClassification {
        let employerID = details?.employer?.id ?? summary.employer?.id ?? ""
        if let entry = registry.first(where: { !$0.source.isEmpty && $0.employerIDs.contains(employerID) }) {
            return .init(isMember: true, reason: "Подтверждённый аккаунт hh.ru \(employerID): \(entry.source)")
        }
        guard employerID == "47858" else { return .unidentified }
        let workplaceFields = [details?.name ?? summary.name, details?.department?.name ?? summary.department?.name]
        let descriptions = [summary.snippet?.plainText, details?.description?.readableHTMLText,
                            details?.brandedDescription?.readableHTMLText, details?.address?.description]
        return classifyWorkplace(eligible: true, workplaceFields: workplaceFields, descriptions: descriptions,
                                 provenance: "hh.ru, аккаунт 47858", registry: registry)
    }

    static func classifyWorkplace(eligible: Bool, workplaceFields: [String?], descriptions: [String?],
                                  provenance: String, registry: [FieldInstitutionRegistryEntry] = registry) -> FieldInstitutionClassification {
        guard eligible else { return .unidentified }
        for (text, requiresWorkplace) in workplaceFields.map({ ($0, false) }) + descriptions.map({ ($0, true) }) {
            guard let text else { continue }
            for sentence in text.components(separatedBy: CharacterSet(charactersIn: ".!;\n")) {
                let value = sentence.lowercased().replacingOccurrences(of: "ё", with: "е")
                    .replacingOccurrences(of: #"департамент[а-я]*\s+полевых учреждений"#, with: "департамент", options: .regularExpression)
                // Interaction, past experience and boilerplate are not the place of work.
                if matches(#"взаимодейств|обслуживани|сопровождени|опыт.*(?:работ|полев)|не является|не относится|для полев|с полев|полев.{0,20}в прошлом"#, value) { continue }
                if requiresWorkplace && !matches(#"(?:работа|работать|работы|место работы|трудоустройство|служба|службы|вакансия|приглашаем|требуется|прием на работу)\s*[:—-]?\s+(?:[а-я]+\s+){0,3}в\s+(?:полев|пу\b|учрежден)|место работы\s*:\s*(?:полев|пу\b)|(?:полевое учреждение).{0,80}(?:приглашает|требуется|ищет)"#, value) { continue }
                if matches(#"\bполев(?:ое|ого|ом|ые|ых)\s+учреждени(?:е|я|и|й|ях)\b"#, value),
                   !matches(#"департамент.{0,12}полевых учреждений"#, value),
                   (matches(#"банк[а]? россии|центрального банка|цб рф"#, value)
                    || !requiresWorkplace || matches(#"(?:работа|работать|служба|место работы).{0,40}в полев"#, value)) {
                    return .init(isMember: true, reason: "Место работы (\(provenance)): \(sentence.trimmingCharacters(in: .whitespaces))")
                }
                for entry in registry where !entry.source.isEmpty {
                    for alias in entry.aliases {
                        let escaped = NSRegularExpression.escapedPattern(for: alias.lowercased())
                        if matches(#"(?:\bпу\s*[«\"]?|\bучреждени[еяи]\s*[«\"]?)"# + #"(?:№\s*)?"# + escaped + #"(?![\w-])"#, value) {
                            return .init(isMember: true, reason: "Подтверждённое наименование \(alias), \(provenance): \(entry.source)")
                        }
                    }
                }
            }
        }
        return .unidentified
    }

    private static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
