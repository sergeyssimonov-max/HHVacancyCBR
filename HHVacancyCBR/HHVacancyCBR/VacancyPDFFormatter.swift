import AppKit
import Foundation

enum VacancyPDFFormatter {
    /// Imports the description on the calling (main) actor and builds the document.
    @MainActor
    static func attributedDocument(for vacancy: VacancySearchResult) -> NSAttributedString {
        attributedDocument(for: vacancy, importedDescription: importedDescription(for: vacancy))
    }

    /// AppKit imports HTML through WebKit, which is main-thread only. Import here and pass
    /// the result to background rendering instead of importing inside PDFExportWorker.
    @MainActor
    static func importedDescription(for vacancy: VacancySearchResult) -> NSAttributedString? {
        guard let html = descriptionHTML(for: vacancy) else { return nil }
        return VacancyHTMLAttributedText.convert(html)
    }

    /// Safe off the main actor: HTML is never imported here. A description that was not
    /// imported in advance falls back to plain text.
    static func attributedDocument(
        for vacancy: VacancySearchResult,
        importedDescription: NSAttributedString?,
        context suppliedContext: DocumentContext? = nil,
        includeSourceEvidence: Bool = true
    ) -> NSAttributedString {
        let builder = VacancyPDFDocumentBuilder()
        let details = vacancy.details

        let context = suppliedContext ?? DocumentContext.vacancy(vacancy)
        let isPersonalDocument = context.kind == "Сведения о вакансии" && includeSourceEvidence
        if isPersonalDocument { builder.documentHeader(context) }
        builder.section(vacancy.name)
        builder.field("Работодатель", vacancy.employerName)
        builder.field("Идентификатор работодателя", vacancy.employerID)
        if vacancy.isFieldInstitution {
            builder.field("Категория", "Полевые учреждения")
            builder.field("Основание внутренней классификации", vacancy.fieldInstitution.reason)
        }
        if let department = vacancy.departmentName {
            builder.field("Подразделение", department)
        }
        builder.field("Регион", vacancy.location.subjectName)
        builder.field("Населённый пункт по hh.ru", details.area?.name ?? vacancy.summary.area?.name)
        appendAddress(details.address, to: builder)
        if vacancy.archiveStatusText != "Не проверен" { builder.field("Статус", vacancy.archiveStatusText) }
        builder.field("Приём откликов", vacancy.applicationStatusText)
        builder.field("Идентификатор вакансии", vacancy.id)
        builder.field("Дата публикации", VacancyPDFStyle.publicationDate(details.publishedAt?.nilIfBlank ?? vacancy.summary.publishedAt))
        if details.initialCreatedAt?.nilIfBlank != details.publishedAt?.nilIfBlank {
            if let initial = details.initialCreatedAt?.nilIfBlank { builder.field("Первоначально создана", VacancyPDFStyle.publicationDate(initial)) }
        }
        if let expires = details.expiresAt?.nilIfBlank { builder.field("Действует до", VacancyPDFStyle.publicationDate(expires)) }
        if let archived = details.archivedAt?.nilIfBlank { builder.field("Дата архивации", VacancyPDFStyle.publicationDate(archived)) }
        builder.linkField("Вакансия на hh.ru", "https://hh.ru/vacancy/" + vacancy.id)
        if isPersonalDocument { builder.identificationNote() }

        appendSalary(details: details, fallbackText: vacancy.salaryText, to: builder)
        appendEmployment(details, to: builder)
        appendDescription(vacancy, importedDescription: importedDescription, to: builder)

        let skills = names(details.keySkills)
        if !skills.isEmpty {
            builder.section("Ключевые навыки")
            builder.bullets(skills)
        }

        let roles = names(details.professionalRoles)
        if !roles.isEmpty {
            builder.section("Профессиональные роли")
            builder.bullets(roles)
        }

        if let languages = details.languages, !languages.isEmpty {
            let values = languages.compactMap { language -> String? in
                guard let name = language.name?.nilIfBlank ?? language.id?.nilIfBlank else { return nil }
                guard let level = language.level?.name?.nilIfBlank ?? language.level?.id?.nilIfBlank else {
                    return name
                }
                return "\(name) - \(level)"
            }
            if !values.isEmpty {
                builder.section("Языки")
                builder.bullets(values)
            }
        }

        appendContacts(details.contacts, to: builder)
        if isPersonalDocument && includeSourceEvidence { builder.sourceEvidence(context) }
        builder.identify(context)
        return builder.document
    }

