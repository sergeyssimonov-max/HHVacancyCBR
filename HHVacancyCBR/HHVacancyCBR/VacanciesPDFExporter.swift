import AppKit
import CoreGraphics
import CryptoKit
import Darwin
import Foundation

enum VacancyPDFDefaults {
    static let paperSize = NSSize(width: 595.28, height: 841.89)
    static let horizontalMargin: CGFloat = 56
    static let verticalMargin: CGFloat = 48
    // NSLayoutManager and NSAttributedString.draw can differ by a fraction of a
    // line in their final font-leading calculation. Reserve one body line so a
    // glyph range accepted by pagination cannot be clipped during PDF drawing.
    // Keep two compact body lines because a list marker and its wrapped text can
    // use different final line fragments in the two AppKit layout paths.
    static let paginationBottomSafetyMargin: CGFloat = 40

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
        let isPersonalDocument = context.kind == "Сведения о вакансии"
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

final class VacancyPDFDocumentBuilder {
    private(set) var document = NSMutableAttributedString()

    // Computed: NSFont is not Sendable, so no shared static instances across actors.
    private static var bodyFont: NSFont { VacancyPDFStyle.bodyFont }
    private static var labelFont: NSFont { VacancyPDFStyle.labelFont }
    private static var headingFont: NSFont { VacancyPDFStyle.headingFont }
    private static var titleFont: NSFont { VacancyPDFStyle.titleFont }

    func identify(_ context: DocumentContext) {
        document.addAttribute(VacancyPDFStyle.documentKind, value: context.kind, range: NSRange(location: 0, length: document.length))
    }

    func documentHeader(_ context: DocumentContext) {
        title(context.kind)
        field("Источник", context.source.displayName)
        for key in context.filters.keys.sorted() { field(key, context.filters[key]) }
        if context.vacancyIDs.count > 1 { field("Количество вакансий", String(Set(context.vacancyIDs).count)) }
    }

    func identificationNote() {
        provenance("Идентификаторы вакансии и работодателя — номера, присвоенные hh.ru. По ним можно найти объявление и карточку организации. Дата публикации, статус и приём откликов приведены по сведениям hh.ru.")
    }

    func sourceEvidence(_ context: DocumentContext, records: [APIObservation]? = nil) {
        let records = records ?? context.observationIDs.compactMap { try? PDFSourceEvidence.shared.observation($0) }
        let blockStart = document.length
        section("Данные для проверки")
        provenance("Файл содержит сохранённые ответы API и реквизиты их получения: адреса запросов, параметры, время по часам устройства, идентификаторы и контрольные суммы. Вложения содержат исходные данные JSON и, если источник их предоставил, разметку описания вакансии. Они не являются снимком внешнего вида страницы сайта.")
        provenance("Материалы могут быть исследованы при судебной компьютерно-технической экспертизе с применением соответствующих методик, в том числе разработок ФБУ РФЦСЭ при Минюсте России. Суд может истребовать сведения у оператора площадки (статьи 57 и 79 ГПК РФ, статьи 66 и 82 АПК РФ). Происхождение и время размещения оцениваются с учётом всех доказательств.")
        let covered = Set(records.flatMap(\.vacancyIDs))
        if records.count < context.observationIDs.count || !Set(context.vacancyIDs).isSubset(of: covered) {
            provenance("Исходный ответ для части вакансий не сохранился или повреждён. Его контрольная сумма не подтверждена.")
        }
        guard !records.isEmpty else { return }
        provenance("Совпадение контрольной суммы подтверждает согласованность вложенных байтов и хеша, но само по себе не подтверждает их происхождение или время получения.")
        for (index, record) in records.enumerated() {
            field("Ответ API №\(index + 1)", record.endpoint + " · сохранён " + VacancyPDFStyle.utcDate(record.receivedAt))
            field("Запрос", record.method + " · " + record.parameters.keys.sorted().map { "\($0)=\(record.parameters[$0]!)" }.joined(separator: "&"))
            field("Отправлен", VacancyPDFStyle.utcDate(record.sentAt))
            field("HTTP / байт", "\(record.httpStatus) / \(record.byteCount)")
            field("Алгоритм хеша", record.algorithm == MaterialHash.algorithm ? MaterialHash.displayName : record.algorithm)
            hashField("Хеш ответа №\(index + 1)", record.hash)
        }
        if records.count <= 3 {
            let text = document.string as NSString
            let lastParagraph = text.paragraphRange(for: NSRange(location: document.length - 1, length: 0))
            let groupLength = lastParagraph.location - blockStart
            if groupLength > 0 {
                document.addAttribute(VacancyPDFStyle.keepWithNext, value: true,
                                      range: NSRange(location: blockStart, length: groupLength))
            }
        }
    }

    func title(_ text: String) {
        let style = paragraphStyle(lineSpacing: 2, paragraphSpacing: 12)
        append(text + "\n", attributes: [.font: Self.titleFont, .foregroundColor: VacancyPDFStyle.ink, .paragraphStyle: style, VacancyPDFStyle.keepWithNext: true])
    }

    func provenance(_ text: String) {
        append(text + "\n", attributes: [
            .font: Self.bodyFont,
            .foregroundColor: VacancyPDFStyle.ink,
            .paragraphStyle: paragraphStyle(lineSpacing: 2, paragraphSpacing: 8)
        ])
    }

