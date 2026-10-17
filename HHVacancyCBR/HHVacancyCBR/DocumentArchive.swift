import Foundation
import CryptoKit

/// Digests identify bytes, not signatures or timestamps issued by a trusted party.
enum MaterialHash {
    static let algorithm = "GOST-R-34.11-2012-512"
    static func digest(_ data: Data, algorithm: String = algorithm) throws -> String {
        if algorithm == "SHA-256" { return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        guard algorithm == self.algorithm else { throw ArchiveError.invalid("Неизвестный алгоритм") }
        var bytes = [UInt8](repeating: 0, count: 64)
        data.withUnsafeBytes { raw in hh_streebog512(raw.bindMemory(to: UInt8.self).baseAddress, data.count, &bytes) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

enum ArchiveError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let reason) = self { return "Архив: " + reason }; return nil }
}

enum ArchiveJSON {
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

struct HistoricalVacancy: Identifiable {
    let observation: APIObservation
    let value: VacancySearchResult
    var id: String { observation.id + ":" + value.id }
}

struct DocumentContext: Codable, Sendable {
    let id: String
    let createdAt: String
    let kind: String
    let applicationVersion: String
    let build: String
    let periodFrom: String?
    let periodTo: String?
    let filters: [String: String]
    let vacancyIDs: [String]
    let observationIDs: [String]
    init(id: String = UUID().uuidString.lowercased(), kind: String, vacancyIDs: [String], observationIDs: [String] = [], filters: [String: String] = [:],
         periodFrom: Date? = nil, periodTo: Date? = nil, createdAt: Date = Date()) {
        self.id = id
        self.createdAt = ArchiveJSON.timestamp(createdAt)
        self.kind = kind
        applicationVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Не указана"
        build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Не указан"
        self.periodFrom = periodFrom.map(ArchiveJSON.timestamp); self.periodTo = periodTo.map(ArchiveJSON.timestamp)
        self.filters = filters; self.vacancyIDs = vacancyIDs
        self.observationIDs = Array(Set(observationIDs)).sorted()
    }
}

extension DocumentContext {
    static func vacancy(_ value: VacancySearchResult) -> DocumentContext {
        DocumentContext(kind: "Отчет об автоматизированной фиксации сведений о вакансии", vacancyIDs: [value.id], observationIDs: value.observationIDs,
                        filters: ["Работодатель": value.employerName, "ID работодателя hh.ru": value.employerID ?? "Не указан",
                                  "Категория HHVacancyCBR": value.isFieldInstitution ? "Полевые учреждения" : "Общая выборка",
                                  "Местность hh.ru": value.summary.area?.name ?? "Не указана"])
    }
}

struct ArchiveManifest: Codable, Sendable {
    struct File: Codable, Sendable {
        let path: String
        let type: String
        let size: Int
        let algorithm: String
        let hash: String
        let observationIDs: [String]
    }
    let version: Int
    let report: DocumentContext
    let files: [File]
}

/// Append-only directories. A complete transaction becomes visible only after rename.
/// Legacy favorites/snapshots remain untouched and are never fabricated as raw responses.
final class DocumentArchive: @unchecked Sendable {
    static let shared = DocumentArchive()
    private let configuredRoot: URL?
    private let lock = NSRecursiveLock()
    init(root: URL? = nil) { configuredRoot = root }
    var root: URL { get throws {
        if let configuredRoot { return configuredRoot }
        // XCTest must not add synthetic fixtures to the user's real archive.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory.appendingPathComponent("HHVacancyCBR-tests-\(ProcessInfo.processInfo.processIdentifier)")
        }
        return try ApplicationSupportLocation.fileURL(named: "documented-archive-v1", fileManager: .default)
    } }
    private func directory(_ name: String) throws -> URL {
        let url = try root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                              attributes: [.posixPermissions: 0o700])
        return url
    }
    private func validID(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw ArchiveError.invalid("Некорректный идентификатор") }
    }
    private func safeFile(_ path: String, in directory: URL) throws -> URL {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw ArchiveError.invalid("Некорректный путь") }
        let result = directory.appendingPathComponent(path)
        let parent = directory.resolvingSymlinksInPath().path + "/"
        guard result.resolvingSymlinksInPath().path.hasPrefix(parent) else { throw ArchiveError.invalid("Путь выходит за комплект") }
        var current = directory
        for part in parts {
            current.appendPathComponent(String(part))
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw ArchiveError.invalid("Символические ссылки запрещены")
            }
        }
        return result
    }
    private func transaction(parent: URL, id: String, write: (URL) throws -> Void) throws -> URL {
        try validID(id)
        let target = parent.appendingPathComponent(id)
        guard !FileManager.default.fileExists(atPath: target.path) else { throw ArchiveError.invalid("Запись уже существует") }
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
        guard url.host == "api.hh.ru", url.path == "/vacancies" || url.path.hasPrefix("/vacancies/") else { return nil }
        guard (200...299).contains(status) else { diagnostic("HTTP \(status)"); return nil }
        let object = try JSONSerialization.jsonObject(with: data)
        func secret(_ object: Any) -> Bool {
            if let dict = object as? [String: Any] {
                return dict.contains { key, value in
                    ["access_token", "refresh_token", "authorization", "client_secret", "password", "cookie"].contains(key.lowercased()) || secret(value)
                }
            }
            return (object as? [Any])?.contains(where: secret) ?? false
        }
        guard !secret(object) else { diagnostic("Ответ с секретным полем не сохранён"); throw ArchiveError.invalid("Ответ содержит секретное поле") }
        let dict = object as? [String: Any] ?? [:]
        let ids = (dict["items"] as? [[String: Any]])?.compactMap { $0["id"] as? String } ?? (dict["id"] as? String).map { [$0] } ?? []
        let allowed = Set(["employer_id", "area", "page", "per_page", "text", "order_by", "date_from", "date_to", "experience", "work_format", "schedule"])
        var parameters: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] where allowed.contains(item.name) { parameters[item.name] = item.value ?? "" }
        let observation = APIObservation(version: 1, id: UUID().uuidString.lowercased(), endpoint: "https://api.hh.ru" + url.path,
            parameters: parameters, sentAt: ArchiveJSON.timestamp(sent), receivedAt: ArchiveJSON.timestamp(received), httpStatus: status,
            vacancyIDs: ids, algorithm: MaterialHash.algorithm, hash: try MaterialHash.digest(data), byteCount: data.count, method: "GET · HeadHunter API · URLSession")
        _ = try transaction(parent: directory("observations"), id: observation.id) { folder in
            try data.write(to: folder.appendingPathComponent("response.json"), options: .withoutOverwriting)
            try ArchiveJSON.encode(observation).write(to: folder.appendingPathComponent("observation.json"), options: .withoutOverwriting)
        }
        return observation
    }
    func diagnostic(_ code: String) {
        // Callers supply fixed technical codes, never requests, headers, or server bodies.
        lock.lock(); defer { lock.unlock() }
        guard let folder = try? directory("diagnostics") else { return }
        try? Data((ArchiveJSON.timestamp(Date()) + " " + code).utf8).write(to: folder.appendingPathComponent(UUID().uuidString + ".log"), options: .withoutOverwriting)
    }
    func observation(_ id: String) throws -> APIObservation {
        try validID(id)
        let folder = try directory("observations").appendingPathComponent(id)
        let record = try JSONDecoder().decode(APIObservation.self, from: Data(contentsOf: folder.appendingPathComponent("observation.json")))
        guard record.version == 1, record.id == id else { throw ArchiveError.invalid("Версия или ID наблюдения") }
        let raw = try Data(contentsOf: folder.appendingPathComponent("response.json"))
        guard raw.count == record.byteCount, try MaterialHash.digest(raw, algorithm: record.algorithm) == record.hash else { throw ArchiveError.invalid("Повреждён ответ API") }
        return record
    }
    func observations() throws -> [APIObservation] {
        lock.lock(); defer { lock.unlock() }
        return try FileManager.default.contentsOfDirectory(at: directory("observations"), includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }.map { try observation($0.lastPathComponent) }
            .sorted { ($0.receivedAt, $0.id) < ($1.receivedAt, $1.id) }
    }
    func history(from: Date = .distantPast, to: Date = .distantFuture) throws -> [HistoricalVacancy] {
        try observations().filter { guard let d = ArchiveJSON.date($0.receivedAt) else { return false }; return d >= from && d <= to }.flatMap { record in
            let raw = try Data(contentsOf: directory("observations").appendingPathComponent(record.id + "/response.json"))
            if record.endpoint.hasSuffix("/vacancies") {
                let response = try JSONDecoder().decode(HHVacancySearchResponse.self, from: raw)
                return response.items.map { item in
                    var summary = item; summary.observationID = record.id
                    return HistoricalVacancy(observation: record, value: VacancySearchResult(summary: summary, location: .unknown))
                }
            }
            var details = try JSONDecoder().decode(HHVacancyDetails.self, from: raw); details.observationID = record.id
            var summary = HHVacancySummary(id: details.id, name: details.name, employer: details.employer, salary: details.salary,
                area: details.area, alternateURL: details.alternateURL, url: nil, snippet: nil, publishedAt: details.publishedAt)
            summary.observationID = record.id
            return [HistoricalVacancy(observation: record, value: VacancySearchResult(id: details.id, summary: summary, details: details, isDetailLoaded: true))]
        }
    }
    struct WebCapture: Codable {
        let id: String
        let observationID: String
        let vacancyID: String
        let url: String
        let capturedAt: String
        let method: String
        let width: Int
        let height: Int
        let algorithm: String
        let hash: String
    }
    func captureWeb(png: Data, url: URL, observationID: String, vacancyID: String, width: Int, height: Int) throws {
        lock.lock(); defer { lock.unlock() }
        let observation = try self.observation(observationID)
        guard observation.vacancyIDs.contains(vacancyID), url.scheme == "https",
              url.host == "hh.ru" || url.host?.hasSuffix(".hh.ru") == true,
              url.path == "/vacancy/" + vacancyID,
              png.starts(with: [137,80,78,71,13,10,26,10]) else { throw ArchiveError.invalid("Неподходящий снимок страницы") }
        var safeURL = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        safeURL.query = nil; safeURL.fragment = nil; safeURL.user = nil; safeURL.password = nil
        let record = WebCapture(id: UUID().uuidString.lowercased(), observationID: observationID, vacancyID: vacancyID,
            url: safeURL.string!, capturedAt: ArchiveJSON.timestamp(Date()), method: "WKWebView.takeSnapshot · видимая область",
            width: width, height: height, algorithm: MaterialHash.algorithm, hash: try MaterialHash.digest(png))
        _ = try transaction(parent: directory("web-captures"), id: record.id) { folder in
            try png.write(to: folder.appendingPathComponent("viewport.png"), options: .withoutOverwriting)
            try ArchiveJSON.encode(record).write(to: folder.appendingPathComponent("capture.json"), options: .withoutOverwriting)
        }
    }

    struct Material {
        let path: String
        let data: Data
        let type: String
        let observationIDs: [String]
    }
    func materials(for context: DocumentContext) throws -> [Material] {
        lock.lock(); defer { lock.unlock() }
        var result = [Material(path: "report.json", data: try ArchiveJSON.encode(context), type: "report-metadata", observationIDs: context.observationIDs)]
        var related = Set(context.observationIDs)
        let selected = try context.observationIDs.map { try observation($0) }
        if let cutoff = selected.map(\.receivedAt).max() {
            for record in try observations() where record.receivedAt <= cutoff && !Set(record.vacancyIDs).isDisjoint(with: context.vacancyIDs) { related.insert(record.id) }
        }
        for id in related.sorted() {
            let record = try observation(id)
            guard !Set(record.vacancyIDs).isDisjoint(with: context.vacancyIDs) else { throw ArchiveError.invalid("Несвязанный материал") }
            let source = try directory("observations").appendingPathComponent(id)
            for (name, type) in [("response.json", "api-response"), ("observation.json", "observation-metadata")] {
                result.append(Material(path: "observations/\(id)/" + name, data: try Data(contentsOf: source.appendingPathComponent(name)), type: type, observationIDs: [id]))
            }
        }
        for folder in try FileManager.default.contentsOfDirectory(at: directory("web-captures"), includingPropertiesForKeys: nil) where !folder.lastPathComponent.hasPrefix(".") {
            let metadata = try Data(contentsOf: folder.appendingPathComponent("capture.json"))
            let record = try JSONDecoder().decode(WebCapture.self, from: metadata)
            guard related.contains(record.observationID), context.vacancyIDs.contains(record.vacancyID), record.capturedAt <= context.createdAt else { continue }
            try validID(record.id)
            let png = try Data(contentsOf: folder.appendingPathComponent("viewport.png"))
            guard try MaterialHash.digest(png, algorithm: record.algorithm) == record.hash else { throw ArchiveError.invalid("Повреждён снимок страницы") }
            result.append(Material(path: "web/\(record.id)/viewport.png", data: png, type: "image/png", observationIDs: [record.observationID]))
            result.append(Material(path: "web/\(record.id)/capture.json", data: metadata, type: "web-capture-metadata", observationIDs: [record.observationID]))
        }
        return result
    }

    func archive(pdf: Data, context: DocumentContext) throws -> URL {
        lock.lock(); defer { lock.unlock() }
        return try transaction(parent: directory("reports"), id: context.id) { folder in
            var entries: [ArchiveManifest.File] = []
            func add(_ data: Data, path: String, type: String, observations: [String]) throws {
                let file = try safeFile(path, in: folder)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: file, options: .withoutOverwriting)
                entries.append(.init(path: path, type: type, size: data.count, algorithm: MaterialHash.algorithm,
                                     hash: try MaterialHash.digest(data), observationIDs: observations))
            }
            try add(pdf, path: "document.pdf", type: "application/pdf", observations: context.observationIDs)
            for material in try materials(for: context) {
                try add(material.data, path: material.path, type: material.type, observations: material.observationIDs)
            }
            let manifest = ArchiveManifest(version: 1, report: context, files: entries)
            try ArchiveJSON.encode(manifest).write(to: folder.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
            try verify(folder)
        }
    }
    func verify(_ folder: URL) throws {
        let manifest = try JSONDecoder().decode(ArchiveManifest.self, from: Data(contentsOf: safeFile("manifest.json", in: folder)))
        guard manifest.version == 1, Set(manifest.files.map(\.path)).count == manifest.files.count,
              manifest.files.contains(where: { $0.path == "document.pdf" }) else { throw ArchiveError.invalid("Некорректный манифест") }
        try validID(manifest.report.id)
        for entry in manifest.files {
            let file = try safeFile(entry.path, in: folder)
            let data = try Data(contentsOf: file)
            guard data.count == entry.size, try MaterialHash.digest(data, algorithm: entry.algorithm) == entry.hash else { throw ArchiveError.invalid("Нарушена целостность \(entry.path)") }
        }
        let expected = Set(manifest.files.map(\.path) + ["manifest.json"])
        let canonicalFolder = folder.resolvingSymlinksInPath().standardizedFileURL
        if let enumerator = FileManager.default.enumerator(at: canonicalFolder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            for case let file as URL in enumerator {
                let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard attributes.isSymbolicLink != true else { throw ArchiveError.invalid("Ссылка в комплекте") }
                if attributes.isRegularFile == true {
                    let relative = file.resolvingSymlinksInPath().standardizedFileURL.pathComponents.dropFirst(canonicalFolder.pathComponents.count).joined(separator: "/")
                    guard expected.contains(relative) else { throw ArchiveError.invalid("Незаявленный файл: " + relative) }
                }
            }
        }
    }
    func reports() throws -> [ArchiveManifest] {
        try FileManager.default.contentsOfDirectory(at: directory("reports"), includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }.map { folder in
                try verify(folder)
                return try JSONDecoder().decode(ArchiveManifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
            }.sorted { $0.report.createdAt > $1.report.createdAt }
    }
    func restore(id: String, destination: URL) throws {
        try validID(id)
        let folder = try directory("reports").appendingPathComponent(id)
        try verify(folder)
        try Data(contentsOf: folder.appendingPathComponent("document.pdf")).write(to: destination, options: .atomic)
    }
}

