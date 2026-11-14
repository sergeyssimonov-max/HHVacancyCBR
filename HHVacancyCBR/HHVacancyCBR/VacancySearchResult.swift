import Foundation

struct VacancySearchResult: Identifiable {
    let id: String
    let summary: HHVacancySummary
    let details: HHVacancyDetails
    let location: VacancyLocation
    let isDetailLoaded: Bool
    let isDetailLoading: Bool
    let detailErrorMessage: String?
    let persistedSalaryText: String?
    let isArchived: Bool
    let archiveCheckedAt: Date?
    let exportDataNotice: String?
    let fieldInstitution: FieldInstitutionClassification
    var isFieldInstitution: Bool { fieldInstitution.isMember }

    init(
        id: String,
        summary: HHVacancySummary,
        details: HHVacancyDetails,
        location: VacancyLocation = .unknown,
        isDetailLoaded: Bool = false,
        isDetailLoading: Bool = false,
        detailErrorMessage: String? = nil,
        persistedSalaryText: String? = nil,
        isArchived: Bool? = nil,
        archiveCheckedAt: Date? = nil,
        exportDataNotice: String? = nil,
        classification: FieldInstitutionClassification? = nil
    ) {
        let classification = classification ?? FieldInstitutionClassifier.classify(summary: summary, details: details)
        let employerID = details.employer?.id ?? summary.employer?.id ?? ""
        self.fieldInstitution = FieldInstitutionClassifier.isEligibleHHEmployer(employerID) ? classification : .unidentified
        self.id = id
        var classifiedSummary = summary
        classifiedSummary.fieldInstitutionEvidence = self.fieldInstitution
        self.summary = classifiedSummary
        self.details = details
        self.location = location
        self.isDetailLoaded = isDetailLoaded
        self.isDetailLoading = isDetailLoading
        self.detailErrorMessage = detailErrorMessage
        self.persistedSalaryText = persistedSalaryText
        self.isArchived = isArchived ?? details.archived ?? false
        self.archiveCheckedAt = archiveCheckedAt
        self.exportDataNotice = exportDataNotice
    }

    init(summary: HHVacancySummary, location: VacancyLocation) {
        self.init(
            id: summary.id, summary: summary,
            details: HHVacancyDetails(
                id: summary.id, name: summary.name, employer: summary.employer,
                area: summary.area, salary: summary.salary, alternateURL: summary.alternateURL,
                description: nil, schedule: summary.schedule, workFormat: summary.workFormat,
                department: summary.department
            ),
            location: location
        )
    }

    var observationIDs: [String] { Array(Set([summary.observationID, details.observationID].compactMap { $0 })).sorted() }

    var archiveStatusText: String {
        if isArchived { return "В архиве" }
        if archiveCheckedAt != nil || details.archived == false { return "Активна" }
        return "Не проверен"
    }

    var closedForApplicants: Bool? { details.closedForApplicants ?? summary.closedForApplicants }
    var applicationStatusText: String {
        closedForApplicants.map { $0 ? "Закрыт" : "Открыт" } ?? "Не указан"
    }

    var name: String {
        details.name
    }

    var employerName: String {
        details.employer?.name?.nilIfBlank ?? summary.employer?.name?.nilIfBlank ?? "Работодатель не указан"
    }

    var employerID: String? {
        details.employer?.id?.nilIfBlank ?? summary.employer?.id?.nilIfBlank
    }

    var departmentName: String? {
        details.department?.name?.nilIfBlank ?? summary.department?.name?.nilIfBlank
    }

    var publishedAt: String? {
        summary.publishedAt ?? details.publishedAt
    }

    var areaName: String {
        location.displayName
    }

    var salaryText: String? {
        details.salaryRange?.displayText ?? details.salary?.displayText
            ?? summary.salary?.displayText ?? persistedSalaryText
    }

    var alternateURL: String? {
        details.alternateURL?.nilIfBlank ?? summary.alternateURL?.nilIfBlank
    }

    var htmlDescription: String {
        details.description?.nilIfBlank ?? ""
    }

    var plainTextDescription: String? {
        details.description?.readableHTMLText.nilIfBlank
    }

    var hasFullDescription: Bool {
        details.description?.nilIfBlank != nil
    }

    func updatingArchiveStatus(_ archived: Bool, checkedAt: Date) -> VacancySearchResult {
        VacancySearchResult(
            id: id, summary: summary, details: details, location: location,
            isDetailLoaded: isDetailLoaded, isDetailLoading: isDetailLoading,
            detailErrorMessage: detailErrorMessage, persistedSalaryText: persistedSalaryText,
            isArchived: archived, archiveCheckedAt: checkedAt, exportDataNotice: exportDataNotice,
            classification: fieldInstitution
        )
    }

    func updatingDetailState(
        isLoading: Bool,
        errorMessage: String?
    ) -> VacancySearchResult {
        VacancySearchResult(
            id: id,
            summary: summary,
            details: details,
            location: location,
            isDetailLoaded: isDetailLoaded,
            isDetailLoading: isLoading,
            detailErrorMessage: errorMessage,
            persistedSalaryText: persistedSalaryText,
            isArchived: isArchived,
            archiveCheckedAt: archiveCheckedAt,
            exportDataNotice: exportDataNotice,
            classification: fieldInstitution
        )
    }
}