    func notice(_ text: String) {
        let style = paragraphStyle(lineSpacing: 2, paragraphSpacing: 8)
        append(text + "\n", attributes: [
            .font: Self.bodyFont,
            .foregroundColor: VacancyPDFStyle.ink,
            .paragraphStyle: style
        ])
    }

    func section(_ text: String) {
        let style = paragraphStyle(lineSpacing: 2, paragraphSpacing: 8, paragraphSpacingBefore: 14)
        append(text + "\n", attributes: [
            .font: Self.headingFont,
            .foregroundColor: VacancyPDFStyle.ink,
            .paragraphStyle: style,
            VacancyPDFStyle.keepWithNext: true
        ])
    }

    func subheading(_ text: String) {
        append(text + "\n", attributes: [
            .font: Self.bodyFont, .foregroundColor: VacancyPDFStyle.ink,
            .paragraphStyle: paragraphStyle(lineSpacing: 2, paragraphSpacing: 4)
        ])
    }

    func field(_ label: String, _ value: String?) {
        guard let value = value?.nilIfBlank else { return }
        let line = NSMutableAttributedString(string: label + ": ", attributes: [
            .font: Self.labelFont, .foregroundColor: VacancyPDFStyle.ink
        ])
        line.append(NSAttributedString(string: value + "\n", attributes: [
            .font: Self.bodyFont,
            .foregroundColor: VacancyPDFStyle.ink
        ]))
        line.addAttribute(.paragraphStyle, value: paragraphStyle(lineSpacing: 2, paragraphSpacing: 4),
                          range: NSRange(location: 0, length: line.length))
        document.append(line)
    }

    func hashField(_ label: String, _ value: String) {
        let characters = Array(value)
        let rows = stride(from: 0, to: characters.count, by: 64).map { start in
            String(characters[start..<min(start + 64, characters.count)])
        }
        append(label + "\n", attributes: [
            .font: Self.labelFont, .foregroundColor: VacancyPDFStyle.ink,
            .paragraphStyle: paragraphStyle(lineSpacing: 2, paragraphSpacing: 2)
        ])
        append(rows.joined(separator: "\n") + "\n", attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 8.2, weight: .regular),
            .foregroundColor: VacancyPDFStyle.ink,
            .paragraphStyle: paragraphStyle(lineSpacing: 2, paragraphSpacing: 8)
        ])
    }

    func linkField(_ label: String, _ value: String?) {
        guard let value = value?.nilIfBlank else { return }
        let line = NSMutableAttributedString(string: label + ": ", attributes: [
            .font: Self.labelFont, .foregroundColor: VacancyPDFStyle.ink
        ])
        var attributes: [NSAttributedString.Key: Any] = [
            .font: Self.bodyFont,
            .foregroundColor: VacancyPDFStyle.ink
        ]
        if let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            attributes[.link] = url
        }
        line.append(NSAttributedString(string: value + "\n", attributes: attributes))
        line.addAttribute(.paragraphStyle, value: paragraphStyle(lineSpacing: 2, paragraphSpacing: 4, lineBreakMode: .byCharWrapping),
                          range: NSRange(location: 0, length: line.length))
        document.append(line)
    }

    func plain(_ text: String) {
        append(text + "\n", attributes: [
            .font: Self.bodyFont,
            .foregroundColor: VacancyPDFStyle.ink,
            .paragraphStyle: paragraphStyle(lineSpacing: 2, paragraphSpacing: 8)
        ])
    }

    func vacancyListItem(index: Int, entry: VacancyStatisticsReport.Entry, publishedAt: String) {
        // One record stays together when it fits on a page.
        let item = NSMutableAttributedString(string: "\(index). \(entry.name)\u{2028}", attributes: [
            .font: VacancyPDFStyle.font(ofSize: 10.5, weight: .semibold), .foregroundColor: VacancyPDFStyle.ink
        ])
        var fields = [("Идентификатор вакансии", entry.id),
                      ("Дата публикации", VacancyPDFStyle.publicationDate(publishedAt)),
                      ("Работодатель", entry.employerName)]
        if !entry.employerID.hasPrefix("unknown:") { fields.append(("Идентификатор работодателя", entry.employerID)) }
        if !entry.status.isEmpty { fields.append(("Статус", entry.status)) }
        fields.append(("Приём откликов", entry.applicationStatus))
        fields.append(("Местность", entry.regionName))
        fields.append(("Вакансия на hh.ru", "https://hh.ru/vacancy/" + entry.id))
        if let reason = entry.classificationReason {
            fields.append(("Категория", "Полевые учреждения"))
            fields.append(("Основание", reason))
        }
        for (offset, field) in fields.enumerated() {
            item.append(NSAttributedString(string: field.0 + ": ", attributes: [
                .font: Self.bodyFont, .foregroundColor: VacancyPDFStyle.ink
            ]))
            var attributes: [NSAttributedString.Key: Any] = [.font: Self.bodyFont, .foregroundColor: VacancyPDFStyle.ink]
            if field.0 == "Вакансия на hh.ru", let url = URL(string: field.1) { attributes[.link] = url }
            item.append(NSAttributedString(string: field.1 + (offset == fields.count - 1 ? "\n" : "\u{2028}"), attributes: attributes))
        }
        item.addAttribute(.paragraphStyle, value: paragraphStyle(lineSpacing: 2, paragraphSpacing: 14),
                          range: NSRange(location: 0, length: item.length))
        document.append(item)
    }

    func bullets(_ values: [String]) {
        let style = paragraphStyle(lineSpacing: 2, paragraphSpacing: 4, headIndent: 16, firstLineHeadIndent: 0)
        for value in values where value.nilIfBlank != nil {
            append("–  \(value)\n", attributes: [
                .font: Self.bodyFont, .foregroundColor: VacancyPDFStyle.ink, .paragraphStyle: style
            ])
        }
    }

    func html(_ content: NSAttributedString) {
        document.append(content)
        if !document.string.hasSuffix("\n") {
            append("\n", attributes: [.font: Self.bodyFont, .foregroundColor: VacancyPDFStyle.ink,
                                      .paragraphStyle: paragraphStyle(lineSpacing: 2, paragraphSpacing: 8)])
        }
    }

    private func append(_ text: String, attributes: [NSAttributedString.Key: Any]) {
        document.append(NSAttributedString(string: text, attributes: attributes))
    }

    private func paragraphStyle(
        lineSpacing: CGFloat,
        paragraphSpacing: CGFloat,
        paragraphSpacingBefore: CGFloat = 0,
        headIndent: CGFloat = 0,
        firstLineHeadIndent: CGFloat = 0,
        lineBreakMode: NSLineBreakMode = .byWordWrapping
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.paragraphSpacing = paragraphSpacing
        style.paragraphSpacingBefore = paragraphSpacingBefore
        style.headIndent = headIndent
        style.firstLineHeadIndent = firstLineHeadIndent
        style.lineBreakMode = lineBreakMode
        return style
    }
}

