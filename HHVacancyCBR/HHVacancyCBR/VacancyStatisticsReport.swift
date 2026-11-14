import AppKit
import Foundation

struct VacancyStatisticsReport: Sendable {
    var categoryName = "Все вакансии"
    var documentContext: DocumentContext {
        var selectedFilters: [String: String] = [:]
        if employerID != "all" { selectedFilters["Работодатель"] = employerName }
        if regionID != "all" { selectedFilters["Регион"] = regionName }
        if categoryName != "Все вакансии" { selectedFilters["Категория"] = categoryName }
        if modeName != "Все вакансии" { selectedFilters["Список"] = modeName }
        return DocumentContext(kind: "Реестр вакансий",
                        vacancyIDs: entries.map(\.id), observationIDs: entries.flatMap(\.observationIDs),
                        filters: selectedFilters)
    }
    struct Entry: Sendable {
        let id: String
        let name: String
        let publishedAt: String?
        let employerID: String
        let employerName: String
        let regionID: String
        let regionName: String
        let isArchived: Bool
        let isFieldInstitution: Bool
        let status: String
        let applicationStatus: String
        let observationIDs: [String]
        let classificationReason: String?
        let hasSalary: Bool

        init(_ vacancy: VacancySearchResult) {
            observationIDs = vacancy.observationIDs
            classificationReason = vacancy.isFieldInstitution ? vacancy.fieldInstitution.reason : nil
            id = vacancy.id
            name = vacancy.name
            publishedAt = vacancy.publishedAt
            employerID = vacancy.employerID ?? "unknown:\(vacancy.employerName)"
            employerName = vacancy.employerName
            if vacancy.location == .unknown, let area = vacancy.summary.area, let name = area.name?.nilIfBlank {
                regionID = "hh-area:" + (area.id ?? name)
                regionName = name
            } else {
                regionID = vacancy.location.filterID
                regionName = vacancy.location.subjectName ?? vacancy.areaName
            }
            isArchived = vacancy.isArchived
            isFieldInstitution = vacancy.isFieldInstitution
            status = vacancy.archiveStatusText == "Не проверен" ? "" : vacancy.archiveStatusText
            applicationStatus = vacancy.applicationStatusText
            hasSalary = vacancy.salaryText?.nilIfBlank != nil
        }
    }

    let entries: [Entry]
    let modeName: String
    let employerID: String
    let employerName: String
    let regionID: String
    let regionName: String
    let createdAt: Date
    let timeZoneIdentifier: String
    let sourceNote: String

    var fileName: String { PDFFileNameBuilder.statisticsReport(self) }

    func orderedEntries() -> [(entry: Entry, date: Date?)] {
        let parser = HHPublicationDateParser()
        return entries.map { entry in
            (entry: entry, date: parser.date(from: entry.publishedAt))
        }.sorted { left, right in
            switch (left.date, right.date) {
            case let (lhs?, rhs?) where lhs != rhs: return lhs > rhs
            case (_?, nil): return true
            case (nil, _?): return false
            default: return (left.entry.id, left.entry.observationIDs.joined()) < (right.entry.id, right.entry.observationIDs.joined())
            }
        }
    }

    func attributedDocument() throws -> NSAttributedString {
        let builder = VacancyPDFDocumentBuilder()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss XXX"
        let ordered = orderedEntries()
        let dated = ordered.compactMap(\.date)
        let employers = Dictionary(grouping: entries, by: \.employerID)
        let regions = Dictionary(grouping: entries, by: \.regionID)
        let archived = entries.filter(\.isArchived).count
        let salaried = entries.filter(\.hasSalary).count

        builder.documentHeader(documentContext)
        builder.section("Общая статистика")
        builder.field("Всего вакансий", String(entries.count))
        builder.field("Полевые учреждения", String(entries.filter(\.isFieldInstitution).count))
        builder.field("Работодателей", String(employers.count))
        builder.field("Регионов / территориальных групп", String(regions.count))
        builder.field("Активных по сведениям hh.ru", String(entries.filter { $0.status == "Активна" }.count))
        builder.field("В архиве", String(archived))
        builder.field("С указанной зарплатой", String(salaried))
        builder.field("Без указанной зарплаты", String(entries.count - salaried))
        if let newest = dated.first, let oldest = dated.last {
            builder.field("Период размещения", "\(formatter.string(from: oldest)) - \(formatter.string(from: newest))")
        }
        builder.field("Без корректной даты размещения", String(entries.count - dated.count))
        builder.section("По работодателям")
        for key in employers.keys.sorted() {
            try Task.checkCancellation()
            guard let values = employers[key], let first = values.first else { continue }
            builder.field(first.employerName, String(values.count))
        }
        builder.section("По регионам")
        for key in regions.keys.sorted() {
            try Task.checkCancellation()
            guard let values = regions[key], let first = values.first else { continue }
            builder.field(first.regionName, String(values.count))
        }
        builder.section("Вакансии: от новых к старым")
        builder.identificationNote()
        if ordered.isEmpty { builder.plain("Под выбранными фильтрами вакансий нет.") }
        for (index, row) in ordered.enumerated() {
            try Task.checkCancellation()
            let date = row.entry.publishedAt ?? "Не указана"
            builder.vacancyListItem(index: index + 1, entry: row.entry, publishedAt: date)
        }
        builder.sourceEvidence(documentContext)
        builder.identify(documentContext)
        return builder.document
    }
}
