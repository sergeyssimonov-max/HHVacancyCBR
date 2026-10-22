import Foundation
import CryptoKit

/// A matching digest verifies that the saved response bytes are unchanged.
enum MaterialHash {
    static let algorithm = "GOST-R-34.11-2012-512"
    static let displayName = "ГОСТ Р 34.11-2012 «Информационная технология. Криптографическая защита информации. Функция хэширования», 512 бит"
    static func digest(_ data: Data, algorithm: String = algorithm) throws -> String {
        if algorithm == "SHA-256" { return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        guard algorithm == self.algorithm else { throw PDFSourceError.invalid("Неизвестный алгоритм") }
        var bytes = [UInt8](repeating: 0, count: 64)
        data.withUnsafeBytes { raw in hh_streebog512(raw.bindMemory(to: UInt8.self).baseAddress, data.count, &bytes) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum PDFSourceError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let reason) = self { return "Источник PDF: " + reason }; return nil }
}

enum PDFSourceJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(secondsFromGMT: 0)
        return f.string(from: date)
    }
    static func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: text)
    }
}

struct APIObservation: Codable, Identifiable, Sendable {
    var source: VacancySource? = nil
    var resolvedSource: VacancySource { source ?? .hh }
    let version: Int
    let id: String
    let endpoint: String
    let parameters: [String: String]
    let sentAt: String
    let receivedAt: String
    let httpStatus: Int
    let vacancyIDs: [String]
    let algorithm: String
    let hash: String
    let byteCount: Int
    let method: String
}

struct DocumentContext: Sendable {
    let source: VacancySource
    let kind: String
    let filters: [String: String]
    let vacancyIDs: [String]
    let observationIDs: [String]
    init(kind: String, vacancyIDs: [String], observationIDs: [String] = [], filters: [String: String] = [:], source: VacancySource = .hh) {
        self.source = source
        self.kind = kind
        self.filters = filters; self.vacancyIDs = vacancyIDs
        self.observationIDs = Array(Set(observationIDs)).sorted()
    }
}

extension DocumentContext {
    static func vacancy(_ value: VacancySearchResult) -> DocumentContext {
        DocumentContext(kind: "Сведения о вакансии", vacancyIDs: [value.id], observationIDs: value.observationIDs)
    }
}