enum VacancyHTMLAttributedText {
    private static let commentExpression = expression(#"<!--[\s\S]*?-->"#)
    private static let blockedElementExpression = expression(
        #"<(script|style|noscript|iframe|object|embed|svg|canvas|form|button|video|audio|picture)\b[^>]*>[\s\S]*?</\1\s*>"#,
        options: [.caseInsensitive]
    )
    private static let unterminatedBlockedElementExpression = expression(
        #"<(script|style|noscript|iframe|object|embed|svg|canvas|form|button|video|audio|picture)\b[^>]*>[\s\S]*$"#,
        options: [.caseInsensitive]
    )
    private static let externalElementExpression = expression(
        #"<(img|input|source|link|meta)\b[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let supportedElementExpression = expression(
        #"<(p|div|br|ul|ol|li|h[1-6]|strong|b|em|i|blockquote|pre|code|hr)\b[^>]*>"#,
        options: [.caseInsensitive]
    )
    private static let unsupportedElementExpression = expression(
        #"<(?!/?(?:p|div|br|ul|ol|li|h[1-6]|strong|b|em|i|blockquote|pre|code|hr|a)\b)[^>]+>"#,
        options: [.caseInsensitive]
    )
    private static let anchorExpression = expression(#"<a\b[^>]*>"#, options: [.caseInsensitive])
    private static let anchorHREFExpression = expression(
        #"href\s*=\s*([\"'])(.*?)\1"#,
        options: [.caseInsensitive]
    )

    static func plainText(_ html: String) -> NSAttributedString {
        let readable = html.readableHTMLText.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let indent = line.prefix { $0 == " " || $0 == "\t" }
            let content = line.dropFirst(indent.count)
            return content.hasPrefix("- ") ? String(indent) + "– " + content.dropFirst(2) : String(line)
        }.joined(separator: "\n")
        let result = NSMutableAttributedString(
            string: readable,
            attributes: [.font: VacancyPDFStyle.bodyFont, .foregroundColor: VacancyPDFStyle.ink]
        )
        removeEmptyParagraphs(in: result)
        normalizeParagraphStyles(in: result)
        return result
    }

    @MainActor
    static func convert(_ html: String) -> NSAttributedString {
        let sanitized = sanitize(html)
        let wrapped = """
        <html><head><meta charset="utf-8"></head><body>\(sanitized)</body></html>
        """
        guard let data = wrapped.data(using: .utf8),
              let imported = try? NSMutableAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
              ) else {
            return plainText(html)
        }

        let fullRange = NSRange(location: 0, length: imported.length)
        imported.addAttribute(.foregroundColor, value: VacancyPDFStyle.ink, range: fullRange)
        // Replace paragraph-leading list markers and hyphens; preserve numbered lists and prose.
        let markers = try! NSRegularExpression(pattern: #"(?m)^[\t ]*([•◦▪●○■⁃-])(?=[\t ])"#)
        for match in markers.matches(in: imported.string, range: NSRange(location: 0, length: imported.length)).reversed() {
            imported.replaceCharacters(in: match.range(at: 1), with: "–")
        }
        normalizeLeadingHyphenBullets(in: imported)
        removeEmptyParagraphs(in: imported)
        normalizeParagraphStyles(in: imported)
        return imported
    }

    private static func removeEmptyParagraphs(in text: NSMutableAttributedString) {
        let source = text.string as NSString
        var ranges: [NSRange] = []
        var location = 0
        while location < source.length {
            var start = 0
            var end = 0
            var contentsEnd = 0
            source.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd,
                                     for: NSRange(location: location, length: 0))
            if source.substring(with: NSRange(location: start, length: contentsEnd - start))
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ranges.append(NSRange(location: start, length: end - start))
            }
            location = max(end, location + 1)
        }
        for range in ranges.reversed() { text.deleteCharacters(in: range) }
    }

    private static func normalizeLeadingHyphenBullets(in text: NSMutableAttributedString) {
        let source = text.string as NSString
        guard source.length > 1 else { return }
        for index in stride(from: source.length - 2, through: 0, by: -1) {
            let isLineStart = index == 0 || [UInt16(10), UInt16(13), UInt16(0x2028), UInt16(0x2029)].contains(source.character(at: index - 1))
            if isLineStart, source.character(at: index) == 45,
               [UInt16(9), UInt16(32)].contains(source.character(at: index + 1)) {
                text.replaceCharacters(in: NSRange(location: index, length: 1), with: "–")
            }
        }
    }

    private static func normalizeParagraphStyles(in text: NSMutableAttributedString) {
        let source = text.string as NSString
        var location = 0
        while location < text.length {
            var paragraphStart = 0
            var paragraphEnd = 0
            var contentsEnd = 0
            source.getParagraphStart(
                &paragraphStart,
                end: &paragraphEnd,
                contentsEnd: &contentsEnd,
                for: NSRange(location: location, length: 0)
            )
            let paragraphRange = NSRange(
                location: paragraphStart,
                length: max(0, paragraphEnd - paragraphStart)
            )
            let contentsRange = NSRange(
                location: paragraphStart,
                length: max(0, contentsEnd - paragraphStart)
            )
            let content = source.substring(with: contentsRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let original = text.attribute(
                .paragraphStyle,
                at: min(paragraphStart, max(0, text.length - 1)),
                effectiveRange: nil
            ) as? NSParagraphStyle
            let style = (original?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            let hasList = !style.textLists.isEmpty
            let isBullet = hasList || content.hasPrefix("– ")
            if content.hasPrefix("–"), hasList {
                style.textLists = style.textLists.map { _ in NSTextList(markerFormat: .init(rawValue: "–"), options: 0) }
            }
            let isBoldHeading = !content.isEmpty
                && content.count <= 80
                && paragraphIsBold(text, range: contentsRange)
                && (!hasList || content.hasSuffix(":"))

            style.lineSpacing = 2
            style.paragraphSpacingBefore = 0
            style.paragraphSpacing = isBullet ? 4 : 8
            if isBoldHeading {
                style.textLists = []
                style.headIndent = 0
                style.firstLineHeadIndent = 0
                style.paragraphSpacingBefore = 14
                style.paragraphSpacing = 8
            } else if hasList {
                let textColumn = style.tabStops.last?.location ?? max(style.headIndent, 18)
                style.headIndent = textColumn
                style.firstLineHeadIndent = 0
            } else {
                style.headIndent = min(max(style.headIndent, 0), 18)
                style.firstLineHeadIndent = min(max(style.firstLineHeadIndent, 0), 18)
            }
            if paragraphRange.length > 0 {
                text.addAttribute(.paragraphStyle, value: style, range: paragraphRange)
            }
            if contentsRange.length > 0 {
                text.addAttribute(.font, value: isBoldHeading ? VacancyPDFStyle.headingFont : VacancyPDFStyle.bodyFont,
                                  range: contentsRange)
            }
            location = max(paragraphEnd, location + 1)
        }
    }

    private static func paragraphIsBold(_ text: NSAttributedString, range: NSRange) -> Bool {
        guard range.length > 0 else { return false }
        var sawText = false
        var allBold = true
        text.enumerateAttribute(.font, in: range) { value, fontRange, stop in
            let substring = (text.string as NSString).substring(with: fontRange)
            guard substring.nilIfBlank != nil else { return }
            sawText = true
            guard let font = value as? NSFont,
                  font.fontDescriptor.symbolicTraits.contains(.bold) else {
                allBold = false
                stop.pointee = true
                return
            }
        }
        return sawText && allBold
    }

    static func sanitize(_ html: String) -> String {
        var value = html
        value = replacing(commentExpression, in: value, with: "")
        value = replacing(
            blockedElementExpression,
            in: value,
            with: ""
        )
        value = replacing(
            unterminatedBlockedElementExpression,
            in: value,
            with: ""
        )
        value = replacing(externalElementExpression, in: value, with: "")
        value = sanitizeAnchors(in: value)
        value = replacing(
            supportedElementExpression,
            in: value,
            with: "<$1>"
        )
        value = replacing(
            unsupportedElementExpression,
            in: value,
            with: ""
        )
        return value
    }

    private static func sanitizeAnchors(in source: String) -> String {
        guard let expression = anchorExpression else { return source }
        let mutable = NSMutableString(string: source)
        let matches = expression.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for match in matches.reversed() {
            let tag = mutable.substring(with: match.range)
            let href = firstCapture(expression: anchorHREFExpression, in: tag, group: 2)
            let replacement: String
            if let href,
               let url = URL(string: href),
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                let escaped = href.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "\"", with: "&quot;")
                replacement = "<a href=\"\(escaped)\">"
            } else {
                replacement = "<a>"
            }
            mutable.replaceCharacters(in: match.range, with: replacement)
        }
        return mutable as String
    }

    private static func firstCapture(
        expression: NSRegularExpression?,
        in source: String,
        group: Int
    ) -> String? {
        guard let expression,
              let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)),
              match.numberOfRanges > group,
              let range = Range(match.range(at: group), in: source) else { return nil }
        return String(source[range])
    }

    private static func replacing(
        _ expression: NSRegularExpression?,
        in source: String,
        with replacement: String
    ) -> String {
        guard let expression else { return source }
        return expression.stringByReplacingMatches(
            in: source,
            range: NSRange(source.startIndex..., in: source),
            withTemplate: replacement
        )
    }

    private static func expression(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: options)
    }
}

