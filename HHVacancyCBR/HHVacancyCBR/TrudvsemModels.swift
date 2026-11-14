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
        func amount(_ value: SourceJSONValue) -> Int? {
            guard let number = value.number, number >= 0, number < Double(Int.max) else { return nil }
            return Int(number.rounded())
        }
        let lower = amount(dto.raw["salary_min"])
        let upper = amount(dto.raw["salary_max"])
        let single = amount(dto.raw["salary"])
        if lower != nil || upper != nil || single != nil {
            return HHSalary(from: lower ?? (upper == nil ? single : nil), to: upper,
                            currency: dto.raw["currency"].text ?? "RUR", gross: nil).displayText
                .map { single != nil && lower == nil && upper == nil ? $0.replacingOccurrences(of: "от ", with: "", options: .anchored) : $0 }
        }
        return dto.raw["salary"].text
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
            eligible: organization.hasFieldInstitutions,
            workplaceFields: [dto.title, dto.raw["company"]["name"].text],
            descriptions: [dto.raw["duty"].text, dto.raw["addresses"].readable],
            provenance: "trudvsem.ru, ИНН \(organization.inn), companycode \(dto.companyCode)")
    }

    private enum CodingKeys: String, CodingKey { case dto, organizationKey, observationIDs, fieldInstitution }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dto = try container.decode(TrudvsemVacancyDTO.self, forKey: .dto)
        let key = try container.decode(String.self, forKey: .organizationKey)
        organizationKey = key
        observationIDs = try container.decode([String].self, forKey: .observationIDs)
        let savedClassification = try container.decode(FieldInstitutionClassification.self, forKey: .fieldInstitution)
        // Keep the snapshot format and source data; discard an impossible cached category.
        let eligible = OrganizationRegistry.all.contains { $0.id == key && $0.hasFieldInstitutions }
        fieldInstitution = eligible ? savedClassification : .unidentified
    }
    var context: DocumentContext {
        .init(kind: "Сведения о вакансии", vacancyIDs: [id], observationIDs: observationIDs, source: .trudvsem)
    }
}

enum TrudvsemError: LocalizedError {
    case invalid(String), http(Int), incomplete(String)
    case network(URLError.Code, retryAfter: Int?)

    var stopsCollection: Bool {
        switch self {
        case .network: return true
        case .http(let status): return [401, 403, 408, 429].contains(status) || (500...599).contains(status)
        default: return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalid(let text): return "trudvsem.ru: некорректный ответ (\(text))."
        case .http(let code): return "trudvsem.ru: HTTP \(code)."
        case .incomplete(let text): return "Неполный сбор trudvsem.ru: \(text)."
        case .network(let code, let retryAfter):
            let reason: String
            switch code {
            case .timedOut: reason = "Сервер trudvsem.ru не ответил вовремя."
            case .notConnectedToInternet: reason = "Нет подключения к интернету."
            case .cannotFindHost, .dnsLookupFailed: reason = "Не удалось найти сервер trudvsem.ru."
            case .cannotConnectToHost, .networkConnectionLost: reason = "Не удалось установить соединение с trudvsem.ru."
            case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                 .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                 .clientCertificateRejected, .clientCertificateRequired:
                reason = "Не удалось установить защищённое соединение с trudvsem.ru."
            default: reason = "Сетевая ошибка trudvsem.ru (код \(code.rawValue))."
            }
            return reason + " " + (retryAfter.map { "Повторите обновление через \($0) с." }
                ?? "Проверьте подключение и повторите обновление позже.")
        }
    }
}