    private static func appendAddress(_ address: HHVacancyAddress?, to builder: VacancyPDFDocumentBuilder) {
        guard let address else { return }
        let components = [address.city, address.street, address.building]
            .compactMap { $0?.nilIfBlank }
        if !components.isEmpty { builder.field("Адрес", components.joined(separator: ", ")) }
        builder.field("Ориентир", address.description?.nilIfBlank)
        if let stations = address.metroStations {
            let values = stations.compactMap { station -> String? in
                guard let name = station.stationName?.nilIfBlank else { return nil }
                return station.lineName?.nilIfBlank.map { "\(name) (\($0))" } ?? name
            }
            if !values.isEmpty { builder.field("Метро", values.joined(separator: ", ")) }
        }
    }

    private static func appendSalary(
        details: HHVacancyDetails,
        fallbackText: String?,
        to builder: VacancyPDFDocumentBuilder
    ) {
        builder.section("Вознаграждение")
        if let range = details.salaryRange {
            builder.field("От", range.from.map(formatAmount))
            builder.field("До", range.to.map(formatAmount))
            builder.field("Валюта", range.currency?.nilIfBlank)
            builder.field("Налоги", range.gross.map { $0 ? "До вычета налогов" : "На руки" })
            builder.field("Период", range.mode?.name?.nilIfBlank ?? range.mode?.id?.nilIfBlank)
            builder.field("Частота выплаты", range.frequency?.name?.nilIfBlank ?? range.frequency?.id?.nilIfBlank)
            return
        }
        if let salary = details.salary {
            builder.field("От", salary.from.map(formatAmount))
            builder.field("До", salary.to.map(formatAmount))
            builder.field("Валюта", salary.currency?.nilIfBlank)
            builder.field("Налоги", salary.gross.map { $0 ? "До вычета налогов" : "На руки" })
            return
        }
        if let fallbackText = fallbackText?.nilIfBlank {
            builder.field("Сохранённое значение", fallbackText)
        } else {
            builder.plain("HH не указал вознаграждение.")
        }
    }

    private static func appendEmployment(_ details: HHVacancyDetails, to builder: VacancyPDFDocumentBuilder) {
        let sectionStart = builder.document.length
        builder.section("Опыт, занятость и график")
        let fieldsStart = builder.document.length
        builder.field("Требуемый опыт", value(details.experience))
        builder.field("Форма занятости", value(details.employmentForm) ?? value(details.employment))
        builder.field("График", value(details.schedule))
        builder.field("Формат работы", joinedNames(details.workFormat))
        builder.field("Рабочие дни", joinedNames(details.workScheduleByDays) ?? joinedNames(details.workingDays))
        builder.field("Рабочие часы", joinedNames(details.workingHours))
        builder.field("Интервалы работы", joinedNames(details.workingTimeIntervals))
        builder.field("Режим времени", joinedNames(details.workingTimeModes))
        builder.field("Длительность вахты", joinedNames(details.flyInFlyOutDuration))
        if details.internship == true { builder.field("Стажировка", "Да") }
        if details.nightShifts == true { builder.field("Ночные смены", "Да") }
        if builder.document.length == fieldsStart {
            builder.document.deleteCharacters(in: NSRange(location: sectionStart, length: fieldsStart - sectionStart))
        }
    }

    private static func descriptionHTML(for vacancy: VacancySearchResult) -> String? {
        vacancy.details.description?.nilIfBlank ?? vacancy.details.brandedDescription?.nilIfBlank
    }

    private static func appendDescription(
        _ vacancy: VacancySearchResult,
        importedDescription: NSAttributedString?,
        to builder: VacancyPDFDocumentBuilder
    ) {
        builder.section("Описание вакансии")
        if let html = descriptionHTML(for: vacancy) {
            builder.html(importedDescription ?? VacancyHTMLAttributedText.plainText(html))
            return
        }

        if let snippet = vacancy.summary.snippet?.plainText.nilIfBlank {
            builder.subheading("Фрагменты поисковой карточки hh.ru")
            builder.plain(snippet)
        }
    }

    private static func appendContacts(_ contacts: HHVacancyContacts?, to builder: VacancyPDFDocumentBuilder) {
        guard let contacts else { return }
        let phones = contacts.phones?.compactMap { phone -> String? in
            guard let number = phone.displayText else { return nil }
            return phone.comment?.nilIfBlank.map { "\(number) - \($0)" } ?? number
        } ?? []
        guard contacts.name?.nilIfBlank != nil || !phones.isEmpty else { return }
        builder.section("Контакты")
        builder.field("Контактное лицо", contacts.name?.nilIfBlank)
        if !phones.isEmpty { builder.bullets(phones) }
    }

    private static func names(_ items: [HHNamedItem]?) -> [String] {
        items?.compactMap { $0.name?.nilIfBlank ?? $0.id?.nilIfBlank } ?? []
    }

    private static func joinedNames(_ items: [HHNamedItem]?) -> String? {
        names(items).joined(separator: ", ").nilIfBlank
    }

    private static func value(_ item: HHNamedItem?) -> String? {
        item?.name?.nilIfBlank ?? item?.id?.nilIfBlank
    }

    private static func formatAmount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = " "
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
