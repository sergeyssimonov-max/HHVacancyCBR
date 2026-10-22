import Foundation

/// Lossless JSON values: unknown source fields remain typed and available offline.
indirect enum SourceJSONValue: Codable, Equatable, Sendable {
    case object([String: SourceJSONValue]), array([SourceJSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: SourceJSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([SourceJSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(_ key: String) -> Self { if case .object(let v) = self { return v[key] ?? .null }; return .null }
    var text: String? {
        switch self {
        case .string(let v): return v.nilIfBlank
        case .number(let v): return v.rounded() == v ? String(format: "%.0f", v) : String(v)
        default: return nil
        }
    }
    var number: Double? {
        let value: Double?
        if case .number(let v) = self { value = v } else if case .string(let v) = self { value = Double(v) } else { value = nil }
        return value.flatMap { $0.isFinite ? $0 : nil }
    }
    var list: [Self]? { if case .array(let v) = self { return v }; return nil }
    var fields: [String: Self]? { if case .object(let v) = self { return v }; return nil }
    var readable: String {
        switch self {
        case .object(let v): return v.keys.sorted().map { "\($0): \(v[$0]!.readable)" }.joined(separator: "\n")
        case .array(let v): return v.map(\.readable).joined(separator: "\n")
        case .bool(let v): return v ? "Да" : "Нет"
        case .null: return ""
        default: return text?.readableHTMLText ?? ""
        }
    }
}

struct TrudvsemVacancyDTO: Codable, Equatable, Sendable {
    let raw: SourceJSONValue
    let id: String
    let title: String
    let companyCode: String
    enum CodingKeys: String, CodingKey { case id, title = "job-name", company }
    init(raw: SourceJSONValue) throws {
        guard let id = raw["id"].text, let title = raw["job-name"].text,
              let companyCode = raw["company"]["companycode"].text else { throw TrudvsemError.invalid("Запись без id, job-name или companycode") }
        self.raw = raw; self.id = id; self.title = title; self.companyCode = companyCode
    }
    init(from decoder: Decoder) throws { try self.init(raw: SourceJSONValue(from: decoder)) }
    func encode(to encoder: Encoder) throws { try raw.encode(to: encoder) }
}

struct TrudvsemPage: Sendable {
    let total: Int
    let vacancies: [TrudvsemVacancyDTO]
    let receivedCount: Int
    let malformedCount: Int
    var observationID: String?
    init(data: Data) throws {
        let root = try JSONDecoder().decode(SourceJSONValue.self, from: data)
        guard root["status"].text == "200" else { throw TrudvsemError.invalid("API status: \(root["status"].text ?? "отсутствует")") }
        guard let n = root["meta"]["total"].number, n >= 0, n < Double(Int.max), n.rounded() == n else { throw TrudvsemError.invalid("meta.total") }
        total = Int(n)
        // Empty results can be absent in a successful zero-result response.
        let items: [SourceJSONValue]
        if let values = root["results"]["vacancies"].list { items = values }
        else if total == 0 { items = [] }
        else { throw TrudvsemError.invalid("results.vacancies") }
        receivedCount = items.count
        vacancies = items.compactMap { try? TrudvsemVacancyDTO(raw: $0["vacancy"]) }
        malformedCount = items.count - vacancies.count
    }
}

struct TrudvsemVacancy: Codable, Identifiable, Equatable, Sendable {
    let dto: TrudvsemVacancyDTO
    let organizationKey: String
    var observationIDs: [String]
    let fieldInstitution: FieldInstitutionClassification
    var id: String { "trudvsem.ru:\(dto.companyCode):\(dto.id)" }
    var title: String { dto.title }
    var organization: Organization? { OrganizationRegistry.all.first { $0.id == organizationKey } }
    var department: String { dto.raw["company"]["name"].text ?? dto.companyCode }
    var regionID: String { dto.raw["region"]["region_code"].text ?? "unknown" }
    var region: String { dto.raw["region"]["name"].text ?? "Регион не указан" }
    var salary: String? {
        if let text = dto.raw["salary"].text { return text }
        let lower = dto.raw["salary_min"].number.map { "от " + String(format: "%.0f", $0) }
        let upper = dto.raw["salary_max"].number.map { "до " + String(format: "%.0f", $0) }
        let bounds = [lower, upper].compactMap { $0 }
        guard !bounds.isEmpty else { return nil }
        return (bounds + [dto.raw["currency"].text].compactMap { $0 }).joined(separator: " ")
    }
    var created: String? { dto.raw["creation-date"].text }
    var createdDate: Date? {
        guard let created else { return nil }
        if let date = HHPublicationDateParser().date(from: created) { return date }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        return f.date(from: created)
    }
    var url: URL? {
        guard let raw = dto.raw["vac_url"].text, let url = URL(string: raw), ["https", "http"].contains(url.scheme) else { return nil }
        return url
    }
    init(dto: TrudvsemVacancyDTO, organization: Organization, observationIDs: [String]) {
        self.dto = dto; organizationKey = organization.id; self.observationIDs = observationIDs
        fieldInstitution = FieldInstitutionClassifier.classifyWorkplace(
            eligible: organization.id == "bank_of_russia",
            workplaceFields: [dto.title, dto.raw["company"]["name"].text],
            descriptions: [dto.raw["duty"].text, dto.raw["addresses"].readable],
            provenance: "trudvsem.ru, ИНН \(organization.inn), companycode \(dto.companyCode)")
    }
    var context: DocumentContext {
        .init(kind: "Сведения о вакансии", vacancyIDs: [id], observationIDs: observationIDs, source: .trudvsem)
    }
}

enum TrudvsemError: LocalizedError {
    case invalid(String), http(Int), incomplete(String)
    var errorDescription: String? {
        switch self {
        case .invalid(let text): return "trudvsem.ru: некорректный ответ (\(text))."
        case .http(let code): return "trudvsem.ru: HTTP \(code)."
        case .incomplete(let text): return "Неполный сбор trudvsem.ru: \(text). Предыдущая выборка сохранена."
        }
    }
}
