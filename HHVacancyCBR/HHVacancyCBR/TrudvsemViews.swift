import SwiftUI

struct TrudvsemViews: View {
    @ObservedObject var viewModel: TrudvsemViewModel
    @Binding var source: VacancySource
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            statusBar
            Divider()
            if let error = viewModel.errorMessage { Text(error).font(.caption).foregroundColor(.red).padding(8).textSelection(.enabled) }
            if viewModel.results.isEmpty {
                VacancyEmptyState(
                    message: viewModel.updatedAt == nil ? "Загрузите вакансии trudvsem.ru кнопкой «Обновить»." : "Вакансий не найдено.",
                    isLoading: viewModel.isLoading)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.displayedResults) { vacancy in
                            card(vacancy)
                            Divider()
                        }
                    }
                }
            }
        }.background(DeskPalette.content)
    }

    private var toolbar: some View {
        HStack(spacing: 14) {
            Picker("", selection: $source) {
                Text("hh.ru").tag(VacancySource.hh)
                Text("trudvsem.ru").tag(VacancySource.trudvsem)
            }.pickerStyle(.segmented).frame(width: 220, height: 32).accessibilityIdentifier("vacancyListModePicker")
            Picker("Категория", selection: $viewModel.fieldInstitutionsOnly) {
                Text("Все вакансии").tag(false); Text("Полевые учреждения").tag(true)
            }.labelsHidden().frame(width: 190).accessibilityIdentifier("categoryFilterPicker")
            Picker("Работодатель", selection: $viewModel.selectedEmployerID) {
                Text("Все работодатели").tag("all")
                ForEach(OrganizationRegistry.available(on: .trudvsem)) { Text($0.name).tag($0.id) }
            }.labelsHidden().frame(minWidth: 140, maxWidth: .infinity).accessibilityIdentifier("employerFilterPicker")
            Picker("Субъект", selection: $viewModel.selectedRegionID) {
                ForEach(viewModel.regions) { Text($0.title).tag($0.id) }
            }.labelsHidden().frame(minWidth: 140, maxWidth: .infinity).accessibilityIdentifier("regionFilterPicker")
            VacancyRefreshButton(title: viewModel.isLoading ? (viewModel.isCancellingSearch ? "Отмена…" : "Отменить") : "Обновить") {
                if viewModel.isLoading { viewModel.cancelSearch() } else { viewModel.startRefresh() }
            }.disabled(viewModel.isCancellingSearch)
                .accessibilityIdentifier("refreshTrudvsemButton")
        }.controlSize(.large).padding(.horizontal, 28).padding(.vertical, 10).background(DeskPalette.toolbar)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            VacancyStatusSummary(
                vacancyCountMessage: VacancyDisplayFormat.vacancyCount(viewModel.displayedResults.count),
                fieldInstitutionCount: viewModel.displayedResults.filter { $0.fieldInstitution.isMember }.count,
                updatedAtMessage: viewModel.updatedAt.map { VacancyDisplayFormat.updatedAt($0) },
                loadingEmployerName: viewModel.isLoading ? viewModel.currentEmployerName : nil)
            Spacer()
            PDFExportCommand(title: viewModel.isExporting ? "Отменить экспорт" : "Все вакансии в PDF") {
                if viewModel.isExporting { viewModel.cancelExport() } else { viewModel.export(.all) }
            }.disabled(viewModel.displayedResults.isEmpty).accessibilityIdentifier("exportBulkPDFButton")
            PDFExportCommand(title: "Статистика в PDF") { viewModel.export(.statistics) }
                .disabled(viewModel.displayedResults.isEmpty || viewModel.isExporting).accessibilityIdentifier("exportStatisticsPDFButton")
        }.lineLimit(1).font(.system(size: 13)).foregroundColor(.secondary).padding(.horizontal, 28).frame(height: 48)
    }

    private func card(_ value: TrudvsemVacancy) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(value.title).font(.system(size: 15, weight: .semibold))
                    Text(value.organization?.name ?? value.organizationKey).font(.system(size: 13)).foregroundColor(.secondary)
                    if value.fieldInstitution.isMember { Text("Полевое учреждение").font(.caption).foregroundColor(.secondary).help(value.fieldInstitution.reason ?? "") }
                }
                Spacer()
                VacancyCompensationSummary(salary: value.salary, area: value.region)
            }
            HStack(spacing: 10) {
                if let url = value.url { Button("Открыть на trudvsem.ru ↗") { NSWorkspace.shared.open(url) } }
                Button("Скопировать ссылку") {
                    guard let url = value.url else { return }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }.disabled(value.url == nil)
                Button(viewModel.expandedID == value.id ? "Скрыть детали" : "Подробнее") { viewModel.expandedID = viewModel.expandedID == value.id ? nil : value.id }
                Spacer()
                PDFExportCommand(title: "Экспорт в PDF") { viewModel.export(.personal(value)) }.disabled(viewModel.isExporting)
            }.buttonStyle(.borderless)
            if viewModel.expandedID == value.id {
                VacancyHTMLDescriptionView(html: TrudvsemDescriptionFormatter.html(for: value)).frame(minHeight: 320)
            }
        }.padding(.horizontal, 28).padding(.vertical, 18)
    }
}

private enum TrudvsemDescriptionFormatter {
    static func html(for value: TrudvsemVacancy) -> String {
        let keys = ["duty", "requirement", "requirements", "qualification", "education", "experience", "schedule", "employment", "term", "social_protected"]
        return keys.compactMap { key -> String? in
            let text = value.dto.raw[key].readable
            guard value.dto.raw[key] != .null, !text.isEmpty else { return nil }
            return "<h3>\(TrudvsemPDFFormatter.labels[key] ?? key)</h3>\(text)"
        }.joined(separator: "\n")
    }
}
