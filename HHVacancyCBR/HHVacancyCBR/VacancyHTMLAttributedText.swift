import AppKit
import Foundation

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
