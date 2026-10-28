import SwiftUI

@MainActor
struct VacancyStatusSummary: View {
    let vacancyCountMessage: String
    let fieldInstitutionCount: Int
    let updatedAtMessage: String?
    let loadingEmployerName: String?

    var body: some View {
        Group {
            Text(vacancyCountMessage)
                .accessibilityIdentifier("displayedVacancyCount")
            Text("Полевые учреждения: \(fieldInstitutionCount)")
                .accessibilityIdentifier("fieldInstitutionCount")
            if let updatedAtMessage {
                Text(updatedAtMessage)
                    .accessibilityIdentifier("vacancyUpdateStatus")
            }
            VacancyStatusMessage(message: loadingEmployerName)
        }
    }
}

struct VacancyEmptyState: View {
    let message: String
    var isLoading = false

    var body: some View {
        VStack(spacing: 12) {
            if isLoading { ProgressView() }
            Text(message)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

@MainActor
struct PDFExportCommand: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.body)
                .frame(height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
        .foregroundColor(.primary)
    }
}

@MainActor
struct VacancyCompensationSummary: View {
    let salary: String?
    let area: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(salary ?? "Зарплата не указана")
                .font(.system(size: 13))
            Text(area)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .foregroundColor(.primary)
    }
}

enum DeskPalette {
    static let content = Color(nsColor: .textBackgroundColor)
    static let toolbar = Color(nsColor: .windowBackgroundColor)
}

/// Shows the current employer only while a refresh is running.
struct VacancyStatusMessage: View {
    let message: String?

    var body: some View {
        if let message {
            Text(message)
                .truncationMode(.tail)
                .help(message)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .accessibilityLabel(message)
                .accessibilityIdentifier("vacancyExtractionStatus")
        }
    }
}

/// Shared geometry for every refresh/cancel control, regardless of its title.
struct VacancyRefreshButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(width: 120, height: 32)
    }
}

@MainActor
struct VacancySearchBar: View {
    @Binding var text: String
    let submit: @MainActor () -> Void
    let clear: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                TextField("Поиск в названии и доступном описании", text: $text)
                    .textFieldStyle(.plain)
                    .onSubmit { submit() }
                    .accessibilityIdentifier("vacancySearchField")
                if !text.isEmpty {
                    Button { clear() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary.opacity(0.65))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Очистить поиск")
                    .accessibilityIdentifier("clearVacancySearch")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.35)))
            Button("Искать") { submit() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(width: 120, height: 32)
                .accessibilityIdentifier("submitVacancySearch")
        }
        .controlSize(.large)
        .padding(.horizontal, 28)
        .padding(.vertical, 10)
        .background(DeskPalette.toolbar)
    }
}
