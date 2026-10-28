import AppKit
import Foundation

enum TrudvsemPDFFormatter {
    static let labels: [String: String] = [
        "job-name": "Название вакансии", "creation-date": "Дата создания", "date_modify": "Дата изменения",
        "schedule": "График работы", "employment": "Занятость", "work-places": "Рабочие места",
        "requirement": "Требования", "requirements": "Профессиональные требования", "duty": "Обязанности",
        "addresses": "Адреса", "address": "Адрес", "location": "Адрес", "region": "Регион", "category": "Специализация",
        "qualification": "Квалификация", "social_protected": "Социальные гарантии", "term": "Условия",
        "education": "Образование", "experience": "Опыт работы", "name": "Наименование", "specialisation": "Специализация",
        "contact_list": "Контакты", "contact_person": "Контактное лицо", "contact_type": "Способ связи", "contact_value": "Контакт",
        "phone": "Телефон", "email": "Электронная почта", "medicalCertificate": "Медицинская справка",
        "medicalDocuments": "Медицинские документы",
        "medicalCertiﬁcate": "Медицинская справка"
    ]
    private static func dateText(_ value: String?) -> String? {
        guard let value = value?.nilIfBlank else { return nil }
        if value.count == 10, let date = ISO8601DateFormatter().date(from: value + "T00:00:00Z") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ru_RU")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "dd.MM.yyyy"
            return formatter.string(from: date)
        }
        return HHPublicationDateParser().date(from: value) == nil ? value : VacancyPDFStyle.publicationDate(value)
    }
    private static func experienceLabel(_ years: Int) -> String {
        if years == 0 { return "Без опыта" }
        let last = years % 10, lastTwo = years % 100
        let unit = (11...14).contains(lastTwo) ? "лет" : (last == 1 ? "года" : ((2...4).contains(last) ? "лет" : "лет"))
        return "От \(years) \(unit)"
    }
    /// Unrecognised technical keys stay in the attached original JSON, never as labels in the document.
    static func append(_ value: SourceJSONValue, key: String, to builder: VacancyPDFDocumentBuilder) {
        guard value != .null, let label = labels[key] else { return }
        if key == "contact_type" {
            guard let raw = value.text, value.number == nil else { return }
            let translations = ["phone": "Телефон", "telephone": "Телефон", "email": "Электронная почта", "e-mail": "Электронная почта"]
            let text = translations[raw.lowercased()] ?? raw
            if text.range(of: #"[A-Za-z]"#, options: .regularExpression) == nil { builder.field(label, text) }
            return
        }
        switch value {
        case .object(let fields):
            let known = fields.keys.sorted().filter { labels[$0] != nil && fields[$0] != .null }
            guard !known.isEmpty else { return }
            builder.subheading(label)
            for k in known { append(fields[k]!, key: k, to: builder) }
        case .array(let items):
            let texts = items.compactMap { item -> String? in
                if case .string = item { return item.text?.readableHTMLText.nilIfBlank }
                return nil
            }
            if !texts.isEmpty { builder.subheading(label); builder.bullets(texts) }
            for item in items where item.fields != nil {
                if let fields = item.fields {
                    for k in fields.keys.sorted() where labels[k] != nil { append(fields[k]!, key: k, to: builder) }
                }
            }
        default:
            if key == "experience", let n = value.number, n >= 0, n.rounded() == n, n < 100 {
                builder.field(label, experienceLabel(Int(n)))
            } else if ["duty", "requirements", "qualification", "term"].contains(key),
                      let text = value.readable.nilIfBlank {
                builder.subheading(label)
                for paragraph in text.components(separatedBy: "\n").compactMap(\.nilIfBlank) { builder.plain(paragraph) }
            } else { builder.field(label, value.readable.nilIfBlank) }
        }
    }
    static func personal(_ vacancy: TrudvsemVacancy, records: [APIObservation]? = nil,
                         includeSourceEvidence: Bool = true) -> PDFVacancySnapshot {
        let b = VacancyPDFDocumentBuilder(), c = vacancy.context
        if includeSourceEvidence { b.documentHeader(c) }
        b.section(vacancy.title)
        b.field("Работодатель", vacancy.organization?.name)
        if let department = vacancy.dto.raw["company"]["name"].text, department != vacancy.organization?.name {
            b.field("Подразделение", department)
        }
        b.field("Регион", vacancy.region)
        if vacancy.fieldInstitution.isMember { b.field("Категория", "Полевые учреждения") }
        b.field("Дата создания", dateText(vacancy.created))
        b.linkField("Вакансия на trudvsem.ru", vacancy.url?.absoluteString)
        if let salary = vacancy.salary { b.section("Вознаграждение"); b.field("Зарплата", salary) }
        let raw = vacancy.dto.raw
        for (section, keys) in [
            ("Опыт, занятость и график", ["employment", "schedule", "work-places", "term", "social_protected", "addresses"]),
            ("Описание вакансии", ["duty", "requirements", "qualification", "requirement", "education", "experience"]),
            ("Контакты", ["contact_person", "contact_list", "phone", "email"]),
            ("Дополнительные сведения", ["medicalCertificate", "medicalCertiﬁcate", "medicalDocuments"])
        ] {
            let available = keys.filter { raw[$0] != .null }
            if !available.isEmpty { b.section(section); for key in available { append(raw[key], key: key, to: b) } }
        }
        if includeSourceEvidence { b.sourceEvidence(c, records: records) }
        b.identify(c)
        return .init(context: c, document: b.document)
    }
    static func statistics(_ values: [TrudvsemVacancy], filters: [String: String]) -> PDFVacancySnapshot {
        let c = DocumentContext(kind: "Реестр вакансий", vacancyIDs: values.map(\.id),
            observationIDs: values.flatMap(\.observationIDs), filters: filters.filter { $0.key != "Сортировка" }, source: .trudvsem)
        let b = VacancyPDFDocumentBuilder()
        b.documentHeader(c)
        b.field("Сформирован", VacancyPDFStyle.utcDate(PDFSourceJSON.timestamp(Date())))
        b.section("Общая статистика")
        b.field("Уникальных вакансий", String(values.count))
        b.field("Организаций", String(Set(values.map(\.organizationKey)).count))
        b.field("Подразделений", String(Set(values.map { $0.dto.companyCode }).count))
        b.field("Регионов", String(Set(values.map(\.regionID)).count))
        b.field("Полевых учреждений: вакансий", String(values.filter { $0.fieldInstitution.isMember }.count))
        let salaried = values.filter { $0.salary != nil || $0.dto.raw["salary_min"].number != nil || $0.dto.raw["salary_max"].number != nil }
        b.field("С зарплатой / без зарплаты", "\(salaried.count) / \(values.count - salaried.count)")
        let places = values.compactMap { $0.dto.raw["work-places"].number }
        if !places.isEmpty { b.field("Рабочих мест (по указанным значениям)", String(places.reduce(0, +))) }
        let dates = values.compactMap(\.created).sorted()
        if let first = dates.first, let last = dates.last { b.field("Период дат создания", "\(dateText(first) ?? first) — \(dateText(last) ?? last)") }
        func grouping(_ title: String, _ key: (TrudvsemVacancy) -> String) {
            b.section(title)
            let groups = Dictionary(grouping: values, by: key)
            for name in groups.keys.sorted() { b.field(name, String(groups[name]!.count)) }
        }
        grouping("По работодателям") { $0.organization?.name ?? "Работодатель не указан" }
        grouping("По регионам") { $0.region }
        grouping("По подразделениям") { $0.dto.raw["company"]["name"].text ?? "Подразделение не указано" }
        for (key, title) in [("employment", "По занятости"), ("schedule", "По графику"), ("education", "По образованию")] {
            grouping(title) { $0.dto.raw[key].text ?? $0.dto.raw["requirement"][key].text ?? "Не указано" }
        }
        b.section("По опыту")
        b.plain("Требования к опыту работы и число соответствующих вакансий:")
        let experiences = Dictionary(grouping: values) { vacancy -> String in
            let value = vacancy.dto.raw["experience"] == .null ? vacancy.dto.raw["requirement"]["experience"] : vacancy.dto.raw["experience"]
            guard let n = value.number, n >= 0, n.rounded() == n, n < 100 else { return value.text ?? "Не указано" }
            return experienceLabel(Int(n))
        }
        for key in experiences.keys.sorted() { b.field(key, String(experiences[key]!.count)) }
        b.section("Вакансии: от новых к старым")
        for (index, value) in values.enumerated() {
            b.subheading("\(index + 1). \(value.title)")
            b.field("Работодатель", value.organization?.name)
            b.field("Подразделение", value.dto.raw["company"]["name"].text)
            b.field("Регион", value.region); b.field("Дата создания", dateText(value.created)); b.field("Зарплата", value.salary)
            b.linkField("Объявление", value.url?.absoluteString)
        }
        b.sourceEvidence(c); b.identify(c)
        return .init(context: c, document: b.document)
    }
}
