import Foundation

/// Adds EmbeddedFiles to a freshly generated, unencrypted CoreGraphics PDF.
/// Original page streams are untouched. Unsupported PDF structures fail closed.
/// Binary source bytes are stored in unfiltered streams and recoverable exactly.
enum PDFOriginalMaterials {
    static func embed(_ materials: [PDFSourceEvidence.Material], in pdf: Data) throws -> Data {
        let text = String(decoding: pdf, as: UTF8.self)
        func captures(_ pattern: String, _ input: String) throws -> [String] {
            let regex = try NSRegularExpression(pattern: pattern)
            guard let match = regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).last else { throw PDFSourceError.invalid("Структура исходного PDF не поддерживается") }
            return (0..<match.numberOfRanges).map { (input as NSString).substring(with: match.range(at: $0)) }
        }
        let trailer = try captures(#"trailer\s*(<<[\s\S]*?>>)\s*startxref\s*(\d+)\s*%%EOF"#, text)
        guard !trailer[1].contains("/Encrypt") else { throw PDFSourceError.invalid("Зашифрованный PDF") }
        let root = try captures(#"/Root\s+(\d+)\s+(\d+)\s+R"#, trailer[1])
        let size = try captures(#"/Size\s+(\d+)"#, trailer[1])
        guard let firstID = Int(size[1]), let rootID = Int(root[1]), root[2] == "0" else { throw PDFSourceError.invalid("Каталог PDF") }
        let catalog = try captures("(?:^|[\\r\\n])" + root[1] + #"\s+0\s+obj\s*(<<[\s\S]*?>>)\s*endobj"#, text)[1]
        guard !catalog.contains("/Names"), !catalog.contains("/EmbeddedFiles") else { throw PDFSourceError.invalid("PDF уже содержит дерево имён") }
        var result = pdf
        result.append(Data("\n".utf8))
        var offsets: [(Int, Int)] = []
        var nextID = firstID
        func object(_ id: Int, _ body: Data) {
            offsets.append((id, result.count))
            result.append(Data("\(id) 0 obj\n".utf8)); result.append(body); result.append(Data("\nendobj\n".utf8))
        }
        func literal(_ value: String) -> String {
            value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
        }
        var names: [String] = []
        for material in materials.sorted(by: { $0.path < $1.path }) {
            guard material.path.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { throw PDFSourceError.invalid("Имя вложения PDF") }
            let streamID = nextID; nextID += 1
            let specID = nextID; nextID += 1
            var stream = Data("<< /Type /EmbeddedFile /Length \(material.data.count) >>\nstream\n".utf8)
            stream.append(material.data); stream.append(Data("\nendstream".utf8))
            object(streamID, stream)
            let name = literal(material.path)
            object(specID, Data("<< /Type /Filespec /F (\(name)) /UF (\(name)) /EF << /F \(streamID) 0 R >> >>".utf8))
            names.append("(\(name)) \(specID) 0 R")
        }
        let namesID = nextID; nextID += 1
        object(namesID, Data(("<< /Names [" + names.joined(separator: " ") + "] >>").utf8))
        object(rootID, Data((String(catalog.dropLast(2)) + " /Names << /EmbeddedFiles \(namesID) 0 R >> >>").utf8))
        let xref = result.count
        result.append(Data("xref\n".utf8))
        for (id, offset) in offsets.sorted(by: { $0.0 < $1.0 }) {
            result.append(Data("\(id) 1\n\(String(format: "%010d", offset)) 00000 n \n".utf8))
        }
        let info = (try? captures(#"(/Info\s+\d+\s+\d+\s+R)"#, trailer[1])[1]) ?? ""
        result.append(Data("trailer\n<< /Size \(nextID) /Root \(rootID) 0 R /Prev \(trailer[2]) \(info) >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return result
    }
}
