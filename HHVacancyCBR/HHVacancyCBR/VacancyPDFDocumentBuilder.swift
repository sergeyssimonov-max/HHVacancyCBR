import AppKit
import Foundation

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
        section("Данные для проверки")
        provenance("При наличии сохранённых ответов API файл включает их исходные данные и реквизиты получения: адреса запросов, параметры, время по часам устройства, идентификаторы и контрольные суммы. Вложения содержат JSON и, если источник предоставил, разметку описания вакансии. Они не являются снимком внешнего вида страницы сайта.")
        provenance("Документы, полученные через интернет, могут представляться как письменные доказательства при соблюдении применимых условий: статья 71 Гражданского процессуального кодекса Российской Федерации. Относимость, допустимость и достоверность оценивает суд.")
        provenance("Материалы могут быть исследованы при судебной компьютерно-технической экспертизе с применением соответствующих экспертных методик. При необходимости суд может истребовать сведения у оператора площадки (статьи 57 и 79 Гражданского процессуального кодекса Российской Федерации).")
        let covered = Set(records.flatMap(\.vacancyIDs))
        if records.count < context.observationIDs.count || !Set(context.vacancyIDs).isSubset(of: covered) {
            provenance("Исходный ответ для части вакансий не сохранился или повреждён. Его контрольная сумма не подтверждена.")
        }
        guard !records.isEmpty else { return }
        for (index, record) in records.enumerated() {
            field("Ответ API №\(index + 1)", record.endpoint + " · сохранён " + VacancyPDFStyle.utcDate(record.receivedAt))
            field("Запрос", record.method + " · " + record.parameters.keys.sorted().map { "\($0)=\(record.parameters[$0]!)" }.joined(separator: "&"))
            field("Отправлен", VacancyPDFStyle.utcDate(record.sentAt))
            field("HTTP / байт", "\(record.httpStatus) / \(record.byteCount)")
            field("Алгоритм хеша", record.algorithm == MaterialHash.algorithm ? MaterialHash.displayName : record.algorithm)
            hashField("Хеш ответа №\(index + 1)", record.hash)
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
