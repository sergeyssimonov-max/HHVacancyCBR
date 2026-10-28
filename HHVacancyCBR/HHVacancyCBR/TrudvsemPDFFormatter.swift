import AppKit
import Foundation

enum TrudvsemPDFFormatter {
    static let labels: [String: String] = [
        "job-name": "Название вакансии", "id": "ID вакансии", "vac_url": "Объявление",
        "creation-date": "Дата создания", "date_modify": "Дата изменения", "salary": "Зарплата",
        "salary_min": "Нижняя граница зарплаты", "salary_max": "Верхняя граница зарплаты", "currency": "Валюта",
        "schedule": "График", "employment": "Занятость", "work-places": "Рабочие места",
        "requirement": "Требования", "requirements": "Профессиональные требования", "duty": "Обязанности",
        "addresses": "Адреса", "category": "Специализация", "qualification": "Квалификация",
        "company": "Работодатель по данным API", "region": "Регион", "contact_list": "Контакты",
        "contact_person": "Контактное лицо", "social_protected": "Социальные гарантии", "term": "Условия",
        "source": "Вид публикации", "education": "Образование", "experience": "Опыт", "address": "Адрес",
        "name": "Наименование", "companycode": "companycode", "inn": "ИНН", "ogrn": "ОГРН", "kpp": "КПП",
        "region_code": "Код региона", "specialisation": "Специализация", "url": "Ссылка", "email": "Электронная почта"
    ]
    static func append(_ value: SourceJSONValue, key: String, to builder: VacancyPDFDocumentBuilder) {
        guard value != .null else { return }
        let label = labels[key] ?? key
        switch value {
        case .object(let fields):
            builder.subheading(label)
            for k in fields.keys.sorted() { append(fields[k]!, key: k, to: builder) }
        case .array(let items):
            builder.subheading(label)
            for (index, item) in items.enumerated() { append(item, key: "\(index + 1)", to: builder) }
        default:
            builder.field(label, value.readable.nilIfBlank)
        }
    }
    static func personal(_ vacancy: TrudvsemVacancy, records: [APIObservation]? = nil) -> PDFVacancySnapshot {
        let b = VacancyPDFDocumentBuilder(), c = vacancy.context
        b.documentHeader(c); b.title(vacancy.title)
        b.field("Основная организация", vacancy.organization?.legalName)
        b.field("Подразделение", vacancy.department)
        if vacancy.fieldInstitution.isMember {
            b.field("Категория", "Полевые учреждения"); b.field("Основание", vacancy.fieldInstitution.reason)
        }
        for key in (vacancy.dto.raw.fields ?? [:]).keys.sorted() { append(vacancy.dto.raw[key], key: key, to: b) }
        b.sourceEvidence(c, records: records); b.identify(c)
        return .init(context: c, document: b.document)
    }
    static func statistics(_ values: [TrudvsemVacancy], filters: [String: String]) -> PDFVacancySnapshot {
        let c = DocumentContext(kind: "Статистика и краткий реестр вакансий", vacancyIDs: values.map(\.id),
            observationIDs: values.flatMap(\.observationIDs), filters: filters, source: .trudvsem)
        let b = VacancyPDFDocumentBuilder()
        b.documentHeader(c)
        b.field("Сформирован", VacancyPDFStyle.utcDate(PDFSourceJSON.timestamp(Date())))
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
        if let first = dates.first, let last = dates.last { b.field("Период дат создания", "\(first) — \(last)") }
        func grouping(_ title: String, _ key: (TrudvsemVacancy) -> String) {
            b.section(title)
            let groups = Dictionary(grouping: values, by: key)
            for name in groups.keys.sorted() { b.field(name, String(groups[name]!.count)) }
        }
        grouping("По организациям") { $0.organization?.name ?? $0.organizationKey }
        grouping("По регионам") { $0.region }
        grouping("По подразделениям") { $0.department + " · " + $0.dto.companyCode }
        for (key, title) in [("employment", "По занятости"), ("schedule", "По графику"), ("education", "По образованию"), ("experience", "По опыту")] {
            grouping(title) { $0.dto.raw[key].text ?? $0.dto.raw["requirement"][key].text ?? "Не указано" }
        }
        b.section("Зарплата по валюте и периодичности")
        let groups = Dictionary(grouping: salaried) { v in
            (v.dto.raw["currency"].text ?? "Валюта не указана") + " · " + (v.dto.raw["salary_period"].text ?? "Период не указан")
        }
        for key in groups.keys.sorted() {
            let group = groups[key]!
            let amounts = group.flatMap { [$0.dto.raw["salary_min"].number, $0.dto.raw["salary_max"].number].compactMap { $0 } }
            b.subheading(key); b.field("Вакансий", String(group.count))
            if let min = amounts.min(), let max = amounts.max() { b.field("Границы опубликованных диапазонов", "\(min) — \(max)") }
            let ranges = Dictionary(grouping: group) { ($0.dto.raw["salary_min"].text ?? "—") + " … " + ($0.dto.raw["salary_max"].text ?? "—") }
            for range in ranges.keys.sorted() { b.field(range, String(ranges[range]!.count)) }
        }
        b.section("Краткий реестр")
        for (index, value) in values.enumerated() {
            b.subheading("\(index + 1). \(value.title)")
            b.field("ID / companycode", value.dto.id + " / " + value.dto.companyCode)
            b.field("Организация / подразделение", (value.organization?.name ?? value.organizationKey) + " / " + value.department)
            b.field("Регион", value.region); b.field("Дата создания", value.created); b.field("Зарплата", value.salary)
            b.linkField("Объявление", value.url?.absoluteString)
        }
        b.sourceEvidence(c); b.identify(c)
        return .init(context: c, document: b.document)
    }
}