struct BulkPDFExportProgress: Equatable {
    let completedVacancies: Int
    let totalVacancies: Int
    var stage = "Подготовка вакансий"
}

/// A vacancy frozen for background rendering, with its HTML description already
/// imported on the main actor. The attributed string is not mutated after creation.
struct PDFVacancySnapshot: @unchecked Sendable {
    let context: DocumentContext
    let attributedDocument: NSAttributedString

    @MainActor
    init(value: VacancySearchResult, includeSourceEvidence: Bool = true) {
        context = DocumentContext.vacancy(value)
        attributedDocument = VacancyPDFFormatter.attributedDocument(for: value,
            importedDescription: VacancyPDFFormatter.importedDescription(for: value), context: context,
            includeSourceEvidence: includeSourceEvidence)
    }
    init(context: DocumentContext, document: NSAttributedString) {
        self.context = context; attributedDocument = document.copy() as! NSAttributedString
    }
}

struct PDFVacanciesSnapshot: @unchecked Sendable {
    let values: [PDFVacancySnapshot]

    @MainActor
    init(values: [VacancySearchResult]) {
        var snapshots: [PDFVacancySnapshot] = []
        snapshots.reserveCapacity(values.count)
        for value in values { snapshots.append(PDFVacancySnapshot(value: value, includeSourceEvidence: false)) }
        self.values = snapshots
    }

