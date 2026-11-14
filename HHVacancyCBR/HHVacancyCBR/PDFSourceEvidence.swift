import Foundation
import CryptoKit

/// A matching digest checks consistency, not origin or time of receipt.
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
        try validatedObservation(id).record
    }

    private func validatedObservation(_ id: String) throws -> (record: APIObservation, data: Data) {
        try validID(id)
        let folder = try directory("observations").appendingPathComponent(id)
        let record = try JSONDecoder().decode(APIObservation.self, from: Data(contentsOf: folder.appendingPathComponent("observation.json")))
        guard record.version == 1, record.id == id else { throw PDFSourceError.invalid("Версия или ID наблюдения") }
        let raw = try Data(contentsOf: folder.appendingPathComponent("response.json"))
        guard raw.count == record.byteCount, try MaterialHash.digest(raw, algorithm: record.algorithm) == record.hash else { throw PDFSourceError.invalid("Повреждён ответ API") }
        return (record, raw)
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
            try Task.checkCancellation()
            let record: APIObservation
            let raw: Data
            do { (record, raw) = try validatedObservation(id) }
            catch {
                result.append(Material(path: "sources/unavailable-\(index + 1).txt",
                    data: Data("Исходный ответ не сохранился или повреждён; контрольная сумма не подтверждена.".utf8),
                    type: "source-warning", observationIDs: [id]))
                continue
            }
            guard record.resolvedSource == context.source else { throw PDFSourceError.invalid("Подмена источника") }
            covered.formUnion(record.vacancyIDs)
            guard !Set(record.vacancyIDs).isDisjoint(with: context.vacancyIDs) else { throw PDFSourceError.invalid("Несвязанный материал") }
            guard hashes.insert(record.hash).inserted else { continue }
            result.append(Material(path: String(format: "sources/response-%03d.json", index + 1),
                                   data: raw,
                                   type: "api-response", observationIDs: [id]))
        }
        guard Set(context.vacancyIDs).isSubset(of: covered), !context.vacancyIDs.isEmpty else {
            result.append(Material(path: "sources/incomplete.txt",
                data: Data("Для части вакансий исходные ответы отсутствуют или повреждены. Происхождение данных не подтверждено.".utf8),
                type: "source-warning", observationIDs: []))
            return result
        }
        return result
    }
}