/// Append-only directories. A complete transaction becomes visible only after rename.
/// Legacy snapshots remain untouched and are never fabricated as raw responses.
final class PDFSourceEvidence: @unchecked Sendable {
    static let shared = PDFSourceEvidence()
    private let configuredRoot: URL?
    private let lock = NSRecursiveLock()
    init(root: URL? = nil) { configuredRoot = root }
    var root: URL { get throws {
        if let configuredRoot { return configuredRoot }
        // XCTest must not add synthetic fixtures to the user's real source receipts.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("HHVacancyCBR-tests-\(ProcessInfo.processInfo.processIdentifier)")
        }
        // Preserve this directory name so existing source receipts remain readable.
        return try ApplicationSupportLocation.fileURL(named: "documented-archive-v1", fileManager: .default)
    } }
    private func directory(_ name: String) throws -> URL {
        let url = try root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        return url
    }
    private func validID(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw PDFSourceError.invalid("Некорректный идентификатор") }
    }
    private func transaction(parent: URL, id: String, write: (URL) throws -> Void) throws -> URL {
        try validID(id)
        let target = parent.appendingPathComponent(id)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw PDFSourceError.invalid("Запись уже существует") }
        let staging = parent.appendingPathComponent(".pending-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: staging) }
        try write(staging)
        try FileManager.default.moveItem(at: staging, to: target)
        return target
    }
    /// Only public vacancy responses. Headers and authorization never enter persistence.
    @discardableResult
    func capture(data: Data, url: URL, status: Int, sent: Date, received: Date) throws -> APIObservation? {
        lock.lock(); defer { lock.unlock() }
        let source: VacancySource
        if url.host == "api.hh.ru", url.path == "/vacancies" || url.path.hasPrefix("/vacancies/") { source = .hh }
        else if url.host == "opendata.trudvsem.ru", url.path.hasPrefix("/api/v1/vacancies/") { source = .trudvsem }
        else { return nil }
        guard (200...299).contains(status) else { return nil }
        let object = try JSONSerialization.jsonObject(with: data)
        func secret(_ object: Any) -> Bool {
            if let dict = object as? [String: Any] {
                return dict.contains { key, value in
                    ["access_token", "refresh_token", "authorization", "client_secret", "password", "cookie"].contains(key.lowercased()) || secret(value)
                }
            }
            return (object as? [Any])?.contains(where: secret) ?? false
        }
        guard !secret(object) else { throw PDFSourceError.invalid("Ответ содержит секретное поле") }
        let dict = object as? [String: Any] ?? [:]
        var ids = (dict["items"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? (dict["id"] as? String).map { [$0] } ?? []
        if source == .trudvsem {
            let entries = (dict["results"] as? [String: Any])?["vacancies"] as? [[String: Any]] ?? []
            ids = entries.compactMap { wrapper in
                guard let v = wrapper["vacancy"] as? [String: Any], let id = v["id"] as? String,
                      let company = v["company"] as? [String: Any], let code = company["companycode"] as? String else { return nil }
                return "trudvsem.ru:\(code):\(id)"
            }
        }
        let allowed = Set(["employer_id", "area", "page", "per_page", "text", "order_by", "date_from", "date_to", "experience", "work_format", "schedule", "limit", "offset", "modifiedFrom", "modifiedTo"])
        var parameters: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] where allowed.contains(item.name) { parameters[item.name] = item.value ?? "" }
        let observation = APIObservation(source: source, version: 1, id: UUID().uuidString.lowercased(), endpoint: "https://" + (url.host ?? "") + url.path,
            parameters: parameters, sentAt: PDFSourceJSON.timestamp(sent), receivedAt: PDFSourceJSON.timestamp(received), httpStatus: status,
            vacancyIDs: ids, algorithm: MaterialHash.algorithm, hash: try MaterialHash.digest(data), byteCount: data.count, method: "GET")
        _ = try transaction(parent: directory("observations"), id: observation.id) { folder in
            try data.write(to: folder.appendingPathComponent("response.json"), options: .withoutOverwriting)
            try PDFSourceJSON.encode(observation).write(to: folder.appendingPathComponent("observation.json"), options: .withoutOverwriting)
        }
        return observation
    }
    func observation(_ id: String) throws -> APIObservation {
        try validID(id)
        let folder = try directory("observations").appendingPathComponent(id)
        let record = try JSONDecoder().decode(APIObservation.self, from: Data(contentsOf: folder.appendingPathComponent("observation.json")))
        guard record.version == 1, record.id == id else { throw PDFSourceError.invalid("Версия или ID наблюдения") }
        let raw = try Data(contentsOf: folder.appendingPathComponent("response.json"))
        guard raw.count == record.byteCount, try MaterialHash.digest(raw, algorithm: record.algorithm) == record.hash else { throw PDFSourceError.invalid("Повреждён ответ API") }
        return record
    }
    struct Material {
        let path: String
        let data: Data
        let type: String
        let observationIDs: [String]
    }
    func materials(for context: DocumentContext) throws -> [Material] {
        lock.lock(); defer { lock.unlock() }
        var result: [Material] = []
        var covered = Set<String>()
        var hashes = Set<String>()
        for (index, id) in context.observationIDs.enumerated() {
            let record = try observation(id)
            guard record.resolvedSource == context.source else { throw PDFSourceError.invalid("Подмена источника") }
            covered.formUnion(record.vacancyIDs)
            guard !Set(record.vacancyIDs).isDisjoint(with: context.vacancyIDs) else { throw PDFSourceError.invalid("Несвязанный материал") }
            guard hashes.insert(record.hash).inserted else { continue }
            let source = try directory("observations").appendingPathComponent(id)
            result.append(Material(path: String(format: "sources/response-%03d.json", index + 1),
                                   data: try Data(contentsOf: source.appendingPathComponent("response.json")),
                                   type: "api-response", observationIDs: [id]))
        }
        guard Set(context.vacancyIDs).isSubset(of: covered), !context.vacancyIDs.isEmpty else {
            throw PDFSourceError.invalid("Для части вакансий отсутствуют исходные ответы API. Обновите источник.")
        }
        return result
    }
}

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