    init(snapshots: [PDFVacancySnapshot]) {
        values = snapshots
    }

    /// Imports descriptions one by one, letting the UI run between vacancies.
    @MainActor
    static func make(values: [VacancySearchResult]) async throws -> PDFVacanciesSnapshot {
        var snapshots: [PDFVacancySnapshot] = []
        snapshots.reserveCapacity(values.count)
        for value in values {
            try Task.checkCancellation()
            snapshots.append(PDFVacancySnapshot(value: value, includeSourceEvidence: false))
            await Task.yield()
        }
        return PDFVacanciesSnapshot(snapshots: snapshots)
    }
}

enum BulkPDFExportOutcome: Equatable {
    case cancelled
    case exported(fileCount: Int, pageCount: Int)
}

@MainActor
protocol VacanciesPDFExporting {
    func export(vacancies: [VacancySearchResult], progress: @escaping @MainActor @Sendable (BulkPDFExportProgress) -> Void) async throws -> BulkPDFExportOutcome
    func export(vacancies: [VacancySearchResult], filters: [String: String], progress: @escaping @MainActor @Sendable (BulkPDFExportProgress) -> Void) async throws -> BulkPDFExportOutcome
}
extension VacanciesPDFExporting {
    func export(vacancies: [VacancySearchResult], filters: [String: String], progress: @escaping @MainActor @Sendable (BulkPDFExportProgress) -> Void) async throws -> BulkPDFExportOutcome {
        try await export(vacancies: vacancies, progress: progress)
    }
}

/// Writes new files and never replaces one: each name, or its first free `_N` variant,
/// is created with O_CREAT | O_EXCL, so checking and creating are a single step. If a
/// later file fails or the task is cancelled, unchanged file identities are removed.
/// Open identity descriptors prevent inode reuse while the batch is in progress.
enum PDFNewFileWriter {
    private final class CreatedFile {
        let url: URL
        private let identityDescriptor: Int32