/// Adds EmbeddedFiles to a freshly generated, unencrypted CoreGraphics PDF.
/// Original page streams are untouched. Unsupported PDF structures fail closed.
/// Binary source bytes are stored in unfiltered streams and recoverable exactly.
enum PDFOriginalMaterials {
    static func embed(_ materials: [DocumentArchive.Material], in pdf: Data) throws -> Data {
        let text = String(decoding: pdf, as: UTF8.self)
        func captures(_ pattern: String, _ input: String) throws -> [String] {
            let regex = try NSRegularExpression(pattern: pattern)
            guard let match = regex.matches(in: input, range: NSRange(input.startIndex..., in: input)).last else { throw ArchiveError.invalid("Структура исходного PDF не поддерживается") }
            return (0..<match.numberOfRanges).map { (input as NSString).substring(with: match.range(at: $0)) }
        }
        let trailer = try captures(#"trailer\s*(<<[\s\S]*?>>)\s*startxref\s*(\d+)\s*%%EOF"#, text)
        guard !trailer[1].contains("/Encrypt") else { throw ArchiveError.invalid("Зашифрованный PDF") }
        let root = try captures(#"/Root\s+(\d+)\s+(\d+)\s+R"#, trailer[1])
        let size = try captures(#"/Size\s+(\d+)"#, trailer[1])
        guard let firstID = Int(size[1]), let rootID = Int(root[1]), root[2] == "0" else { throw ArchiveError.invalid("Каталог PDF") }
        let catalog = try captures("(?:^|[\\r\\n])" + root[1] + #"\s+0\s+obj\s*(<<[\s\S]*?>>)\s*endobj"#, text)[1]
        guard !catalog.contains("/Names"), !catalog.contains("/EmbeddedFiles") else { throw ArchiveError.invalid("PDF уже содержит дерево имён") }
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
            guard material.path.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else { throw ArchiveError.invalid("Имя вложения PDF") }
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
