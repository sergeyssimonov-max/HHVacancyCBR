import Foundation

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var readableHTMLText: String {
        // Bound temporary Foundation allocations during bulk vacancy conversion.
        autoreleasepool {
            var value = self
            value = value.replacingOccurrences(
                of: "<(script|style)\\b[^>]*>[\\s\\S]*?</\\1>",
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            value = value.replacingOccurrences(of: "<\\s*br\\s*/?\\s*>", with: "\n", options: [.regularExpression, .caseInsensitive])
            value = value.replacingOccurrences(of: "<\\s*li\\b[^>]*>", with: "\n– ", options: [.regularExpression, .caseInsensitive])
            value = value.replacingOccurrences(of: "</\\s*(p|div|h[1-6]|li|ul|ol|blockquote)\\s*>", with: "\n", options: [.regularExpression, .caseInsensitive])
            value = value.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            value = value
                .replacingOccurrences(of: "&nbsp;", with: " ")
                                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&laquo;", with: "«")
                .replacingOccurrences(of: "&raquo;", with: "»")
                .replacingOccurrences(of: "&mdash;", with: "—")
                .replacingOccurrences(of: "&ndash;", with: "–")
                .replacingOccurrences(of: "&amp;", with: "&")
            value = value.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            value = value.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
            value = value.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

}