        init(url: URL, descriptor: Int32) throws {
            self.url = url
            identityDescriptor = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard identityDescriptor >= 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        deinit { Darwin.close(identityDescriptor) }

        func removeIfStillOwned() {
            Self.removeIfStillOwned(at: url, descriptor: identityDescriptor)
        }

        static func removeIfStillOwned(at url: URL, descriptor: Int32) {
            var original = stat()
            var current = stat()
            // lstat deliberately does not follow a replacement symlink.
            guard fstat(descriptor, &original) == 0,
                  lstat(url.path, &current) == 0,
                  original.st_dev == current.st_dev,
                  original.st_ino == current.st_ino,
                  original.st_gen == current.st_gen else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func write(
        _ contents: [Data],
        names: [String],
        in directory: URL,
        maximumCandidates: Int = 10_000,
        beforeEachFile: (Int) throws -> Void = { _ in }
    ) throws -> [URL] {
        guard contents.count == names.count else { throw VacanciesPDFExporter.ExportError.missingPreparedExport }
        var written: [CreatedFile] = []
        do {
            for (index, (data, name)) in zip(contents, names).enumerated() {
                try Task.checkCancellation()
                try beforeEachFile(index)
                written.append(try writeNewFile(data, name: name, in: directory, maximumCandidates: maximumCandidates))
            }
            try Task.checkCancellation()
            return written.map(\.url)
        } catch {
            for file in written { file.removeIfStillOwned() }
            throw error
        }
    }

    static func writeFiles(_ files: [URL], names: [String], in directory: URL) throws -> [URL] {
        guard files.count == names.count else { throw VacanciesPDFExporter.ExportError.missingPreparedExport }
        var written: [CreatedFile] = []
        do {
            for (file, name) in zip(files, names) {
                try Task.checkCancellation()
                let data = try Data(contentsOf: file, options: .mappedIfSafe)
                written.append(try writeNewFile(data, name: name, in: directory, maximumCandidates: 10_000))
            }
            try Task.checkCancellation()
            return written.map(\.url)
        } catch {
            for file in written { file.removeIfStillOwned() }
            throw error
        }
    }

    private static func writeNewFile(_ data: Data, name: String, in directory: URL, maximumCandidates: Int) throws -> CreatedFile {
        for number in 1...max(1, maximumCandidates) {
            let candidate = number == 1 ? name : PDFFileNameBuilder.fileName(
                base: name, semanticSuffix: String(number), fallback: "vacancy"
            )
            let url = directory.appendingPathComponent(candidate)
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
            guard descriptor >= 0 else {
                let code = errno
                if code == EEXIST { continue }
                throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            // Keep the identity alive even after the writer is closed.
            let created: CreatedFile
            do {
                created = try CreatedFile(url: url, descriptor: descriptor)
            } catch {
                CreatedFile.removeIfStillOwned(at: url, descriptor: descriptor)
                try? handle.close()
                throw error
            }
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                created.removeIfStillOwned()
                throw error
            }
            return created
        }
        throw VacanciesPDFExporter.ExportError.noAvailableFileName
    }
}

actor PDFExportWorker {
    private struct PreparedPart: Sendable {
        let file: URL
        let pageCount: Int
        let context: DocumentContext
    }

    private var preparedParts: [PreparedPart]?
    private var stagingDirectory: URL?
    deinit { if let stagingDirectory { try? FileManager.default.removeItem(at: stagingDirectory) } }

    struct PreparedExport: Sendable {
        let partCount: Int
        let pageCount: Int
    }

    init() {}

    /// Trudvsem uses plain source fields, so formatting can run on the worker too.
    func prepareTrudvsem(
        vacancies: [TrudvsemVacancy],
        filters: [String: String] = [:],
        progress: @escaping @MainActor @Sendable (BulkPDFExportProgress) -> Void
    ) async throws -> PreparedExport {
        discardPreparedExport()
        let observations = try verifiedObservations(for: vacancies.map(\.context))
        var snapshots: [PDFVacancySnapshot] = []
        snapshots.reserveCapacity(vacancies.count)
        for vacancy in vacancies {
            try Task.checkCancellation()
            snapshots.append(autoreleasepool {
                TrudvsemPDFFormatter.personal(vacancy, records: vacancy.context.observationIDs.compactMap { observations[$0] }, includeSourceEvidence: false)
            })
        }
        return try await prepare(vacancies: PDFVacanciesSnapshot(snapshots: snapshots), filters: filters, progress: progress)
    }

    func exportTrudvsemPersonal(vacancy: TrudvsemVacancy, destination: URL) throws {
        try Task.checkCancellation()
        try exportDocument(document: TrudvsemPDFFormatter.personal(vacancy), destination: destination)
    }

    func exportTrudvsemStatistics(vacancies: [TrudvsemVacancy], filters: [String: String], destination: URL) throws {
        try Task.checkCancellation()
        try exportDocument(document: TrudvsemPDFFormatter.statistics(vacancies, filters: filters), destination: destination)
    }

    private func verifiedObservations(for contexts: [DocumentContext]) throws -> [String: APIObservation] {
        var observations: [String: APIObservation] = [:]
        for id in Set(contexts.flatMap(\.observationIDs)) {
            try Task.checkCancellation()
            observations[id] = try? PDFSourceEvidence.shared.observation(id)
        }
        return observations
    }

    func prepare(
        vacancies: PDFVacanciesSnapshot,
        filters: [String: String] = [:],
        progress: @escaping @MainActor @Sendable (BulkPDFExportProgress) -> Void
    ) async throws -> PreparedExport {
        discardPreparedExport()
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("VacancyPDF-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        stagingDirectory = staging
        var succeeded = false
        defer { if !succeeded { discardPreparedExport() } }
        try Task.checkCancellation()
        struct Chunk {
            var pages: [VacanciesPDFExporter.Page]
            var contexts: [DocumentContext]
        }
        let started = PDFSourceJSON.timestamp(Date())
        // Cache only within this export. Publication verifies the raw materials again.
        let observations = try verifiedObservations(for: vacancies.values.map(\.context))
        struct HeaderKey: Hashable {
            let source: String
            let vacancyCount: Int
            let observationIDs: [String]
        }
        var headerPageCounts: [HeaderKey: Int] = [:]
        var chunks: [Chunk] = []
        var current = Chunk(pages: [], contexts: [])
        func context(_ contexts: [DocumentContext]) -> DocumentContext {
            DocumentContext(kind: "Все вакансии", vacancyIDs: Array(Set(contexts.flatMap(\.vacancyIDs))).sorted(),
                observationIDs: contexts.flatMap(\.observationIDs), filters: filters,
                source: contexts.first?.source ?? .hh)
        }
        func header(_ c: DocumentContext, part: Int, total: Int, continuation: Bool) -> [VacanciesPDFExporter.Page] {
            let builder = VacancyPDFDocumentBuilder()
            builder.documentHeader(c)
            builder.field("Сформирован", VacancyPDFStyle.utcDate(started))
            builder.field("Часть", "\(part) из \(total)")
            if continuation { builder.field("Продолжение", "Полная карточка вакансии продолжается с предыдущей части") }
            builder.identify(c)
            return autoreleasepool { VacanciesPDFExporter.pages(for: builder.document) }
        }
        func evidencePages(_ c: DocumentContext) -> [VacanciesPDFExporter.Page] {
            let builder = VacancyPDFDocumentBuilder()
            builder.sourceEvidence(c, records: c.observationIDs.compactMap { observations[$0] })
            builder.identify(c)
            return autoreleasepool { VacanciesPDFExporter.pages(for: builder.document) }
        }
        func headerPageCount(_ c: DocumentContext) -> Int {
            let key = HeaderKey(source: c.source.rawValue, vacancyCount: c.vacancyIDs.count, observationIDs: c.observationIDs)
            if let count = headerPageCounts[key] { return count }
            let count = header(c, part: 999999, total: 999999, continuation: true).count + evidencePages(c).count
            headerPageCounts[key] = count
            return count
        }
        let limit = VacanciesPDFExporter.maximumPagesPerFile
        for (index, vacancy) in vacancies.values.enumerated() {
            try Task.checkCancellation()
            var pages = autoreleasepool { VacanciesPDFExporter.pages(for: vacancy.attributedDocument) }[...]
            let candidateContexts = current.contexts + [vacancy.context]
            let overhead = headerPageCount(context(candidateContexts))
            if !current.pages.isEmpty && current.pages.count + pages.count + overhead > limit {
                chunks.append(current); current = Chunk(pages: [], contexts: [])
            }
            while !pages.isEmpty {
                try Task.checkCancellation()
                let contexts = current.contexts + [vacancy.context]
                let capacity = limit - headerPageCount(context(contexts)) - current.pages.count
                guard capacity > 0 else { throw PDFSourceError.invalid("Реквизиты источников превышают лимит части") }
                let count = min(capacity, pages.count)
                current.pages += pages.prefix(count); current.contexts = contexts
                pages = pages.dropFirst(count)
                if !pages.isEmpty { chunks.append(current); current = Chunk(pages: [], contexts: []) }
            }
            await progress(.init(completedVacancies: index + 1, totalVacancies: vacancies.values.count))
        }
        if !current.pages.isEmpty { chunks.append(current) }
        var parts: [PreparedPart] = []
        var previousIDs = Set<String>()
        var pageOffset = 0
        for index in chunks.indices {
            try Task.checkCancellation()
            let chunk = chunks[index]
            chunks[index] = Chunk(pages: [], contexts: [])
            await progress(.init(completedVacancies: vacancies.values.count, totalVacancies: vacancies.values.count,
                                 stage: "Формирование части \(index + 1) из \(chunks.count)"))
            let c = context(chunk.contexts)
            let continuation = !previousIDs.isDisjoint(with: c.vacancyIDs)
            let headerPages = header(c, part: index + 1, total: chunks.count, continuation: continuation)
            let combined = NSMutableAttributedString(attributedString: headerPages.last!.content)
            combined.append(chunk.pages[0].content)
            let leadingPages = autoreleasepool { VacanciesPDFExporter.pages(for: combined) }
            let pages = Array(headerPages.dropLast()) + leadingPages + Array(chunk.pages.dropFirst()) + evidencePages(c)
            guard pages.count <= limit else { throw PDFSourceError.invalid("Превышен лимит страниц") }
            let rendered = try autoreleasepool {
                try documentedData(pages: pages, context: c, pageOffset: pageOffset)
            }
            pageOffset += pages.count
            let file = staging.appendingPathComponent("part-\(index).pdf")
            try rendered.data.write(to: file, options: .atomic)
            parts.append(.init(file: file, pageCount: rendered.count, context: c))
            previousIDs = Set(c.vacancyIDs)
        }
        preparedParts = parts
        succeeded = true
        return PreparedExport(partCount: parts.count, pageCount: parts.reduce(0) { $0 + $1.pageCount })
    }

    func discardPreparedExport() {
        preparedParts = nil
        if let stagingDirectory { try? FileManager.default.removeItem(at: stagingDirectory) }
        stagingDirectory = nil
    }

    func exportDocument(document: PDFVacancySnapshot, destination: URL) throws {
        try Task.checkCancellation()
        let pages = VacanciesPDFExporter.pages(for: document.attributedDocument)
        let data = try documentedData(pages: pages, context: document.context).data
        try Task.checkCancellation()
        _ = try PDFNewFileWriter.write([data], names: [destination.lastPathComponent], in: destination.deletingLastPathComponent())
    }

    private func documentedData(pages: [VacanciesPDFExporter.Page], context: DocumentContext, pageOffset: Int = 0,
                                didRenderPage: (@Sendable (Int) -> Void)? = nil) throws -> (data: Data, count: Int) {
        let materials = try PDFSourceEvidence.shared.materials(for: context)
        let rendered = try VacanciesPDFExporter.pdfData(for: pages, pageOffset: pageOffset, didRenderPage: didRenderPage)
        let data = try PDFOriginalMaterials.embed(materials, in: rendered)
        try VacanciesPDFExporter.validatePDF(data: data, expectedPages: pages.count)
        return (data, pages.count)
    }

    func exportPersonal(
        vacancy: PDFVacancySnapshot,
        destination: URL,
        didRenderPage: (@Sendable (Int) -> Void)? = nil
    ) throws {
        try Task.checkCancellation()
        let pages = autoreleasepool {
            VacanciesPDFExporter.pages(for: vacancy.attributedDocument)
        }
        try Task.checkCancellation()
        let data = try documentedData(pages: pages, context: vacancy.context, didRenderPage: didRenderPage).data
        try Task.checkCancellation()
        _ = try PDFNewFileWriter.write([data], names: [destination.lastPathComponent], in: destination.deletingLastPathComponent())
    }

    func exportStatistics(report: VacancyStatisticsReport, destination: URL) throws {
        try Task.checkCancellation()
        let pages = try autoreleasepool {
            try VacanciesPDFExporter.pages(for: report.attributedDocument())
        }
        let data = try documentedData(pages: pages, context: report.documentContext).data
        try Task.checkCancellation()
        _ = try PDFNewFileWriter.write([data], names: [destination.lastPathComponent], in: destination.deletingLastPathComponent())
    }

    /// Writes the prepared parts as new files; see PDFNewFileWriter.
    func writePrepared(names: [String], directory: URL) throws -> [URL] {
        guard let parts = preparedParts else {
            throw VacanciesPDFExporter.ExportError.missingPreparedExport
        }
        defer { discardPreparedExport() }
        return try PDFNewFileWriter.writeFiles(parts.map(\.file), names: names, in: directory)
    }
}

@MainActor
final class VacanciesPDFExporter: VacanciesPDFExporting {
    nonisolated static let maximumPagesPerFile = 100

    struct Page: @unchecked Sendable {
        let content: NSAttributedString
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
    /// A paragraph that starts on a page and would cross its end moves to the next page;
    /// a whitespace-only tail joins the previous page instead of becoming a blank page.
    nonisolated static func pages(for attributedText: NSAttributedString) -> [Page] {
        guard attributedText.length > 0 else { return [Page(content: attributedText)] }
        let contentWidth = VacancyPDFDefaults.paperSize.width - VacancyPDFDefaults.horizontalMargin * 2
        let pageHeight = VacancyPDFDefaults.paperSize.height - VacancyPDFDefaults.verticalMargin * 2
            - VacancyPDFDefaults.paginationBottomSafetyMargin

        let lines: [(start: Int, minY: CGFloat, maxY: CGFloat)] = autoreleasepool {
            let textStorage = NSTextStorage(attributedString: attributedText)
            let layoutManager = NSLayoutManager()
            textStorage.addLayoutManager(layoutManager)
            let container = NSTextContainer(size: NSSize(width: contentWidth, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)
            var result: [(start: Int, minY: CGFloat, maxY: CGFloat)] = []
            layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) {
                rect, _, _, glyphRange, _ in
                let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
                result.append((characters.location, rect.minY, rect.maxY))
            }
            return result
        }
        guard !lines.isEmpty else { return [Page(content: attributedText)] }

        let source = attributedText.string as NSString
        var pageStarts = [0]
        var index = 1
        while index < lines.count {
            let first = pageStarts[pageStarts.count - 1]
            guard lines[index].maxY - lines[first].minY > pageHeight else {
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
                if lines[paragraphLast].maxY - lines[paragraphFirst].minY <= pageHeight { next = paragraphFirst }
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
                let merged = NSMutableAttributedString(attributedString: previous.content)
                merged.append(attributedText.attributedSubstring(from: range))
                pages[pages.count - 1] = Page(content: merged)
            } else {
                pages.append(Page(content: attributedText.attributedSubstring(from: range)))
            }
        }
        return pages.isEmpty ? [Page(content: attributedText)] : pages
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
                let monochromeContent = NSMutableAttributedString(attributedString: page.content)
                monochromeContent.removeAttribute(.link, range: NSRange(location: 0, length: monochromeContent.length))
                monochromeContent.draw(
                    with: NSRect(
                        x: VacancyPDFDefaults.horizontalMargin, y: VacancyPDFDefaults.verticalMargin,
                        width: VacancyPDFDefaults.paperSize.width - VacancyPDFDefaults.horizontalMargin * 2,
                        height: VacancyPDFDefaults.paperSize.height - VacancyPDFDefaults.verticalMargin * 2
                    ),
                    options: [.usesLineFragmentOrigin, .usesFontLeading]
                )
                var links: [(URL, NSRange)] = []
                page.content.enumerateAttribute(.link, in: NSRange(location: 0, length: page.content.length)) { value, range, _ in
                    guard let value, let url = (value as? URL) ?? URL(string: String(describing: value)) else { return }
                    links.append((url, range))
                }
                if !links.isEmpty {
                    let linkStorage = NSTextStorage(attributedString: monochromeContent)
                    let linkLayout = NSLayoutManager()
                    let linkContainer = NSTextContainer(size: NSSize(width: VacancyPDFDefaults.paperSize.width - VacancyPDFDefaults.horizontalMargin * 2, height: .greatestFiniteMagnitude))
                    linkContainer.lineFragmentPadding = 0
                    linkStorage.addLayoutManager(linkLayout)
                    linkLayout.addTextContainer(linkContainer)
                    linkLayout.ensureLayout(for: linkContainer)
                    for (url, range) in links {
                        let glyphs = linkLayout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
                        linkLayout.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: linkContainer) { rect, _ in
                            context.setURL(url as CFURL, for: CGRect(x: rect.minX + VacancyPDFDefaults.horizontalMargin,
                                y: VacancyPDFDefaults.paperSize.height - VacancyPDFDefaults.verticalMargin - rect.maxY,
                                width: rect.width, height: rect.height))
                        }
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
